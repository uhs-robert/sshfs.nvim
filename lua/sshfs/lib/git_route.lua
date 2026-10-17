-- lua/sshfs/lib/git_route.lua
-- Runs git for paths under an sshfs mount on the server instead of over FUSE.
--
-- A generated `git` wrapper script sits first on Neovim's PATH (so only Neovim's children see it).
-- It consults one `.map` file per mount, written here, to decide whether a command can be routed.
-- The routing rules live in git_route_wrapper.sh; this module owns generating it and the map files.

local GitRoute = {}
local Logger = require("sshfs.lib.logger")

local WRAPPER_TEMPLATE = "lua/sshfs/lib/git_route_wrapper.sh"

--- The wrapper bakes in this instance's real git and ssh options, so each Neovim gets its own
--- bin dir (named by pid) instead of the last instance to start deciding for all. Maps carry only
--- mount facts and stay shared.
---@return table paths root, bin_dir, wrapper and map_dir (maps live directly in root)
function GitRoute.paths()
  local root = vim.fn.stdpath("cache") .. "/sshfs/git"
  local bin_dir = root .. "/bin/" .. vim.uv.os_getpid()
  return { root = root, bin_dir = bin_dir, wrapper = bin_dir .. "/git", map_dir = root }
end

---@return boolean enabled True when routing is on and the platform has a POSIX sh
function GitRoute.enabled()
  local git_opts = require("sshfs.config").get().git or {}
  return git_opts.route_over_ssh ~= false and vim.fn.has("win32") == 0
end

local function sh_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function split_path(path_value)
  return vim.split(path_value or "", ":", { plain = true, trimempty = true })
end

