-- lua/sshfs/lib/sshfs.lua
-- SSHFS wrapper with authentication workflows

local Sshfs = {}
local sshfs_major_version
local sshfs_version_warning_shown = false

--- Detect the installed SSHFS major version once per Neovim instance.
--- @return number|nil Major version, or nil if it cannot be determined
local function get_sshfs_major_version()
  if sshfs_major_version ~= nil then return sshfs_major_version or nil end

  sshfs_major_version = false

  -- Bounded wait: a hung `sshfs --version` must not block Neovim indefinitely.
  local ok, process = pcall(vim.system, { "sshfs", "--version" }, { text = true })
  if ok then
    local wait_ok, result = pcall(process.wait, process, 2000)
    if wait_ok and result then
      -- Some builds report the version on stderr and/or exit non-zero, so parse
      -- whatever output is available rather than gating on the exit code.
      local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
      sshfs_major_version = tonumber(output:match("SSHFS version%s+(%d+)") or output:match("SSHFS%s+(%d+)")) or false
    end
  end

  if not sshfs_major_version and not sshfs_version_warning_shown then
    sshfs_version_warning_shown = true
    vim.notify(
      "Unable to detect SSHFS version; using configured option names unchanged. SSHFS 2.x/fuse-t may require cache, cache_timeout, and cache_max_size.",
      vim.log.levels.WARN
    )
  end

  return sshfs_major_version or nil
end

--- Translate sshfs 3.x directory-cache option names for sshfs 2.x implementations.
--- Explicit 2.x options take precedence over translated defaults/user values.
--- @param options_table table
--- @return table
local function normalize_sshfs_options(options_table)
  local options = vim.deepcopy(options_table)
  local major = get_sshfs_major_version()
  if not major or major >= 3 then return options end

  if options.dir_cache ~= nil then
    if options.cache == nil then options.cache = options.dir_cache end
    options.dir_cache = nil
  end

  if options.dcache_timeout ~= nil then
    if options.cache_timeout == nil then options.cache_timeout = options.dcache_timeout end
    options.dcache_timeout = nil
  end

  if options.dcache_max_size ~= nil then
    if options.cache_max_size == nil then options.cache_max_size = options.dcache_max_size end
    options.dcache_max_size = nil
  end

  return options
end

--- Convert sshfs_options table to array format for sshfs -o
--- @param options_table table Table of options (e.g., {reconnect = true, ConnectTimeout = 5})
--- @return table Array of option strings (e.g., {"reconnect", "ConnectTimeout=5"})
local function build_sshfs_args(options_table)
  local result = {}

  for key, value in pairs(options_table) do
    if value == true then
      -- Boolean true: just add the key
      table.insert(result, key)
    elseif value ~= false and value ~= nil then
      -- String or number: add as key=value
      table.insert(result, string.format("%s=%s", key, tostring(value)))
    end
    -- false or nil: skip this option
  end

  return result
end

--- Build sshfs options array for mounting via established ControlMaster socket
--- @param auth_type string Authentication type (only "socket" is used in SSH-first flow)
--- @return table Array of sshfs options
local function get_sshfs_options(auth_type)
  local Config = require("sshfs.config")
  local Ssh = require("sshfs.lib.ssh")
  local opts = Config.get()
  local options = {}

  -- Add user-configured sshfs options from config (convert table to array)
  if opts.connections and opts.connections.sshfs_options then
    local sshfs_opts = build_sshfs_args(normalize_sshfs_options(opts.connections.sshfs_options))
    vim.list_extend(options, sshfs_opts)
  end

  -- Add SSH command to reuse existing ControlMaster socket
  if auth_type == "socket" then
    local ssh_cmd = Ssh.build_command_string("socket")
    if ssh_cmd ~= "ssh" then table.insert(options, "ssh_command=" .. ssh_cmd) end
  end

  return options
end

--- Execute the actual mount command (private helper)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string Remote path to mount (already resolved)
--- @param callback function Callback function(result: table) - result has fields: success, message, resolved_path
local function mount_with_path(host, mount_point, remote_path_suffix, callback)
  local options = get_sshfs_options("socket")

  -- Use host.name (the alias) to let SSH config resolution work properly
  local remote_path = host.name
  if host.user then remote_path = host.user .. "@" .. remote_path end
  remote_path = remote_path .. ":" .. remote_path_suffix

  -- Add options/port
  local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }
  if host.port then
    table.insert(cmd, "-p")
    table.insert(cmd, host.port)
  end

  -- Execute mount command asynchronously
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 then
        callback({
          success = true,
          message = "Mount successful",
          resolved_path = remote_path_suffix,
        })
      else
        local error_msg = obj.stderr or obj.stdout or "Unknown error"
        callback({
          success = false,
          message = "Mount failed: " .. error_msg,
        })
      end
    end)
  end)
end

--- Mount via established ControlMaster socket (async, private helper)
--- Assumes SSH connection is already authenticated and socket exists
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(result: table) - result has fields: success, message, resolved_path
local function mount_via_socket(host, mount_point, remote_path_suffix, callback)
  remote_path_suffix = remote_path_suffix or (host.path or "")

  -- If path starts with ~, resolve it to the actual home directory
  -- This handles symlinked home directories and non-standard structures
  if remote_path_suffix:match("^~") then
    local Ssh = require("sshfs.lib.ssh")
    Ssh.get_remote_home(host.name, function(actual_home, error)
      if actual_home then
        -- Replace ~ with the actual home path and mount
        local resolved_path = remote_path_suffix:gsub("^~", actual_home)
        mount_with_path(host, mount_point, resolved_path, callback)
      else
        -- Fall back to letting SSHFS try to handle it (may fail for symlinks)
        vim.notify(
          "Could not resolve home directory, attempting mount anyway: " .. (error or "unknown error"),
          vim.log.levels.WARN
        )
        mount_with_path(host, mount_point, remote_path_suffix, callback)
      end
    end)
    return
  end

  mount_with_path(host, mount_point, remote_path_suffix, callback)
end

--- Authenticate and mount using SSH-first (async)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(result: table) - result has fields: success, message, resolved_path
function Sshfs.authenticate_and_mount(host, mount_point, remote_path_suffix, callback)
  local Ssh = require("sshfs.lib.ssh")
  vim.notify("Connecting to " .. host.name .. "...", vim.log.levels.INFO)

  -- Try batch connection (non-interactive)
  Ssh.try_batch_connect(host.name, function(success, exit_code, error)
    if success then
      mount_via_socket(host, mount_point, remote_path_suffix, callback)
      return
    end

    -- Batch failed, try interactive terminal
    Ssh.open_auth_terminal(host.name, function(term_success, term_exit_code)
      if term_success then
        mount_via_socket(host, mount_point, remote_path_suffix, callback)
      else
        callback({
          success = false,
          message = string.format("SSH authentication failed for %s (exit code: %d)", host.name, term_exit_code),
        })
      end
    end)
  end)
end

return Sshfs
