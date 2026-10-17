-- lua/sshfs/lib/mirror_remote.lua
-- Everything mirror mode runs against the server: rsync transfers and small batched shell scripts over ssh.
-- Every call is non-interactive and time-limited. When the ControlMaster socket has gone (it expires after
-- connections.control_persist without a mount to keep it busy), the host is re-authenticated once and the
-- call retried.

local Remote = {}
local Logger = require("sshfs.lib.logger")

-- Short calls (stat, delete, fetch) and whole-tree transfers
Remote.COMMAND_TIMEOUT_MS = 60 * 1000
Remote.TRANSFER_TIMEOUT_MS = 60 * 60 * 1000

-- vim.system reports a timed-out command with this code after killing it
local TIMEOUT_CODE = 124

-- Hosts being re-authenticated, each with the callbacks waiting on it
local REAUTH_WAITERS = {}

--- Host object the ssh builders expect, from a mirror state
---@param state table
---@return table
function Remote.ssh_host(state)
  return { name = state.host, user = state.user, port = state.port }
end

---@param obj table vim.system result
---@return string
function Remote.describe_failure(obj)
  if obj.code == TIMEOUT_CODE then return "timed out" end
  local text = vim.trim(obj.stderr or "")
  if text == "" then text = vim.trim(type(obj.stdout) == "string" and obj.stdout or "") end
  return string.format("exit %d%s", obj.code, text ~= "" and (": " .. text) or "")
end

--- Whether a failure came from ssh itself rather than the command it ran
--- ssh exits 255 on its own errors; rsync reports a dead transport with its own codes and this message.
---@param obj table vim.system result
---@return boolean
function Remote.is_transport_failure(obj)
  if obj.code == 255 then return true end
  local stderr = obj.stderr or ""
  return obj.code ~= 0 and stderr:find("connection unexpectedly closed", 1, true) ~= nil
end

---@param cmd string[]
---@param opts table {stdin = string|nil, timeout = number|nil, text = boolean|nil}
---@param callback function fun(obj: table)
local function spawn(cmd, opts, callback)
  Logger.debug("Running mirror command", function()
    return { command = table.concat(cmd, " ") }
  end)
  local ok, err = pcall(vim.system, cmd, {
    text = opts.text ~= false,
    stdin = opts.stdin,
    timeout = opts.timeout or Remote.COMMAND_TIMEOUT_MS,
  }, function(obj)
    vim.schedule(function()
      callback(obj)
    end)
  end)
  if not ok then vim.schedule(function()
    callback({ code = -1, stdout = "", stderr = tostring(err) })
  end) end
end

--- Re-create the ControlMaster for a host, sharing one attempt between concurrent callers
---@param state table Mirror state
---@param callback function fun(ok: boolean)
local function reauthenticate(state, callback)
  local key = (state.user or "") .. "@" .. state.host .. ":" .. tostring(state.port or "")
  if REAUTH_WAITERS[key] then return table.insert(REAUTH_WAITERS[key], callback) end
  REAUTH_WAITERS[key] = { callback }

  Logger.debug("Mirror connection lost; re-authenticating", { host = state.host })
  require("sshfs.lib.sshfs").authenticate(Remote.ssh_host(state), function(result)
    local waiters = REAUTH_WAITERS[key]
    REAUTH_WAITERS[key] = nil
    for _, waiter in ipairs(waiters) do
      waiter(result.success == true)
    end
  end)
end

--- Run a remote command, re-authenticating and retrying once if the connection has gone
---@param state table Mirror state
---@param build function fun(): string[] Builds the command (rebuilt for the retry)
---@param opts table {stdin, timeout, text, no_reauth = boolean} no_reauth: fail instead (used while exiting)
---@param callback function fun(obj: table)
function Remote.run(state, build, opts, callback)
  local function attempt(retried)
    spawn(build(), opts, function(obj)
      if retried or opts.no_reauth or not Remote.is_transport_failure(obj) then return callback(obj) end
      reauthenticate(state, function(ok)
        if not ok then return callback(obj) end
        attempt(true)
      end)
    end)
  end
  attempt(false)
end

-- Remote scripts --------------------------------------------------------------------------------------------
-- Run under `sh -c` so the user's login shell (csh, fish) only has to pass one single-quoted word. Paths
-- arrive on stdin, one per line after the remote root, so they never meet any shell quoting. Each answer
-- line carries a marker, so a login script that prints to stdout cannot be mistaken for one.

local STAT = 's=$(stat -c "%Y %s" -- "$p" 2>/dev/null || stat -f "%m %z" -- "$p" 2>/dev/null)'

-- One line per path: F <mtime> <size> for a regular file, A when it is absent (its nearest existing
-- ancestor is a readable directory; a relative root climbs to .), E for anything else (unreadable, not a regular file, stat failed).
local STAT_SCRIPT = table.concat({
  'IFS= read -r root; while IFS= read -r rel; do p="$root/$rel";',
  'if [ -e "$p" ]; then if [ -f "$p" ] && ' .. STAT .. '; then echo "SSHFS_STAT F $s";',
  'else echo "SSHFS_STAT E"; fi;',
  'else d=${p%/*}; while [ -n "$d" ] && ! [ -e "$d" ]; do case $d in */*) d=${d%/*};; *) d=.;; esac; done; d=${d:-/};',
  'if [ -d "$d" ] && [ -x "$d" ]; then echo "SSHFS_STAT A"; else echo "SSHFS_STAT E"; fi; fi; done',
}, " ")

