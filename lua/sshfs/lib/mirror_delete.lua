-- lua/sshfs/lib/mirror_delete.lua
-- Deleting local mirrors: finding every mirror on disk, the checks that keep work from being lost, and the removal.
-- Only ever touches the local folder and the state file under mirror.base_dir; the server is never contacted.
-- Every check runs again right before the removal, against state read from disk then, because the
-- confirmation and the disconnect give other Neovim instances and pushes time to change things.

local MirrorDelete = {}

local STATUS = {
  here = "connected here",
  elsewhere = "connected in another instance",
  disconnected = "disconnected",
  missing = "folder missing",
  unrecorded = "no sync record",
  work = "has unpushed work",
}

local NO_LOSS = { files = {}, git = false }

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

--- The spelling that tells whether two paths name the same folder: resolved when it exists
---@param path string
---@return string
local function identity(path)
  return vim.uv.fs_realpath(path) or (vim.fs.normalize(path):gsub("/+$", ""))
end

--- Whether a path is a real directory strictly inside mirror.base_dir, however it is spelled, and safe to recurse
--- The lexical check rejects the base itself and anything outside it; the resolved one catches a symlinked
--- mirror folder or base that leads somewhere else. A folder on another device than the base, or holding an
--- sshfs mount, would let a recursive delete reach the server, so both are refused too.
---@param path string
---@return boolean ok
---@return string|nil reason
function MirrorDelete.check_path(path)
  local bases = require("sshfs.lib.mirror_state").base_dirs()
  if path:sub(1, 1) ~= "/" or vim.fs.normalize(path) ~= path then return false, "the path is not normalized" end
  local inside = vim.iter(bases):any(function(base)
    return path:sub(1, #base + 1) == base .. "/"
  end)
  if not inside then return false, path .. " is outside " .. bases[1] end

  local stat = vim.uv.fs_lstat(path)
  if not stat then return false, "the folder does not exist" end
  if stat.type ~= "directory" then return false, path .. " is not a plain directory" end

  local real, real_base = vim.uv.fs_realpath(path), vim.uv.fs_realpath(bases[1])
  if not real or not real_base or real:sub(1, #real_base + 1) ~= real_base .. "/" then
    return false, path .. " resolves outside " .. bases[1]
  end

  local base_stat = vim.uv.fs_stat(real_base)
  if not base_stat or base_stat.dev ~= stat.dev then
    return false, path .. " is on another file system than " .. bases[1] .. " (a mount?)"
  end
  -- Compared as listed rather than resolved: resolving a path inside a hung sshfs mount can block
  for _, mount in ipairs(require("sshfs.lib.mount_point").list_system_mounts()) do
    local mounted = vim.fs.normalize(mount.mount_path)
    for _, root in ipairs({ path, real }) do
      if mounted == root or mounted:sub(1, #root + 1) == root .. "/" then
        return false, path .. " is or contains the active mount " .. mount.mount_path
      end
    end
  end
  return true
end

--- The first directory under root on another device than root itself, found without following symlinks
---@param root string
---@return string|nil path Also an unreadable directory, which cannot be shown to stay on the device
local function file_system_boundary(root)
  local root_stat = vim.uv.fs_lstat(root)
  if not root_stat then return root end
  local function walk(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return dir end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then return nil end
      if kind == "directory" then
        local child = dir .. "/" .. name
        local stat = vim.uv.fs_lstat(child)
        if not stat or stat.dev ~= root_stat.dev then return child end
        local found = walk(child)
        if found then return found end
      end
    end
  end
  return walk(root)
end

--- Each spelling a lockfile for this entry may have been registered under
---@param entry table
---@return string[]
local function lock_keys(entry)
  local keys, seen = {}, {}
  local function add(key)
    if key and not seen[key] then
      seen[key] = true
      table.insert(keys, key)
    end
  end
  add(entry.state_key)
  add(entry.local_path)
  for _, base in ipairs(require("sshfs.lib.mirror_state").base_dirs()) do
    add(base .. "/" .. vim.fs.basename(entry.local_path))
  end
  return keys
end

local function in_use_by_others(entry)
  local Lockfile = require("sshfs.lib.lockfile")
  return vim.iter(lock_keys(entry)):any(Lockfile.is_in_use_by_others)
end

---@param state table
---@return string status
local function state_status(state)
  if vim.fn.isdirectory(state.local_path) ~= 1 then return STATUS.missing end
  local Lockfile = require("sshfs.lib.lockfile")
  if not require("sshfs.lib.connections").is_mirror_live(state) then return STATUS.disconnected end
  return Lockfile.is_held_by_this_instance(state.local_path) and STATUS.here or STATUS.elsewhere
end

---@param entry table
---@return string
local function label_for(entry)
  local where = vim.fn.fnamemodify(entry.local_path, ":~")
  local status = entry.status .. (entry.has_work and ", " .. STATUS.work or "")
  if not entry.state then return where .. " (" .. status .. ")" end
  return string.format("%s: %s -> %s (%s)", entry.state.host, entry.state.remote_path, where, status)
end

--- A recorded local_path with its parent resolved, so a base recorded through a symlink or with a trailing
--- slash names the folder as the canonical base does; the folder itself stays unresolved, so a symlink there
--- is still refused rather than followed
---@param local_path string
---@return string
local function folder_spelling(local_path)
  local normalized = vim.fs.normalize(local_path):gsub("/+$", "")
  local parent = vim.fs.dirname(normalized)
  local real_parent = vim.uv.fs_realpath(parent)
  if not real_parent then return normalized end
  return (real_parent == "/" and "" or real_parent) .. "/" .. vim.fs.basename(normalized)
end

--- The state recording a folder, under whichever spelling it was recorded
---@param path string
---@return table|nil state
local function recorded_state(path)
  local target = identity(path)
  return vim.iter(require("sshfs.lib.mirror_state").list()):find(function(state)
    return identity(state.local_path) == target
  end)
end

--- Directories directly inside the base directory that no state file points at
---@param recorded table<string, boolean> identity -> true
---@return string[] paths
local function unrecorded_folders(recorded)
  local base = require("sshfs.lib.mirror_state").base_dir()
  if vim.fn.isdirectory(base) ~= 1 then return {} end
  local names = vim.fn.readdir(base, function(item)
    return vim.fn.isdirectory(base .. "/" .. item)
  end)
  local paths = {}
  for _, name in ipairs(names) do
    local path = base .. "/" .. name
    if not recorded[identity(path)] then table.insert(paths, path) end
  end
  return paths
end

--- Every mirror known locally: those with a state file, and folders in the base directory without one
---@param host string|nil Only mirrors of this host (folders without a record are then left out)
---@return table[] entries {kind = "mirror"|"missing"|"unrecorded", local_path, state_key, state, status, has_work, label}
function MirrorDelete.entries(host)
  local MirrorState = require("sshfs.lib.mirror_state")
  local Mirror = require("sshfs.lib.mirror")
  local entries, recorded = {}, {}

  for _, state in ipairs(MirrorState.list()) do
    recorded[identity(state.local_path)] = true
    if not host or state.host == host then
      -- local_path is the spelling the folder is checked and removed by; state_key the one the record and
      -- lockfile are keyed by, which an earlier build may have written unnormalized
      local entry = {
        kind = "mirror",
        local_path = folder_spelling(state.local_path),
        state_key = state.local_path,
        state = state,
        status = state_status(state),
      }
      if entry.status == STATUS.missing then
        entry.kind = "missing"
      else
        local details = Mirror.local_only_details(state)
        entry.has_work = #details.files > 0 or details.git
      end
      table.insert(entries, entry)
    end
  end

  if not host then
    for _, path in ipairs(unrecorded_folders(recorded)) do
      table.insert(entries, { kind = "unrecorded", local_path = path, status = STATUS.unrecorded })
    end
  end

  for _, entry in ipairs(entries) do
    entry.label = label_for(entry)
  end
  return entries
end

local function notify_error(message)
  vim.notify("Mirror not deleted: " .. message, vim.log.levels.ERROR)
  return false
end

--- Ask before an irreversible removal; Cancel comes first so a picker's preselected item is the safe one
---@param prompt string One line, since many pickers show only the first
---@param action string Text of the confirming choice
---@param callback function Called only when the action is chosen
local function confirm(prompt, action, callback)
  vim.ui.select({ "Cancel", action }, { prompt = prompt }, function(choice)
    if choice == action then callback() end
  end)
end

--- What would be lost, one item per line
---@param details table Mirror.local_only_details result
---@return string
local function describe_loss(details)
  local lines = {}
  if #details.files > 0 then
    table.insert(lines, string.format("%d file(s) not on the server:", #details.files))
    for _, rel in ipairs(vim.list_slice(details.files, 1, 10)) do
      table.insert(lines, "  " .. rel)
    end
    if #details.files > 10 then table.insert(lines, string.format("  ... and %d more", #details.files - 10)) end
  end
  if details.git then table.insert(lines, "local .git commits, branches or stashes") end
  return table.concat(lines, "\n")
end

--- The loss in a few words, for the confirming choice
---@param details table
---@return string
local function summarize_loss(details)
  local parts = {}
  if #details.files > 0 then table.insert(parts, #details.files .. " file(s)") end
  if details.git then table.insert(parts, "local git work") end
  return table.concat(parts, " and ")
end

local function has_loss(details)
  return #details.files > 0 or details.git
end

--- Whether everything lost now was already in the confirmed loss
---@param now table
---@param confirmed table
---@return boolean
local function loss_within(now, confirmed)
  if now.git and not confirmed.git then return false end
  local allowed = {}
  for _, rel in ipairs(confirmed.files) do
    allowed[rel] = true
  end
  return vim.iter(now.files):all(function(rel)
    return allowed[rel] == true
  end)
end

--- Remove the folder (if any) and the state file
---@param entry table
---@return boolean ok
local function remove(entry)
  if entry.kind ~= "missing" then
    -- Not safely deletable: the record is kept too, so nothing is half-forgotten
    local ok, reason = MirrorDelete.check_path(entry.local_path)
    if not ok then return notify_error(reason) end
    local boundary = file_system_boundary(entry.local_path)
    if boundary then return notify_error(boundary .. " is on another file system or unreadable") end
    -- Buffers on the files would outlive them; an unsaved one stops the delete
    for _, root in ipairs(vim.fn.uniq({ entry.local_path, entry.state_key or entry.local_path })) do
      if not require("sshfs.lib.mount_point").release_mount(root) then return false end
    end
    if vim.fn.delete(entry.local_path, "rf") ~= 0 then return notify_error("could not remove " .. entry.local_path) end
  end
  if entry.state_key then require("sshfs.lib.mirror_state").delete(entry.state_key) end
  for _, key in ipairs(lock_keys(entry)) do
    require("sshfs.lib.lockfile").unregister(key)
  end
  vim.notify("Deleted local mirror " .. entry.local_path, vim.log.levels.INFO)
  return true
end

--- Remove the record of a mirror whose folder is gone, if it is still gone once the confirmation is answered
---@param entry table
local function run_missing(entry)
  local path = entry.local_path
  if in_use_by_others(entry) then return notify_error(path .. " is in use by another Neovim instance") end

  confirm("Remove the record of the missing mirror " .. path .. "?", "Remove record", function()
    if exists(path) then return notify_error(path .. " exists again; run the delete again to check it") end
    if in_use_by_others(entry) then return notify_error(path .. " is in use by another Neovim instance") end
    local fresh = require("sshfs.lib.mirror_state").load(entry.state_key)
    if fresh and require("sshfs.lib.connections").is_mirror_live(fresh) then
      return notify_error(path .. " is connected; disconnect it first")
    end
    remove(entry)
  end)
end

--- Disconnect a mirror this instance holds
---@param entry table
---@return boolean ok
local function disconnect_here(entry)
  local connection = vim.iter(require("sshfs.lib.connections").list_active()):find(function(item)
    return item.kind == "mirror" and item.local_path == entry.state_key
  end)
  if not connection or not require("sshfs.session").disconnect_from(connection, true) then
    return notify_error("could not disconnect " .. entry.local_path)
  end
  return true
end

--- Every guard again, right before the removal; the loss may only have shrunk since it was confirmed
---@param entry table
---@param confirmed table The loss the user agreed to (NO_LOSS without force)
---@return boolean ok
local function recheck_and_remove(entry, confirmed)
  local path = entry.local_path
  local MirrorState = require("sshfs.lib.mirror_state")
  local Connections = require("sshfs.lib.connections")

  local function current_state()
    if entry.state_key then return MirrorState.load(entry.state_key) end
    return recorded_state(path)
  end

  local ok, reason = MirrorDelete.check_path(path)
  if not ok then return notify_error(reason) end
  if in_use_by_others(entry) then return notify_error(path .. " is in use by another Neovim instance") end

  local fresh = current_state()
  if entry.kind == "unrecorded" and fresh then
    return notify_error(path .. " has a sync record now; run the delete again to check it")
  end
  if entry.state_key and not fresh then
    return notify_error("the record of " .. path .. " changed; run the delete again")
  end

  if fresh and Connections.is_mirror_live(fresh) then
    if not require("sshfs.lib.lockfile").is_held_by_this_instance(entry.state_key) then
      return notify_error(path .. " is connected in another Neovim instance")
    end
    if not disconnect_here(entry) then return false end

    -- on_disconnect = "delete" may have removed the mirror itself
    fresh = current_state()
    if not fresh and not exists(path) then
      vim.notify("Deleted local mirror " .. path, vim.log.levels.INFO)
      return true
    end
    -- The disconnect reports success when another instance keeps the mirror connected
    if in_use_by_others(entry) then return notify_error(path .. " is still in use by another Neovim instance") end
    if not fresh then return notify_error("the record of " .. path .. " changed; run the delete again") end
    if Connections.is_mirror_live(fresh) then return notify_error(path .. " is still connected") end
    ok, reason = MirrorDelete.check_path(path)
    if not ok then return notify_error(reason) end
  end

  local now = fresh and require("sshfs.lib.mirror").local_only_details(fresh) or NO_LOSS
  if not loss_within(now, confirmed) then
    return notify_error(
      string.format("%s now has work that was not confirmed:\n%s\nRun the delete again", path, describe_loss(now))
    )
  end

  return remove(entry)
end

--- Delete one mirror after the checks and a confirmation
--- A mirror held by another Neovim is refused. One with work that never reached the server is refused unless
--- force is set, and then the confirmation lists exactly what is lost. A mirror connected here is disconnected
--- first, which flushes its pending pushes.
---@param entry table From MirrorDelete.entries
---@param opts table {force = boolean}
function MirrorDelete.run(entry, opts)
  local unavailable = require("sshfs.config").mirror_unavailable_reason()
  if unavailable then return notify_error("mirror mode is unavailable: " .. unavailable) end
  if entry.kind == "missing" then return run_missing(entry) end

  local path = entry.local_path
  local Mirror = require("sshfs.lib.mirror")

  local ok, reason = MirrorDelete.check_path(path)
  if not ok then return notify_error(reason) end
  if in_use_by_others(entry) then return notify_error(path .. " is in use by another Neovim instance") end

  local state = entry.state_key and require("sshfs.lib.mirror_state").load(entry.state_key)
  if entry.state_key and not state then
    return notify_error("the record of " .. path .. " changed; run the delete again")
  end
  -- A save still waiting to push is not lost, so it must not count against the delete
  if state and require("sshfs.lib.lockfile").is_held_by_this_instance(entry.state_key) then
    Mirror.flush(10000, entry.state_key)
  end

  local details = state and Mirror.local_only_details(state) or NO_LOSS
  if has_loss(details) and not opts.force then
    return notify_error(
      string.format(
        "%s has work that is not on the server:\n%s\n:SSHMirrorDelete! deletes it anyway",
        path,
        describe_loss(details)
      )
    )
  end

  local prompt, action = "Delete local mirror " .. path .. "?", "Delete"
  if entry.kind == "unrecorded" then
    prompt = prompt .. " It has no sync record, so unpushed work cannot be checked."
  elseif has_loss(details) then
    -- The full list goes through notify, since a picker may show only one line of the prompt
    vim.notify("Deleting " .. path .. " loses:\n" .. describe_loss(details), vim.log.levels.WARN)
    action = "Delete, losing " .. summarize_loss(details)
  end

  confirm(prompt, action, function()
    recheck_and_remove(entry, opts.force and details or NO_LOSS)
  end)
end

return MirrorDelete