--- Drop every wrapper bin dir from a PATH value, not just this instance's: a parent Neovim's dir
--- is inherited by nested nvim, $EDITOR and tmux servers, and must never be taken for the real git.
local function without_wrapper_dirs(path_value, root)
  local prefix = vim.fs.normalize(root) .. "/bin/"
  local kept = {}
  for _, entry in ipairs(split_path(path_value)) do
    local normalized = vim.fs.normalize(entry) .. "/"
    if normalized:sub(1, #prefix) ~= prefix then table.insert(kept, entry) end
  end
  return table.concat(kept, ":")
end

--- Resolve the real git, ignoring every wrapper bin dir so a wrapper can never be found as "git".
---@param root string|nil Wrapper cache root (defaults to the plugin's)
---@return string|nil real_git Absolute path, or nil when git is not installed
function GitRoute.resolve_real_git(root)
  root = root or GitRoute.paths().root
  local original = vim.env.PATH
  vim.env.PATH = without_wrapper_dirs(original, root)
  local found = vim.fn.exepath("git")
  vim.env.PATH = original
  if found == "" then return nil end
  return found
end

--- Render the wrapper script text.
---@param params table real_git, map_dir and ssh_options (array of ssh -o values)
---@return string|nil script, string|nil err
function GitRoute.render_wrapper(params)
  local template_files = vim.api.nvim_get_runtime_file(WRAPPER_TEMPLATE, false)
  if #template_files == 0 then return nil, "git wrapper template not found" end
  local lines = vim.fn.readfile(template_files[1])

  local ssh_parts = {}
  for _, option in ipairs(params.ssh_options) do
    table.insert(ssh_parts, "-o " .. sh_quote(option))
  end
  local values = {
    REAL_GIT = sh_quote(params.real_git),
    MAP_DIR = sh_quote(params.map_dir),
    SSH_OPTIONS = table.concat(ssh_parts, " "),
  }
  local script = table.concat(lines, "\n") .. "\n"
  script = script:gsub("@(%u[%u_]*)@", function(name)
    return values[name]
  end)
  return script
end

--- Write a file atomically so a concurrently starting git never reads a partial wrapper or map.
local function write_atomic(path, content, mode)
  local tmp = string.format("%s.%d.tmp", path, vim.uv.os_getpid())
  local file, err = io.open(tmp, "wb")
  if not file then return false, err end
  file:write(content)
  file:close()
  if mode then vim.uv.fs_chmod(tmp, mode) end
  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not ok then
    vim.uv.fs_unlink(tmp)
    return false, rename_err
  end
  return true
end

local NAMESPACE_MARKER = ".namespace"

local function read_first_line(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  return line
end

--- Identifies the pid namespace of this process. Pids only mean something inside one namespace,
--- and containers or NFS homes can share the cache while seeing each other's pids as dead.
local function namespace_id()
  local pid_ns = vim.uv.fs_readlink("/proc/self/ns/pid") or ""
  local boot_id = read_first_line("/proc/sys/kernel/random/boot_id") or ""
  return table.concat({ vim.uv.os_gethostname(), boot_id, pid_ns }, " ")
end

--- Whether every pid recorded under marker `other` is gone from the point of view of `own`.
--- Same host and pid namespace with another boot_id means a reboot: no pid survives it. Fields may be
--- empty (no /proc), hence `%S*`.
local function is_previous_boot(own, other)
  local own_host, own_boot, own_ns = own:match("^(%S*) (%S*) (%S*)$")
  local host, boot, ns = other:match("^(%S*) (%S*) (%S*)$")
  return own_host ~= nil and host == own_host and ns == own_ns and boot ~= own_boot
end

--- Delete bin dirs of Neovim processes that no longer exist. Instances cannot clean up after
--- themselves reliably (an exit autocmd would race plugins still running git), so the next start does.
--- Only dirs marked with this namespace are judged: an unmarked dir may belong to an instance that
--- is mid-startup, so it is left alone too.
local function sweep_dead_bin_dirs(root)
  local own_namespace = namespace_id()
  for _, dir in ipairs(vim.fn.glob(root .. "/bin/*", false, true)) do
    local marker = read_first_line(dir .. "/" .. NAMESPACE_MARKER)
    if marker == own_namespace then
      local pid = tonumber(vim.fn.fnamemodify(dir, ":t"))
      -- signal 0 only probes existence; uv.kill returns nil plus an error for a missing pid
      if not pid or vim.uv.kill(pid, 0) ~= 0 then vim.fn.delete(dir, "rf") end
    elseif marker and is_previous_boot(own_namespace, marker) then
      vim.fn.delete(dir, "rf")
    end
  end
end

--- Generate the wrapper and put its directory first on PATH, or take it off PATH when disabled.
---@return boolean installed
---@return string|nil err
function GitRoute.install()
  local paths = GitRoute.paths()
  if not GitRoute.enabled() then
    vim.env.PATH = without_wrapper_dirs(vim.env.PATH, paths.root)
    return false, "disabled"
  end

  -- Swept before resolving so nothing resolved here can be deleted right after.
  sweep_dead_bin_dirs(paths.root)
  local real_git = GitRoute.resolve_real_git(paths.root)
  if not real_git then return false, "git not found on PATH" end

  local script, render_err = GitRoute.render_wrapper({
    real_git = real_git,
    map_dir = paths.map_dir,
    ssh_options = require("sshfs.lib.ssh").build_git_route_options(),
  })
  if not script then return false, render_err end

  vim.fn.mkdir(paths.bin_dir, "p", "0700")
  write_atomic(paths.bin_dir .. "/" .. NAMESPACE_MARKER, namespace_id() .. "\n")
  local current = io.open(paths.wrapper, "rb")
  local existing = current and current:read("*a")
  if current then current:close() end
  if existing ~= script or vim.fn.executable(paths.wrapper) == 0 then
    local ok, err = write_atomic(paths.wrapper, script, 448) -- 0700
    if not ok then
      Logger.error("Failed to write git wrapper", { path = paths.wrapper, error = tostring(err) })
      return false, tostring(err)
    end
  end

  vim.env.PATH = paths.bin_dir .. ":" .. without_wrapper_dirs(vim.env.PATH, paths.root)
  Logger.debug("Installed git wrapper", { wrapper = paths.wrapper, real_git = real_git })
  return true
end

local function map_path(mount_path, map_dir)
  return (map_dir or GitRoute.paths().map_dir) .. "/" .. vim.fn.sha256(mount_path):sub(1, 16) .. ".map"
end

--- Serialize a mount description in the wrapper's key=value format.
---@param entry table mount_path, real_mount_path, host, user, port, remote_path, real_remote_path
---@return string
function GitRoute.format_map(entry)
  local lines = {
    "mount=" .. entry.mount_path,
    "real_mount=" .. (entry.real_mount_path or ""),
    "host=" .. entry.host,
    "user=" .. (entry.user or ""),
    "port=" .. (entry.port and tostring(entry.port) or ""),
    "remote=" .. entry.remote_path,
    "real=" .. (entry.real_remote_path or ""),
  }
  return table.concat(lines, "\n") .. "\n"
end

---@param map_dir string
---@param entry table See format_map
---@return boolean ok
function GitRoute.write_map_to(map_dir, entry)
  vim.fn.mkdir(map_dir, "p", "0700")
  local ok, err = write_atomic(map_path(entry.mount_path, map_dir), GitRoute.format_map(entry))
  if not ok then Logger.error("Failed to write git map", { mount_path = entry.mount_path, error = tostring(err) }) end
  return ok
end

---@param entry table See format_map
---@return boolean ok
function GitRoute.write_map(entry)
  return GitRoute.write_map_to(GitRoute.paths().map_dir, entry)
end

--- Forget a mount. Call only after a real unmount, never because one instance is leaving a shared mount.
---@param mount_path string
function GitRoute.remove_map(mount_path)
  vim.uv.fs_unlink(map_path(mount_path))
end

---@param mount_path string
---@return boolean
function GitRoute.has_map(mount_path)
  return vim.uv.fs_stat(map_path(mount_path)) ~= nil
end

--- Resolve the remote paths of a mount over its socket and write its map.
---@param info table mount_path, host (name), user, port, remote_path as mounted
---@param callback function|nil Called with (ok: boolean) once finished
function GitRoute.register_mount(info, callback)
  local function done(ok)
    if callback then callback(ok) end
  end
  if not GitRoute.enabled() then return done(false) end

  local host = { name = info.host, user = info.user, port = info.port }
  local cmd = require("sshfs.lib.ssh").build_pwd_command(host, info.remote_path)
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      local lines = vim.split(vim.trim(obj.stdout or ""), "\n", { trimempty = true })
      local remote, real = lines[#lines - 1], lines[#lines]
      if obj.code ~= 0 or not remote or remote:sub(1, 1) ~= "/" or not real or real:sub(1, 1) ~= "/" then
        -- Also the outcome when the remote has no git on its non-interactive PATH.
        Logger.warn(
          "Git route skipped; remote path or git unavailable",
          { mount_path = info.mount_path, code = obj.code }
        )
        return done(false)
      end
      done(GitRoute.write_map({
        mount_path = info.mount_path,
        real_mount_path = vim.uv.fs_realpath(info.mount_path),
        host = info.host,
        user = info.user,
        port = info.port,
        remote_path = remote,
        real_remote_path = real,
      }))
    end)
  end)
end

--- Write a map for a mount created by another Neovim instance, when none exists yet.
--- Only mounts MountPoint reports (under mounts.base_dir) qualify.
---@param mount_path string
function GitRoute.register_existing_mount(mount_path)
  if not GitRoute.enabled() or GitRoute.has_map(mount_path) then return end
  for _, mount in ipairs(require("sshfs.lib.mount_point").list_active()) do
    if mount.mount_path == mount_path and mount.remote_metadata_available then
      GitRoute.register_mount({
        mount_path = mount_path,
        host = mount.host,
        user = mount.user,
        remote_path = mount.remote_path,
      })
      return
    end
  end
end

--- Remove maps whose mount is gone (crash, force-kill, unmounted by hand).
---@return number removed
function GitRoute.sweep_stale()
  local active = require("sshfs.lib.mount_point").active_mount_paths()
  local removed = 0
  for _, file in ipairs(vim.fn.glob(GitRoute.paths().map_dir .. "/*.map", false, true)) do
    local mount_path
    for _, line in ipairs(vim.fn.readfile(file)) do
      mount_path = mount_path or line:match("^mount=(.+)$")
    end
    if not mount_path or not active[mount_path] then
      vim.uv.fs_unlink(file)
      removed = removed + 1
    end
  end
  return removed
end

return GitRoute
