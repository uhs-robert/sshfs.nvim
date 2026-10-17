-- lua/sshfs/lib/mirror_delete.lua
-- Deleting local mirrors: finding every mirror on disk, the checks that keep work from being lost, and the removal.
-- Only ever touches the local folder and the state file under mirror.base_dir; the server is never contacted.

local MirrorDelete = {}

local STATUS = {
  here = "connected here",
  elsewhere = "connected in another instance",
  disconnected = "disconnected",
  missing = "folder missing",
  unrecorded = "no sync record",
  work = "has unpushed work",
}

local function base_dir()
  return (vim.fs.normalize(require("sshfs.config").get().mirror.base_dir):gsub("/+$", ""))
end

--- Whether a path is a real directory strictly inside mirror.base_dir, however it is spelled
--- The lexical check rejects the base itself and anything outside it; the resolved one catches a symlinked
--- mirror folder or base that leads somewhere else, which a recursive delete must never follow.
---@param path string
---@return boolean ok
---@return string|nil reason
function MirrorDelete.check_path(path)
  local base = base_dir()
  if path:sub(1, 1) ~= "/" or vim.fs.normalize(path) ~= path then return false, "the path is not normalized" end
  if path:sub(1, #base + 1) ~= base .. "/" then return false, path .. " is outside " .. base end

  local stat = vim.uv.fs_lstat(path)
  if not stat then return false, "the folder does not exist" end
  if stat.type ~= "directory" then return false, path .. " is not a plain directory" end

  local real, real_base = vim.uv.fs_realpath(path), vim.uv.fs_realpath(base)
  if not real or not real_base or real:sub(1, #real_base + 1) ~= real_base .. "/" then
    return false, path .. " resolves outside " .. base
  end
  return true
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

--- Directories directly inside the base directory that no state file points at
---@param recorded table<string, boolean> local_path -> true
---@return string[] paths
local function unrecorded_folders(recorded)
  local base = base_dir()
  if vim.fn.isdirectory(base) ~= 1 then return {} end
  local names = vim.fn.readdir(base, function(item)
    return vim.fn.isdirectory(base .. "/" .. item)
  end)
  local paths = {}
  for _, name in ipairs(names) do
    if not recorded[base .. "/" .. name] then table.insert(paths, base .. "/" .. name) end
  end
  return paths
end

--- Every mirror known locally: those with a state file, and folders in the base directory without one
---@param host string|nil Only mirrors of this host (folders without a record are then left out)
---@return table[] entries {kind = "mirror"|"missing"|"unrecorded", local_path, state, status, has_work, label}
function MirrorDelete.entries(host)
  local MirrorState = require("sshfs.lib.mirror_state")
  local Mirror = require("sshfs.lib.mirror")
  local entries, recorded = {}, {}

  for _, state in ipairs(MirrorState.list()) do
    recorded[state.local_path] = true
    if not host or state.host == host then
      local entry = { kind = "mirror", local_path = state.local_path, state = state, status = state_status(state) }
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
end

---@param prompt string
---@param callback function fun(confirmed: boolean)
local function confirm(prompt, callback)
  vim.ui.select({ "Delete", "Cancel" }, { prompt = prompt }, function(choice)
    callback(choice == "Delete")
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

local function has_loss(details)
  return #details.files > 0 or details.git
end

--- Remove the folder (if any) and the state file
---@param entry table
---@return boolean ok
local function remove(entry)
  if entry.kind ~= "missing" then
    local ok, reason = MirrorDelete.check_path(entry.local_path)
    if ok then
      if vim.fn.delete(entry.local_path, "rf") ~= 0 then
        notify_error("could not remove " .. entry.local_path)
        return false
      end
    elseif vim.uv.fs_lstat(entry.local_path) then
      -- Present but not safely deletable: keep the record too, so nothing is half-forgotten
      notify_error(reason)
      return false
    end
  end
  require("sshfs.lib.mirror_state").delete(entry.local_path)
  require("sshfs.lib.lockfile").unregister(entry.local_path)
  vim.notify("Deleted local mirror " .. entry.local_path, vim.log.levels.INFO)
  return true
end

--- Delete one mirror after the checks and a confirmation
--- A mirror held by another Neovim is refused. One with work that never reached the server is refused unless
--- force is set, and then the confirmation lists exactly what is lost. A mirror connected here is disconnected
--- first, which flushes its pending pushes.
---@param entry table From MirrorDelete.entries
---@param opts table {force = boolean}
function MirrorDelete.run(entry, opts)
  local path = entry.local_path
  local Mirror = require("sshfs.lib.mirror")
  local MirrorState = require("sshfs.lib.mirror_state")

  if entry.kind == "missing" then
    return confirm("Remove the record of the missing mirror " .. path .. "?", function(confirmed)
      if confirmed then remove(entry) end
    end)
  end

  local ok, reason = MirrorDelete.check_path(path)
  if not ok then return notify_error(reason) end
  if require("sshfs.lib.lockfile").is_in_use_by_others(path) then
    return notify_error(path .. " is in use by another Neovim instance")
  end

  local state = entry.state and MirrorState.load(path)
  local details = state and Mirror.local_only_details(state) or { files = {}, git = false }
  if has_loss(details) and not opts.force then
    return notify_error(
      string.format(
        "%s has work that is not on the server:\n%s\n:SSHMirrorDelete! deletes it anyway",
        path,
        describe_loss(details)
      )
    )
  end

  local prompt = "Delete local mirror " .. path .. "?"
  if entry.kind == "unrecorded" then
    prompt = prompt .. "\nIt has no sync record, so unpushed work cannot be checked."
  elseif has_loss(details) then
    prompt = prompt .. "\nThis loses:\n" .. describe_loss(details)
  end

  confirm(prompt, function(confirmed)
    if not confirmed then return end

    if state and require("sshfs.lib.connections").is_mirror_live(state) then
      local connection = vim.tbl_filter(function(item)
        return item.local_path == path
      end, require("sshfs.lib.connections").list_active())[1]
      if connection and not require("sshfs.session").disconnect_from(connection, true) then
        return notify_error("could not disconnect " .. path)
      end
    end

    -- The disconnect flushed pending pushes (and may have deleted the mirror itself); look again before removing
    local fresh = state and MirrorState.load(path)
    if not fresh and state then
      if vim.uv.fs_lstat(path) == nil then return vim.notify("Deleted local mirror " .. path, vim.log.levels.INFO) end
    end
    if fresh and not opts.force and has_loss(Mirror.local_only_details(fresh)) then
      return notify_error(path .. " has work that is not on the server")
    end
    remove({ kind = entry.kind, local_path = path })
  end)
end

return MirrorDelete
