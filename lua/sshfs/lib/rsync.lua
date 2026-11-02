-- lua/sshfs/lib/rsync.lua
-- Pure rsync command builders for mirror mode, plus detection of the local rsync.
-- Only flags shared by GNU rsync and macOS's openrsync are used: no --info, --mkpath, -i or --files-from.
-- Files are pushed with include rules rather than -R, so new parent directories need nothing special.

local Rsync = {}

local CORE_FLAGS = "-rlptz"

-- A push names its directories only to reach the files inside them, so it must not change them: without -p
-- an existing directory or file keeps its server permissions, and new ones get the local mode under the umask
local PUSH_FLAGS = "-rltz"

-- Characters that never need quoting, in a remote path or an -e argument
local SAFE_CHARS = "^[%w%-%._/:+@,=%%~]*$"

local detected = nil

--- Identify the local rsync, which decides how remote paths must be passed
--- * native: GNU 3.2.4+ escapes remote arguments itself
--- * protect: GNU 3.0 to 3.2.3 needs -s (--protect-args), which older rsyncs and openrsync lack
--- * shell: openrsync and GNU before 3.0 hand the path to the remote shell as is, so it is escaped here
--- * unknown: an unrecognised --version; paths that need escaping are refused
---@return table info {kind = "gnu"|"openrsync"|"unknown", version = string|nil, remote_args = string}
function Rsync.detect()
  if detected then return detected end

  local ok, obj = pcall(function()
    return vim.system({ "rsync", "--version" }, { text = true, timeout = 5000 }):wait()
  end)
  local output = ok and ((obj.stdout or "") .. (obj.stderr or "")) or ""

  if output:lower():find("openrsync", 1, true) then
    detected = { kind = "openrsync", remote_args = "shell" }
  else
    local major, minor, patch = output:match("rsync%s+version%s+v?(%d+)%.(%d+)%.?(%d*)")
    if major then
      local number = tonumber(major) * 10000 + tonumber(minor) * 100 + (tonumber(patch) or 0)
      local remote_args = number >= 30204 and "native" or number >= 30000 and "protect" or "shell"
      detected = { kind = "gnu", version = major .. "." .. minor .. "." .. patch, remote_args = remote_args }
    else
      detected = { kind = "unknown", remote_args = "unknown" }
    end
  end
  return detected
end

--- Quote one -e argument the way rsync splits its remote-shell string (a doubled quote is a literal one)
---@param arg string
---@return string
local function quote_rsh_arg(arg)
  if arg:match(SAFE_CHARS) then return arg end
  return "'" .. arg:gsub("'", "''") .. "'"
end

--- Remote-shell argument that rides the ControlMaster socket, never prompting
---@param conn table Connection with optional port
---@return string
local function transport(conn)
  local args = require("sshfs.lib.ssh").build_transport_args(conn.port)
  return table.concat(vim.tbl_map(quote_rsh_arg, args), " ")
end

--- Escape a remote path for the remote login shell
---@param path string
---@return string
local function shell_escape(path)
  return (path:gsub("[^%w%-%._/:+@,=%%~]", "\\%0"))
end

---@param conn table Connection with host, optional user, remote_path
---@return string spec "user@host:/remote/" with a trailing slash
local function remote_root(conn)
  local target = conn.user and (conn.user .. "@" .. conn.host) or conn.host
  local path = conn.remote_path:gsub("/+$", "") .. "/"
  -- A relative path that starts with a dash would read as an option on the server side
  if not path:match("^[/~]") then path = "./" .. path end
  if Rsync.detect().remote_args == "shell" then path = shell_escape(path) end
  return target .. ":" .. path
end

--- Whether this rsync can pass the connection's remote path intact
---@param conn table Connection with remote_path
---@return boolean ok
---@return string|nil err
function Rsync.check_supported(conn)
  if conn.remote_path:find("[\r\n]") then return false, "remote paths with line breaks are not supported" end
  if Rsync.detect().remote_args == "unknown" and not conn.remote_path:match(SAFE_CHARS) then
    return false, "unrecognised rsync version; cannot safely pass the remote path " .. conn.remote_path
  end
  return true
end

---@param conn table Connection with local_path
---@return string
local function local_root(conn)
  return conn.local_path:gsub("/+$", "") .. "/"
end

---@param excludes string[]
---@return string[]
local function exclude_args(excludes)
  local args = {}
  for _, pattern in ipairs(excludes or {}) do
    table.insert(args, "--exclude=" .. pattern)
  end
  return args
end

--- The flags every transfer shares, then user options last so they can override them
---@param core string The short-flag group
---@return string[]
local function base_flags(core)
  local args = { core }
  if Rsync.detect().remote_args == "protect" then table.insert(args, "-s") end
  local mirror = require("sshfs.config").get().mirror or {}
  return vim.list_extend(args, vim.deepcopy(mirror.rsync_options or {}))
end

---@param ... string[]
---@return string[]
local function join(...)
  local command = { "rsync" }
  for _, part in ipairs({ ... }) do
    vim.list_extend(command, part)
  end
  return command
end

--- rsync filter pattern that matches exactly one path below the transfer root
--- rsync reads a backslash as an escape only when the pattern also has a wildcard, so plain names stay as they are.
---@param rel string
---@return string
function Rsync.literal_pattern(rel)
  if not rel:find("[%*%?%[]") then return "/" .. rel end
  return "/" .. rel:gsub("[\\%*%?%[]", "\\%0")
end

--- Include rules for pushing exactly these files: each file plus every directory above it
---@param rels string[]
---@return string content
function Rsync.include_list(rels)
  local seen, lines = {}, {}
  local function add(line)
    if seen[line] then return end
    seen[line] = true
    table.insert(lines, line)
  end
  for _, rel in ipairs(rels) do
    local parts = vim.split(rel, "/", { plain = true })
    for depth = 1, #parts - 1 do
      add(Rsync.literal_pattern(table.concat(parts, "/", 1, depth)) .. "/")
    end
    add(Rsync.literal_pattern(rel))
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Exclude rules that leave exactly these files untouched by a pull
---@param rels string[]
---@return string content
function Rsync.skip_list(rels)
  return table.concat(vim.tbl_map(Rsync.literal_pattern, rels), "\n") .. "\n"
end

--- Pull the remote tree into the local one
---@param conn table {host, user, port, remote_path, local_path}
---@param excludes string[] rsync exclude patterns
---@param skip_from string|nil File listing paths to leave alone (locally edited files)
---@return string[] command
function Rsync.pull(conn, excludes, skip_from)
  local skip = skip_from and { "--exclude-from=" .. skip_from } or {}
  -- --update keeps a file saved while the pull runs: its mtime is newer than the server copy's
  return join(base_flags(CORE_FLAGS), { "--update" }, exclude_args(excludes), skip, { "-e", transport(conn) }, {
    remote_root(conn),
    local_root(conn),
  })
end

--- Push exactly the files named in an include list (see Rsync.include_list); nothing else is touched
---@param conn table
---@param include_from string File holding the include rules
---@return string[] command
function Rsync.push_files(conn, include_from)
  -- Keeps the server's directory mtimes. openrsync is not known to accept --omit-dir-times, so there the
  -- directories on the path of a pushed file still take the local mtime.
  local keep_dir_times = Rsync.detect().kind == "gnu" and { "--omit-dir-times" } or {}
  return join(
    base_flags(PUSH_FLAGS),
    keep_dir_times,
    { "--exclude=.git", "--include-from=" .. include_from, "--exclude=*" },
    { "-e", transport(conn) },
    { local_root(conn), remote_root(conn) }
  )
end

return Rsync
