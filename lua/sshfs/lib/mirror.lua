-- lua/sshfs/lib/mirror.lua
-- Mirror mode: a pulled local copy of a remote directory, edited at local speed and synced back over the
-- existing ControlMaster connection.
--
-- The manifest (in lib/mirror_state.lua) records, per file, the `mtime size` the server and the local copy
-- shared at the last sync. A local file that differs from it is dirty: a pull leaves it alone and a push
-- sends it. A server file that differs from it changed on the server: a push asks before overwriting it.
-- State is re-read before every comparison and written per entry, because several Neovim instances may
-- work in the same mirror.
--
-- All transfers for one mirror run one at a time through its queue, so a pull never races a push.

local Mirror = {}
local MirrorState = require("sshfs.lib.mirror_state")
local Remote = require("sshfs.lib.mirror_remote")
local Rsync = require("sshfs.lib.rsync")
local Logger = require("sshfs.lib.logger")

-- Per-mirror queues, keyed by local root
local QUEUES = {}

-- Set once Neovim starts exiting: nothing may prompt or open an authentication window after that
local exiting = false

-- Mirrors this session has already warned about, keyed by local root
local warned_unsynced = {}
local warned_disconnected = {}

-- How the status of a pushed buffer reads in vim.b.sshfs_mirror
Mirror.STATUS = {
  pending = "pending",
  pushing = "pushing",
  synced = "synced",
  conflict = "conflict",
  error = "error",
  disconnected = "disconnected",
}

local function mirror_config()
  return require("sshfs.config").get().mirror
end

local function notify_error(message)
  vim.notify("sshfs mirror: " .. message, vim.log.levels.ERROR)
end

local function notify_warn(message)
  vim.notify("sshfs mirror: " .. message, vim.log.levels.WARN)
end

---@param root string
---@param rel string
---@return string
local function local_file(root, rel)
  return root:gsub("/+$", "") .. "/" .. rel
end

---@param host_name string
---@param patterns string[]
---@return boolean
function Mirror.matches_hosts(host_name, patterns)
  for _, pattern in ipairs(patterns or {}) do
    local lua_pattern = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
    if host_name:match(lua_pattern) then return true end
  end
  return false
end

-- Exclusion ---------------------------------------------------------------------------------------------------