-- Pairs of lines (expected "<mtime> <size>", path). Deletes only a file still matching what was expected:
-- D deleted, A already absent, C changed since (left alone), E failed.
local DELETE_SCRIPT = table.concat({
  'IFS= read -r root; while IFS= read -r want && IFS= read -r rel; do p="$root/$rel";',
  'if [ -f "$p" ] && ' .. STAT .. ' && [ "$s" = "$want" ]; then',
  'if rm -f -- "$p"; then echo "SSHFS_RM D"; else echo "SSHFS_RM E"; fi;',
  'elif [ -e "$p" ]; then echo "SSHFS_RM C"; else echo "SSHFS_RM A"; fi; done',
}, " ")

local FETCH_SCRIPT = 'IFS= read -r root; IFS= read -r rel; exec cat -- "$root/$rel"'

---@param script string
---@return string
local function sh_command(script)
  return "sh -c '" .. script .. "'"
end

---@param state table
---@param lines string[]
---@return string
local function stdin_for(state, lines)
  return table.concat(vim.list_extend({ (state.remote_path:gsub("/+$", "")) }, lines), "\n") .. "\n"
end

--- Answer lines with a marker, in order
---@param output string
---@param marker string
---@return string[]
local function marked_lines(output, marker)
  local answers = {}
  for line in output:gmatch("[^\r\n]+") do
    local answer = line:match("^" .. marker .. " (.*)$")
    if answer then table.insert(answers, answer) end
  end
  return answers
end

--- Parse the stat script's answers
---@param output string
---@param rels string[] The paths that were asked about, in order
---@return table<string, table>|nil results rel -> {kind = "file", entry = "sec size"} | {kind = "absent"} | {kind = "error"}
---@return string|nil err When the output does not answer every path
function Remote.parse_stat(output, rels)
  local answers = marked_lines(output, "SSHFS_STAT")
  if #answers ~= #rels then
    return nil, string.format("unexpected stat output (%d answers for %d files)", #answers, #rels)
  end

  local results = {}
  for index, rel in ipairs(rels) do
    local entry = answers[index]:match("^F (%d+ %d+)$")
    if entry then
      results[rel] = { kind = "file", entry = entry }
    elseif answers[index] == "A" then
      results[rel] = { kind = "absent" }
    else
      results[rel] = { kind = "error" }
    end
  end
  return results
end

--- Read the server's `sec size` entry for many files in one ssh call
---@param state table Mirror state
---@param rels string[]
---@param opts table {no_reauth = boolean}
---@param callback function fun(results: table|nil, err: string|nil) see Remote.parse_stat
function Remote.stat(state, rels, opts, callback)
  if #rels == 0 then
    return vim.schedule(function()
      callback({})
    end)
  end

  local Ssh = require("sshfs.lib.ssh")
  Remote.run(state, function()
    return Ssh.build_exec_command(Remote.ssh_host(state), sh_command(STAT_SCRIPT))
  end, { stdin = stdin_for(state, rels), no_reauth = opts.no_reauth }, function(obj)
    if obj.code ~= 0 then return callback(nil, Remote.describe_failure(obj)) end
    callback(Remote.parse_stat(obj.stdout or "", rels))
  end)
end

--- Delete server files, each only if it still matches its expected entry
---@param state table Mirror state
---@param items table[] {rel = string, expected = "sec size"}
---@param opts table {no_reauth = boolean}
---@param callback function fun(results: table<string, string>|nil, err: string|nil) rel -> "D"|"A"|"C"|"E"
function Remote.delete(state, items, opts, callback)
  local Ssh = require("sshfs.lib.ssh")
  local lines, rels = {}, {}
  for _, item in ipairs(items) do
    vim.list_extend(lines, { item.expected, item.rel })
    table.insert(rels, item.rel)
  end

  Remote.run(state, function()
    return Ssh.build_exec_command(Remote.ssh_host(state), sh_command(DELETE_SCRIPT))
  end, { stdin = stdin_for(state, lines), no_reauth = opts.no_reauth }, function(obj)
    if obj.code ~= 0 then return callback(nil, Remote.describe_failure(obj)) end
    local answers = marked_lines(obj.stdout or "", "SSHFS_RM")
    if #answers ~= #rels then return callback(nil, "unexpected delete output") end
    local results = {}
    for index, rel in ipairs(rels) do
      results[rel] = answers[index]
    end
    callback(results)
  end)
end

--- Copy one server file to a local path (for diffing)
---@param state table Mirror state
---@param rel string
---@param dest string
---@param callback function fun(ok: boolean, err: string|nil)
function Remote.fetch(state, rel, dest, callback)
  local Ssh = require("sshfs.lib.ssh")
  Remote.run(state, function()
    return Ssh.build_exec_command(Remote.ssh_host(state), sh_command(FETCH_SCRIPT))
  end, { stdin = stdin_for(state, { rel }), text = false }, function(obj)
    if obj.code ~= 0 then return callback(false, Remote.describe_failure(obj)) end
    local file = io.open(dest, "wb")
    if not file then return callback(false, "cannot write " .. dest) end
    file:write(obj.stdout or "")
    file:close()
    callback(true)
  end)
end

--- Confirm rsync exists on the server
---@param state table Mirror state or host fields (host, user, port)
---@param callback function fun(ok: boolean, message: string|nil)
function Remote.check_rsync(state, callback)
  local Ssh = require("sshfs.lib.ssh")
  Remote.run(state, function()
    return Ssh.build_exec_command(Remote.ssh_host(state), "command -v rsync")
  end, {}, function(obj)
    if obj.code == 0 then return callback(true) end
    if Remote.is_transport_failure(obj) then
      return callback(false, "could not reach " .. state.host .. " (" .. Remote.describe_failure(obj) .. ")")
    end
    callback(false, "rsync is not installed on " .. state.host .. " (mirror mode needs it on both ends)")
  end)
end

return Remote