--- Lua pattern for an rsync glob: `**` crosses directories, `*` and `?` do not
---@param glob string
---@return string
local function glob_to_lua(glob)
  local out = {}
  local index = 1
  while index <= #glob do
    local char = glob:sub(index, index)
    if glob:sub(index, index + 1) == "**" then
      table.insert(out, ".*")
      index = index + 1
    elseif char == "*" then
      table.insert(out, "[^/]*")
    elseif char == "?" then
      table.insert(out, "[^/]")
    else
      table.insert(out, (char:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")))
    end
    index = index + 1
  end
  return table.concat(out)
end

--- Whether one rsync exclude pattern matches a path, following rsync's rules: a trailing `/` matches only
--- directories, a leading `/` anchors at the mirror root, a pattern with a `/` matches the end of the path,
--- and anything else matches the last component.
---@param pattern string
---@param path string Path relative to the mirror root
---@param is_dir boolean
---@return boolean
local function pattern_matches(pattern, path, is_dir)
  if pattern:sub(-1) == "/" then
    if not is_dir then return false end
    pattern = pattern:gsub("/+$", "")
  end
  if pattern:sub(1, 1) == "/" then return path:match("^" .. glob_to_lua(pattern:sub(2)) .. "$") ~= nil end
  -- Matching only at a component boundary at the end covers both the last-component and the end-of-path rule,
  -- since a glob without `**` cannot cross a slash
  local lua_pattern = glob_to_lua(pattern) .. "$"
  return path:match("^" .. lua_pattern) ~= nil or path:match("/" .. lua_pattern) ~= nil
end

--- Whether a path is left out of manifests and pushes: it, or a directory above it, is `.git` or excluded
---@param rel string Path relative to the mirror root
---@param excludes string[]
---@param is_dir boolean|nil Whether rel itself is a directory
---@return boolean
function Mirror.is_excluded(rel, excludes, is_dir)
  local parts = vim.split(rel, "/", { plain = true })
  for depth = 1, #parts do
    if parts[depth] == ".git" then return true end
    local path = table.concat(parts, "/", 1, depth)
    local path_is_dir = depth < #parts or is_dir == true
    for _, pattern in ipairs(excludes) do
      if pattern_matches(pattern, path, path_is_dir) then return true end
    end
  end
  return false
end

-- Manifest ---------------------------------------------------------------------------------------------------

--- Manifest value for a file: whole-second mtime and size, the two things `stat` on the server can answer
---@param stat table uv stat result
---@return string
function Mirror.manifest_entry(stat)
  return string.format("%d %d", stat.mtime.sec, stat.size)
end

---@param entry string
---@return number
local function entry_mtime(entry)
  return tonumber(entry:match("^(%d+)")) or 0
end

--- Manifest entry of a regular local file, or nil when there is none
---@param root string
---@param rel string
---@return string|nil
local function local_entry(root, rel)
  local stat = vim.uv.fs_stat(local_file(root, rel))
  if not stat or stat.type ~= "file" then return nil end
  return Mirror.manifest_entry(stat)
end

--- Map every tracked file under the mirror root to its manifest entry
--- `.git` is skipped because it is pulled but never pushed, so it never takes part in comparisons.
---@param root string
---@param excludes string[]
---@return table<string, string> snapshot
function Mirror.snapshot(root, excludes)
  local snapshot = {}

  local function walk(dir, prefix)
    for name, kind in vim.fs.dir(dir) do
      local rel = prefix .. name
      if not Mirror.is_excluded(rel, excludes, kind == "directory") then
        if kind == "directory" then
          walk(dir .. "/" .. name, rel .. "/")
        elseif kind == "file" then
          local stat = vim.uv.fs_stat(dir .. "/" .. name)
          if stat then snapshot[rel] = Mirror.manifest_entry(stat) end
        end
      end
    end
  end

  walk(root, "")
  return snapshot
end

--- Files that must not be overwritten by a pull
---@param manifest table<string, string>
---@param snapshot table<string, string> Current local state
---@param modified_rels string[] Files with unsaved buffer changes
---@return string[] dirty Sorted
function Mirror.dirty_files(manifest, snapshot, modified_rels)
  local dirty = {}
  for rel, entry in pairs(snapshot) do
    if manifest[rel] ~= entry then dirty[rel] = true end
  end
  for _, rel in ipairs(modified_rels or {}) do
    dirty[rel] = true
  end

  local list = vim.tbl_keys(dirty)
  table.sort(list)
  return list
end

--- Decide what a push of one file should do
---@param manifest_entry string|nil What the server held at the last sync
---@param local_entry_now string|nil The local file now
---@param server table Remote.stat result: {kind = "file", entry} | {kind = "absent"} | {kind = "error"}
---@return string verdict "push" | "synced" (the server already has it) | "conflict" | "error"
function Mirror.classify(manifest_entry, local_entry_now, server)
  if not server or server.kind == "error" then return "error" end
  local server_entry = server.kind == "file" and server.entry or nil
  if server_entry == manifest_entry then return "push" end
  if server_entry and server_entry == local_entry_now then return "synced" end
  -- Includes a file the server deleted since the last sync, and one it gained that the manifest never saw
  return "conflict"
end

--- Fingerprint of the refs in a local .git, to tell whether commits, branches or stashes were made locally
---@param root string
---@return string|nil fingerprint nil when there is no .git directory
function Mirror.git_fingerprint(root)
  local git_dir = local_file(root, ".git")
  if vim.fn.isdirectory(git_dir) ~= 1 then return nil end

  local lines = {}
  local function add(rel)
    local stat = vim.uv.fs_stat(git_dir .. "/" .. rel)
    if stat and stat.type == "file" then table.insert(lines, rel .. " " .. Mirror.manifest_entry(stat)) end
  end
  local function walk(rel)
    for name, kind in vim.fs.dir(git_dir .. "/" .. rel) do
      if kind == "directory" then
        walk(rel .. "/" .. name)
      else
        add(rel .. "/" .. name)
      end
    end
  end

  add("HEAD")
  add("packed-refs")
  if vim.fn.isdirectory(git_dir .. "/refs") == 1 then walk("refs") end
  table.sort(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

-- Local helpers ----------------------------------------------------------------------------------------------

---@return string[]
local function pull_excludes()
  local config = mirror_config()
  local excludes = vim.deepcopy(config.excludes)
  if not config.pull_git then table.insert(excludes, ".git") end
  return excludes
end

--- Buffers showing a mirror file, by its plain or symlink-resolved name
---@param root string
---@param rel string
---@return integer[]
local function buffers_for(root, rel)
  local path = local_file(root, rel)
  local real = vim.uv.fs_realpath(path)
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and (name == path or name == real) then table.insert(found, buf) end
  end
  return found
end

--- Relative paths of loaded buffers with unsaved changes inside the mirror
---@param root string
---@return string[]
local function modified_rels(root)
  local prefixes = { root:gsub("/+$", "") .. "/" }
  local real = vim.uv.fs_realpath(root)
  if real then table.insert(prefixes, real .. "/") end

  local rels = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      for _, prefix in ipairs(prefixes) do
        if name:sub(1, #prefix) == prefix then
          table.insert(rels, name:sub(#prefix + 1))
          break
        end
      end
    end
  end
  return rels
end

--- Show a push result on the buffers that hold the file, for statuslines
---@param root string
---@param rel string
---@param status string
local function set_buffer_status(root, rel, status)
  for _, buf in ipairs(buffers_for(root, rel)) do
    vim.b[buf].sshfs_mirror = status
  end
end

---@param path string
---@param content string
---@return boolean ok
local function write_file(path, content)
  local file = io.open(path, "w")
  if not file then return false end
  file:write(content)
  file:close()
  return true
end

---@param list string[]
---@param limit number|nil
---@return string
local function format_list(list, limit)
  limit = limit or 10
  local shown = vim.list_slice(list, 1, limit)
  return table.concat(shown, "\n") .. (#list > #shown and string.format("\n... and %d more", #list - #shown) or "")
end

-- Queue ------------------------------------------------------------------------------------------------------

local function queue_for(root)
  QUEUES[root] = QUEUES[root] or { order = {}, queued = {}, jobs = {}, running = false, inflight = {} }
  return QUEUES[root]
end

local drain
local push_batch
local prompt_conflicts

--- Run a job on a mirror once the transfers ahead of it finish
---@param root string
---@param job function fun(done: function)
local function schedule_job(root, job)
  table.insert(queue_for(root).jobs, job)
  drain(root)
end

drain = function(root)
  local queue = queue_for(root)
  if queue.running then return end

  local job = table.remove(queue.jobs, 1)
  if not job and #queue.order > 0 then
    -- Every save waiting in the queue goes out as one batch: one stat call, one rsync
    local rels = queue.order
    queue.order, queue.queued = {}, {}
    job = function(done)
      push_batch(root, rels, { prompt = true }, function(summary)
        done()
        prompt_conflicts(root, summary.conflicts)
      end)
    end
  end
  if not job then return end

  queue.running = true
  local released = false
  local function done()
    if released then return end
    released = true
    queue.running = false
    queue.inflight = {}
    drain(root)
  end

  local ok, err = pcall(job, done)
  if not ok then
    notify_error("internal error: " .. tostring(err))
    done()
  end
end

-- Push -------------------------------------------------------------------------------------------------------

--- Send files to the server with rsync and record what the server now holds
--- The manifest takes the local stat from before the transfer, because that is the version rsync read. A file
--- saved again while it was in flight therefore stays dirty and is queued again.
---@param state table
---@param rels string[]
---@param pre table<string, string> Local entries taken before the transfer
---@param record table {manifest = {}, unsynced = {}, summary = {}} filled in
---@param done function
local function transfer(state, rels, pre, record, done)
  if #rels == 0 then return done() end
  local root = state.local_path

  local include_from = vim.fn.tempname()
  if not write_file(include_from, Rsync.include_list(rels)) then
    for _, rel in ipairs(rels) do
      record.fail(rel, "could not write the rsync include list")
    end
    return done()
  end

  for _, rel in ipairs(rels) do
    set_buffer_status(root, rel, Mirror.STATUS.pushing)
  end

  Remote.run(state, function()
    return Rsync.push_files(state, include_from)
  end, { timeout = Remote.TRANSFER_TIMEOUT_MS, no_reauth = exiting }, function(obj)
    os.remove(include_from)
    if obj.code ~= 0 then
      local reason = "push failed (" .. Remote.describe_failure(obj) .. ")"
      for _, rel in ipairs(rels) do
        record.fail(rel, reason)
      end
      notify_error(reason .. ": " .. format_list(rels, 5))
      return done()
    end

    for _, rel in ipairs(rels) do
      record.manifest[rel] = pre[rel]
      if local_entry(root, rel) == pre[rel] then
        record.synced(rel)
      else
        table.insert(record.summary.requeued, rel)
      end
    end
    done()
  end)
end

--- Push files, first checking in one call that the server has not changed them since the last sync
---@param root string
---@param rels string[]
---@param opts table {force = table<string, boolean>} force: skip the check (the user chose to overwrite)
---@param callback function fun(summary: table) with synced, conflicts, errors, requeued (lists of rels)
push_batch = function(root, rels, opts, callback)
  local summary = { synced = {}, conflicts = {}, errors = {}, requeued = {} }
  local state = MirrorState.load(root)
  if not state then return callback(summary) end

  local force = opts.force or {}
  local excludes = mirror_config().excludes
  local pre, to_check, to_push = {}, {}, {}
  for _, rel in ipairs(rels) do
    local entry = not Mirror.is_excluded(rel, excludes) and not rel:find("[\r\n]") and local_entry(root, rel)
    -- A file deleted since it was saved has nothing to push
    if entry then
      pre[rel] = entry
      table.insert(force[rel] and to_push or to_check, rel)
    end
  end
  queue_for(root).inflight = vim.tbl_keys(pre)

  local record = { manifest = {}, unsynced = {}, summary = summary }
  function record.fail(rel, reason)
    table.insert(summary.errors, rel)
    record.unsynced[rel] = reason
    set_buffer_status(root, rel, Mirror.STATUS.error)
  end
  function record.synced(rel)
    table.insert(summary.synced, rel)
    record.unsynced[rel] = false
    set_buffer_status(root, rel, Mirror.STATUS.synced)
  end

  local function finish()
    MirrorState.apply(root, record.manifest, record.unsynced)
    for _, rel in ipairs(summary.requeued) do
      Mirror.enqueue(root, rel)
    end
    callback(summary)
  end

  Remote.stat(state, to_check, { no_reauth = exiting }, function(results, err)
    if not results then
      for _, rel in ipairs(to_check) do
        record.fail(rel, "could not check the server copy (" .. err .. ")")
      end
      if #to_check > 0 then notify_error("could not check the server copies (" .. err .. "); nothing was pushed") end
      return transfer(state, to_push, pre, record, finish)
    end

    -- Another instance may have pushed or pulled while the stat was in flight
    local latest = MirrorState.load(root) or state
    for _, rel in ipairs(to_check) do
      local verdict = Mirror.classify(latest.manifest[rel], pre[rel], results[rel])
      if verdict == "push" then
        table.insert(to_push, rel)
      elseif verdict == "synced" then
        record.manifest[rel] = pre[rel]
        record.synced(rel)
      elseif verdict == "conflict" then
        table.insert(summary.conflicts, rel)
        record.unsynced[rel] = "changed on the server since the last sync"
        set_buffer_status(root, rel, Mirror.STATUS.conflict)
      else
        record.fail(rel, "the server copy could not be read")
        notify_error("could not check " .. rel .. " on the server; it was not pushed")
      end
    end
    transfer(state, to_push, pre, record, finish)
  end)
end

--- Diff the local file against the server's copy in a split
local function show_diff(state, rel)
  local temp = vim.fn.tempname()
  Remote.fetch(state, rel, temp, function(ok, err)
    if not ok then return notify_error("could not fetch the server copy (" .. err .. ")") end
    -- drop reuses a window already showing the file and splits rather than abandon a modified buffer
    vim.cmd("drop " .. vim.fn.fnameescape(local_file(state.local_path, rel)))
    vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(temp))
    vim.bo.readonly = true
    vim.bo.modifiable = false
    vim.bo.bufhidden = "wipe"
  end)
end

--- Ask, one file at a time, what to do about files the server changed since the last sync
--- Runs after the batch has released the queue, so other saves are not held up by an open prompt.
---@param root string
---@param rels string[]
prompt_conflicts = function(root, rels)
  if #rels == 0 or exiting then return end
  local state = MirrorState.load(root)
  if not state then return end

  local rel = rels[1]
  local rest = vim.list_slice(rels, 2)
  local choices = { "Overwrite the server copy", "Diff against the server copy", "Cancel" }
  vim.ui.select(choices, { prompt = rel .. " changed on " .. state.host .. " since the last sync:" }, function(choice)
    if choice == choices[1] then
      schedule_job(root, function(done)
        push_batch(root, { rel }, { force = { [rel] = true } }, function()
          done()
        end)
      end)
    elseif choice == choices[2] then
      show_diff(state, rel)
    end
    prompt_conflicts(root, rest)
  end)
end

-- Registered on the first queued push, so a session that never saves into a mirror carries no exit hook.
-- Needed even with auto_unmount off: a save made just before quitting must not be lost.
local exit_hook_registered = false

local function ensure_exit_hook()
  if exit_hook_registered then return end
  exit_hook_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("sshfs_mirror_exit", { clear = true }),
    callback = function()
      Mirror.flush_on_exit(5000)
    end,
    desc = "Wait for pending mirror pushes",
  })
end

--- Queue a saved file for pushing; saves made while a push is in flight go out together in the next one
---@param root string Mirror root
---@param rel string
function Mirror.enqueue(root, rel)
  if Mirror.is_excluded(rel, mirror_config().excludes) then return end

  ensure_exit_hook()
  local queue = queue_for(root)
  if not queue.queued[rel] then
    queue.queued[rel] = true
    table.insert(queue.order, rel)
  end
  set_buffer_status(root, rel, Mirror.STATUS.pending)
  drain(root)
end

--- Whether transfers are still queued or in flight
---@param root string|nil Restrict to one mirror
---@return boolean
function Mirror.has_pending(root)
  for queue_root, queue in pairs(QUEUES) do
    if (not root or queue_root == root) and (queue.running or #queue.order > 0 or #queue.jobs > 0) then return true end
  end
  return false
end

--- Wait, bounded, for queued transfers to finish
---@param timeout_ms number
---@param root string|nil Restrict to one mirror
---@return boolean drained
function Mirror.flush(timeout_ms, root)
  return vim.wait(timeout_ms, function()
    return not Mirror.has_pending(root)
  end, 20)
end

--- Switch to exit behaviour: conflicts are no longer prompted and lost connections not re-authenticated
--- Files still queued or in flight are recorded as unsynced first, so they are reported next session even if
--- Neovim is gone before their push ends.
function Mirror.begin_exit()
  exiting = true
  for root, queue in pairs(QUEUES) do
    local unsynced = {}
    for _, rel in ipairs(vim.list_extend(vim.deepcopy(queue.order), queue.inflight)) do
      unsynced[rel] = "not pushed before Neovim exited"
    end
    if next(unsynced) then MirrorState.apply(root, {}, unsynced) end
  end
end

--- VimLeavePre: wait for pending pushes without prompting, then report what did not reach the server
---@param timeout_ms number
function Mirror.flush_on_exit(timeout_ms)
  Mirror.begin_exit()
  Mirror.flush(timeout_ms)
  for root in pairs(QUEUES) do
    Mirror.report_unsynced(root, true)
  end
end

-- Pull -------------------------------------------------------------------------------------------------------

--- Pull with the queue held: protect dirty files, transfer, then record only what the pull itself wrote
---@param root string
---@param callback function
local function run_pull(root, callback)
  local state = MirrorState.load(root)
  if not state then return callback({ ok = false, message = "no mirror state for " .. root }) end
  local excludes = mirror_config().excludes

  local before = Mirror.snapshot(root, excludes)
  local dirty = Mirror.dirty_files(state.manifest, before, modified_rels(root))

  -- A kept file is a conflict when the server changed it since the last sync too
  Remote.stat(state, dirty, { no_reauth = exiting }, function(results)
    local conflicts, unchecked = {}, {}
    for _, rel in ipairs(dirty) do
      local server = results and results[rel]
      if not server or server.kind == "error" then
        table.insert(unchecked, rel)
      elseif (server.kind == "file" and server.entry or nil) ~= state.manifest[rel] then
        table.insert(conflicts, rel)
      end
    end

    -- Re-snapshot right before the transfer, so a save made during the check is protected as well
    local latest = MirrorState.load(root) or state
    before = Mirror.snapshot(root, excludes)
    local kept = Mirror.dirty_files(latest.manifest, before, vim.list_extend(modified_rels(root), dirty))
    local kept_set = {}
    for _, rel in ipairs(kept) do
      kept_set[rel] = true
    end

    local skip_from
    if #kept > 0 then
      skip_from = vim.fn.tempname()
      if not write_file(skip_from, Rsync.skip_list(kept)) then
        return callback({ ok = false, message = "could not write the rsync skip list" })
      end
    end

    vim.fn.mkdir(root, "p")
    local started = os.time()
    Remote.run(latest, function()
      return Rsync.pull(latest, pull_excludes(), skip_from)
    end, { timeout = Remote.TRANSFER_TIMEOUT_MS, no_reauth = exiting }, function(obj)
      if skip_from then os.remove(skip_from) end
      if obj.code ~= 0 then
        return callback({ ok = false, message = "rsync pull failed (" .. Remote.describe_failure(obj) .. ")" })
      end

      -- A file changed by the pull carries the server's mtime, which predates the pull. One stamped later
      -- may be a save made during the transfer, so it is recorded only if the server holds exactly that.
      local after = Mirror.snapshot(root, excludes)
      local changes, recent = {}, {}
      for rel, entry in pairs(after) do
        if not kept_set[rel] and entry ~= before[rel] then
          if entry_mtime(entry) < started then
            changes[rel] = entry
          else
            table.insert(recent, rel)
          end
        end
      end

      Remote.stat(latest, recent, { no_reauth = exiting }, function(recent_results)
        for _, rel in ipairs(recent) do
          local server = recent_results and recent_results[rel]
          if server and server.kind == "file" and server.entry == after[rel] then changes[rel] = after[rel] end
        end

        MirrorState.update(root, function(fresh)
          for rel, entry in pairs(changes) do
            fresh.manifest[rel] = entry
          end
          fresh.git_fingerprint = Mirror.git_fingerprint(root)
        end)
        vim.cmd("silent! checktime")
        callback({ ok = true, kept = kept, conflicts = conflicts, unchecked = unchecked })
      end)
    end)
  end)
end

--- Pull the remote tree, leaving locally edited files alone
---@param root string Mirror root
---@param callback function fun(result: table) with ok, message, kept (files left local), conflicts (kept files
--- the server also changed since the last sync), unchecked (kept files whose server copy could not be read)
function Mirror.pull(root, callback)
  schedule_job(root, function(done)
    run_pull(root, function(result)
      done()
      callback(result)
    end)
  end)
end

--- Tell the user how a pull went
---@param host string
---@param result table Mirror.pull result
function Mirror.notify_pull(host, result)
  if not result.ok then return notify_error("pull failed: " .. result.message) end
  vim.notify(string.format("Pulled %s (%d local file(s) kept)", host, #result.kept), vim.log.levels.INFO)
  if #result.conflicts > 0 then
    notify_warn("kept local copies that also changed on the server:\n" .. format_list(result.conflicts))
  end
  if #result.unchecked > 0 then
    notify_warn("kept local copies whose server copy could not be checked:\n" .. format_list(result.unchecked))
  end
end

-- Push all ---------------------------------------------------------------------------------------------------

--- Ask whether to overwrite server files that changed since the last sync
---@param host string
---@param conflicts string[]
---@param callback function fun(choice: "overwrite"|"skip"|nil) nil: cancel
local function ask_conflicts(host, conflicts, callback)
  -- Exiting: never prompt; the conflicts stay dirty and are recorded as unsynced
  if #conflicts == 0 or exiting then return callback("skip") end
  local choices = { "Overwrite them", "Push the rest, keep the server copies", "Cancel" }
  local prompt =
    string.format("%d file(s) changed on %s since the last sync:\n%s", #conflicts, host, format_list(conflicts))
  vim.ui.select(choices, { prompt = prompt }, function(choice)
    if choice == choices[1] then return callback("overwrite") end
    if choice == choices[2] then return callback("skip") end
    callback(nil)
  end)
end

--- Ask whether to delete server files that were removed locally
---@param host string
---@param rels string[]
---@param callback function fun(choice: "delete"|"keep"|nil) nil: cancel
local function ask_delete(host, rels, callback)
  if #rels == 0 or exiting then return callback("keep") end
  local choices = { "Delete on the server", "Keep them on the server", "Cancel" }
  local prompt = string.format("Delete %d file(s) on %s that you removed locally?\n%s", #rels, host, format_list(rels))
  vim.ui.select(choices, { prompt = prompt }, function(choice)
    if choice == choices[1] then return callback("delete") end
    if choice == choices[2] then return callback("keep") end
    callback(nil)
  end)
end

--- Push every file changed locally since the last sync, with the same server check as a save
--- With delete, server files removed locally are deleted too, but only ones the manifest recorded and the
--- server still holds unchanged: never excluded paths, .git, or files the mirror never pulled.
---@param root string
---@param opts table {delete = boolean}
---@param callback function fun(result: table) with ok, message, nothing, pushed, deleted, conflicts, errors
local function run_push_all(root, opts, callback)
  local state = MirrorState.load(root)
  if not state then return callback({ ok = false, message = "no mirror state for " .. root }) end
  local excludes = mirror_config().excludes

  local snapshot = Mirror.snapshot(root, excludes)
  local dirty = Mirror.dirty_files(state.manifest, snapshot, {})
  local removed = {}
  if opts.delete then
    for rel in pairs(state.manifest) do
      local gone = not snapshot[rel] and not vim.uv.fs_lstat(local_file(root, rel))
      if gone and not Mirror.is_excluded(rel, excludes) then table.insert(removed, rel) end
    end
    table.sort(removed)
  end
  if #dirty == 0 and #removed == 0 then return callback({ ok = true, nothing = true }) end

  Remote.stat(state, vim.list_extend(vim.deepcopy(dirty), removed), { no_reauth = exiting }, function(results, err)
    if not results then
      return callback({ ok = false, message = "could not check the server copies (" .. err .. ")" })
    end

    local latest = MirrorState.load(root) or state
    local to_push, conflicts, errors, synced = {}, {}, {}, {}
    for _, rel in ipairs(dirty) do
      local verdict = Mirror.classify(latest.manifest[rel], snapshot[rel], results[rel])
      if verdict == "push" then
        table.insert(to_push, rel)
      elseif verdict == "synced" then
        synced[rel] = snapshot[rel]
      elseif verdict == "conflict" then
        table.insert(conflicts, rel)
      else
        table.insert(errors, rel)
      end
    end

    local deletable, already_gone = {}, {}
    for _, rel in ipairs(removed) do
      local server = results[rel]
      if server.kind == "file" and server.entry == latest.manifest[rel] then
        table.insert(deletable, { rel = rel, expected = server.entry })
      elseif server.kind == "absent" then
        already_gone[rel] = false
      else
        table.insert(server.kind == "error" and errors or conflicts, rel)
      end
    end
    MirrorState.apply(root, vim.tbl_extend("force", synced, already_gone), {})

    local prompted = #conflicts > 0
    ask_conflicts(state.host, conflicts, function(conflict_choice)
      if not conflict_choice then return callback({ ok = false, message = "cancelled" }) end
      local delete_rels = vim.tbl_map(function(item)
        return item.rel
      end, deletable)
      prompted = prompted or #deletable > 0

      ask_delete(state.host, delete_rels, function(delete_choice)
        if not delete_choice then return callback({ ok = false, message = "cancelled" }) end

        -- Without a prompt the check above is current; after one, the files not being overwritten are checked again
        local force = {}
        for _, rel in ipairs(to_push) do
          force[rel] = not prompted
        end
        local skipped = {}
        for _, rel in ipairs(conflicts) do
          if conflict_choice == "overwrite" and snapshot[rel] then
            table.insert(to_push, rel)
            force[rel] = true
          else
            table.insert(skipped, rel)
          end
        end

        if #skipped > 0 then
          local reasons = {}
          for _, rel in ipairs(skipped) do
            reasons[rel] = "changed on the server since the last sync"
          end
          MirrorState.apply(root, {}, reasons)
        end

        push_batch(root, to_push, { force = force }, function(summary)
          local result = {
            ok = true,
            pushed = #summary.synced,
            deleted = 0,
            conflicts = vim.list_extend(skipped, summary.conflicts),
            errors = vim.list_extend(errors, summary.errors),
          }
          for _, rel in ipairs(result.conflicts) do
            set_buffer_status(root, rel, Mirror.STATUS.conflict)
          end
          if delete_choice ~= "delete" or #deletable == 0 then return callback(result) end

          Remote.delete(latest, deletable, { no_reauth = exiting }, function(answers, delete_err)
            if not answers then
              vim.list_extend(result.errors, delete_rels)
              notify_error("delete failed (" .. delete_err .. ")")
              return callback(result)
            end
            local dropped = {}
            for _, rel in ipairs(delete_rels) do
              if answers[rel] == "D" or answers[rel] == "A" then
                dropped[rel] = false
                result.deleted = result.deleted + (answers[rel] == "D" and 1 or 0)
              elseif answers[rel] == "C" then
                table.insert(result.conflicts, rel)
              else
                table.insert(result.errors, rel)
              end
            end
            MirrorState.apply(root, dropped, {})
            callback(result)
          end)
        end)
      end)
    end)
  end)
end

--- Push every locally changed file (see run_push_all), after transfers already queued
---@param root string
---@param opts table {delete = boolean}
---@param callback function
function Mirror.push_all(root, opts, callback)
  schedule_job(root, function(done)
    run_push_all(root, opts, function(result)
      done()
      callback(result)
    end)
  end)
end

-- Unsynced files ---------------------------------------------------------------------------------------------

--- Warn about files a previous push could not deliver, forgetting those that are no longer dirty
---@param root string
---@param force boolean|nil Warn even if this session already did
function Mirror.report_unsynced(root, force)
  local state = MirrorState.load(root)
  if not state or next(state.unsynced) == nil then return end

  local still, cleared = {}, {}
  for rel, reason in pairs(state.unsynced) do
    if local_entry(root, rel) ~= state.manifest[rel] then
      table.insert(still, rel .. " (" .. reason .. ")")
    else
      cleared[rel] = false
    end
  end
  if next(cleared) then MirrorState.apply(root, {}, cleared) end
  if #still == 0 or (warned_unsynced[root] and not force) then return end

  warned_unsynced[root] = true
  table.sort(still)
  local message = string.format(
    "%d file(s) in the %s mirror are not on the server; :SSHMirrorPush sends them:\n%s",
    #still,
    state.host,
    format_list(still)
  )
  Logger.warn(message)
  notify_warn(message)
end

-- Paths and autocommands -------------------------------------------------------------------------------------

--- The mirror base directory, plus its symlink-resolved form when that differs
---@return string[] prefixes Each ending in a slash
local function base_prefixes()
  local base = vim.fs.normalize(mirror_config().base_dir):gsub("/+$", "")
  local prefixes = { base .. "/" }
  local real = vim.uv.fs_realpath(base)
  if real and real ~= base then table.insert(prefixes, real .. "/") end
  return prefixes, base
end

--- Find the mirror whose root contains a path
---@param path string Absolute file path
---@return table|nil state
---@return string|nil rel
function Mirror.find_for_path(path)
  path = vim.fs.normalize(path)
  local prefixes, base = base_prefixes()
  for _, prefix in ipairs(prefixes) do
    if path:sub(1, #prefix) == prefix then
      local dir_name, rel = path:sub(#prefix + 1):match("^([^/]+)/(.+)$")
      if not dir_name then return nil end
      -- States are keyed by the configured, unresolved path
      local state = MirrorState.load(base .. "/" .. dir_name)
      if state then return state, rel end
      return nil
    end
  end
  return nil
end

--- BufWritePost entry point
---@param path string Absolute path of the written file
---@param buf integer|nil The written buffer
function Mirror.on_write(path, buf)
  if not mirror_config().push_on_save then return end
  local state, rel = Mirror.find_for_path(path)
  if not state then return end

  if state.connected == false then
    if buf then vim.b[buf].sshfs_mirror = Mirror.STATUS.disconnected end
    if not warned_disconnected[state.local_path] then
      warned_disconnected[state.local_path] = true
      notify_warn("the " .. state.host .. " mirror is disconnected, so saves stay local; :SSHMirror reconnects it")
    end
    return
  end
  Mirror.enqueue(state.local_path, rel)
end

--- Mark mirrors whose owning Neovim is gone (crashed, killed, or exited without disconnecting) as disconnected
function Mirror.reconcile()
  local Connections = require("sshfs.lib.connections")
  for _, state in ipairs(MirrorState.list()) do
    if state.connected ~= false and not Connections.is_mirror_live(state) then
      MirrorState.update(state.local_path, function(fresh)
        fresh.connected = false
      end)
    end
  end
end

--- Register the editor hooks mirror mode needs, after settling stale mirrors
function Mirror.setup_autocommands()
  Mirror.reconcile()
  local group = vim.api.nvim_create_augroup("sshfs_mirror", { clear = true })
  local registered = {}

  -- Register in lockfile when opening files from a mirror (for instances that didn't create it)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local buf_path = vim.api.nvim_buf_get_name(ev.buf)
      if buf_path == "" then return end
      local state = Mirror.find_for_path(buf_path)
      if not state or registered[state.local_path] then return end

      registered[state.local_path] = true
      if state.connected ~= false then require("sshfs.lib.lockfile").register(state.local_path) end
      Mirror.report_unsynced(state.local_path)
    end,
    desc = "Register in lockfile when accessing an sshfs mirror",
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local path = vim.api.nvim_buf_get_name(ev.buf)
      if path ~= "" then Mirror.on_write(path, ev.buf) end
    end,
    desc = "Push saved files in an sshfs mirror",
  })
end

-- Connect and disconnect -------------------------------------------------------------------------------------

--- Establish a mirror: authenticate, resolve the remote path, check rsync, and pull
---@param host table Host object (name, user, port)
---@param remote_path_suffix string Requested remote path, possibly starting with ~
---@param root string Mirror root
---@param callback function fun(result: table) with success, message, resolved_path
function Mirror.open(host, remote_path_suffix, root, callback)
  local Lockfile = require("sshfs.lib.lockfile")
  local function fail(message)
    callback({ success = false, message = message })
  end

  if vim.fn.executable("rsync") ~= 1 then return fail("rsync is not installed locally (mirror mode needs it)") end

  require("sshfs.lib.sshfs").authenticate(host, function(auth)
    if not auth.success then return fail(auth.message) end

    local function with_remote_path(remote_path)
      local fields =
        { host = host.name, user = host.user, port = host.port, remote_path = remote_path, local_path = root }
      local supported, unsupported_reason = Rsync.check_supported(fields)
      if not supported then return fail(unsupported_reason) end

      Remote.check_rsync(fields, function(ok, message)
        if not ok then return fail(message) end

        -- Registered before the state says connected, so a starting instance never reconciles it away
        Lockfile.register(root)
        local previous = MirrorState.load(root)
        if previous then
          MirrorState.update(root, function(state)
            state.connected = true
          end)
        else
          MirrorState.save(vim.tbl_extend("force", fields, { manifest = {}, unsynced = {}, connected = true }))
        end
        warned_disconnected[root] = nil

        vim.notify("Mirroring " .. host.name .. ":" .. remote_path .. "...", vim.log.levels.INFO)
        Mirror.pull(root, function(result)
          if not result.ok then
            Lockfile.unregister(root)
            -- A kept manifest is worth more than the failed attempt; only a brand-new mirror is discarded
            if previous then
              MirrorState.update(root, function(state)
                state.connected = false
              end)
            else
              MirrorState.delete(root)
            end
            return fail(result.message)
          end
          if #result.kept > 0 then Mirror.notify_pull(host.name, result) end
          Mirror.report_unsynced(root, true)
          callback({ success = true, resolved_path = remote_path })
        end)
      end)
    end

    -- ~, ~/x and ~user/x are resolved on the server; the account name goes into a shell command, so it is vetted
    local tilde_user, rest = remote_path_suffix:match("^~([^/]*)(.*)$")
    if not tilde_user then return with_remote_path(remote_path_suffix) end
    if tilde_user ~= "" and not tilde_user:match("^[%w._-]+$") then
      return fail("cannot resolve the home directory of '" .. tilde_user .. "'")
    end
    require("sshfs.lib.ssh").get_remote_home(host, function(home, err)
      if not home then return fail("could not resolve the remote home directory: " .. (err or "unknown error")) end
      with_remote_path(home .. rest)
    end, tilde_user ~= "" and tilde_user or nil)
  end)
end

--- Why deleting the local copy would lose work, if it would
---@param state table
---@return string|nil reason
function Mirror.local_only_work(state)
  local root = state.local_path
  local snapshot = Mirror.snapshot(root, mirror_config().excludes)
  if #Mirror.dirty_files(state.manifest, snapshot, modified_rels(root)) > 0 or next(state.unsynced) then
    return "it has local files that are not on the server"
  end
  local fingerprint = Mirror.git_fingerprint(root)
  if fingerprint and fingerprint ~= state.git_fingerprint then
    return "its .git has local commits, branches or stashes since the last pull"
  end
  return nil
end

return Mirror
