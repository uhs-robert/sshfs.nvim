-- lua/sshfs/session.lua
-- SSH session lifecycle management: setup, connect, disconnect, reload

local Session = {}
local Config = require("sshfs.config")
local PRE_MOUNT_DIRS = {} -- Track pre-mount directory for each connection

-- Helper to create a unique local folder name based on host and remote path
---@param host_name string Host name
---@param remote_path_suffix string Remote path suffix to be concatenated to the host name
---@return string Success A unique concatenation of the host name and the suffix
local function get_unique_mount_dir(host_name, remote_path_suffix)
  local config = Config.get()

  local sanitized_path = remote_path_suffix
    :gsub("^/", "") -- trim leading slash
    :gsub("/$", "") -- trim trailing slash
    :gsub("/", "_") -- internal slashes to underscores

  -- If root or empty then use the host name; otherwise append the path
  local suffix = (sanitized_path ~= "") and ("_" .. sanitized_path) or ""
  return config.mounts.base_dir .. "/" .. host_name .. suffix
end

--- Connect to a remote SSH host via SSHFS
---@param host table Host object with name, user, port, and path fields
---@return boolean|nil Success status (or nil if async callback)
function Session.connect(host)
  local MountPoint = require("sshfs.lib.mount_point")
  local Lockfile = require("sshfs.lib.lockfile")
  local config = Config.get()

  -- Ask the user for the mount path
  local Ask = require("sshfs.ui.ask")
  Ask.for_mount_path(host, config, function(remote_path_suffix)
    if not remote_path_suffix then
      vim.notify("Connection cancelled.", vim.log.levels.WARN)
      return
    end

    -- Generate unique mount directory based on host + path
    local mount_dir = get_unique_mount_dir(host.name, remote_path_suffix)

    -- Check if unique path is already mounted
    if MountPoint.is_active(mount_dir) then
      vim.notify("Path " .. remote_path_suffix .. " on " .. host.name .. " is already mounted.", vim.log.levels.WARN)
      return
    end

    -- Capture current directory before mounting
    PRE_MOUNT_DIRS[mount_dir] = vim.uv.cwd()

    -- Ensure the unique mount directory exists
    if not MountPoint.get_or_create(mount_dir) then
      vim.notify("Failed to create mount directory: " .. mount_dir, vim.log.levels.ERROR)
      return
    end

    -- Attempt authentication and mounting (async)
    local Sshfs = require("sshfs.lib.sshfs")
    Sshfs.authenticate_and_mount(host, mount_dir, remote_path_suffix, function(result)
      -- Handle connection failure
      if not result.success then
        vim.notify("Connection failed: " .. (result.message or "Unknown error"), vim.log.levels.ERROR)
        MountPoint.cleanup()
        return
      end

      -- Register in lockfile so other instances know we're using this mount
      Lockfile.register(mount_dir)

      -- Navigate to remote directory with picker
      vim.notify("Connected to " .. host.name .. " (" .. remote_path_suffix .. ")", vim.log.levels.INFO)
      local Hooks = require("sshfs.ui.hooks")
      local final_path = result.resolved_path or remote_path_suffix
      Hooks.on_mount(mount_dir, host.name, final_path, config)
    end)
  end)
end

--- Disconnect from the currently active SSH mount
---@return boolean Success status
function Session.disconnect()
  local MountPoint = require("sshfs.lib.mount_point")
  local active_connection = MountPoint.get_active()
  if not active_connection or not active_connection.mount_path then
    vim.notify("No active connection to disconnect", vim.log.levels.WARN)
    return false
  end

  return Session.disconnect_from(active_connection)
end

--- Disconnect from a specific SSH connection
---@param connection table Connection object with host and mount_path fields
---@param silent boolean|nil If true, suppress notifications (optional, defaults to false)
---@return boolean Success status
function Session.disconnect_from(connection, silent)
  local MountPoint = require("sshfs.lib.mount_point")
  local Lockfile = require("sshfs.lib.lockfile")
  if not connection or not connection.mount_path then
    vim.notify("Invalid connection to disconnect", vim.log.levels.WARN)
    return false
  end

  -- Change directory if currently inside mount point
  local cwd = vim.uv.cwd()
  if cwd and connection.mount_path and cwd:find(connection.mount_path, 1, true) == 1 then
    local restore_dir = PRE_MOUNT_DIRS[connection.mount_path]
    if restore_dir and vim.fn.isdirectory(restore_dir) == 1 then
      vim.cmd("tcd " .. vim.fn.fnameescape(restore_dir))
    else
      vim.cmd("tcd " .. vim.fn.expand("~"))
    end
  end

  -- Release buffers and LSPs associated with mount point
  local safe_to_unmount = MountPoint.release_mount(connection.mount_path, silent)
  if not safe_to_unmount then return false end

  -- Unregister from lockfile
  Lockfile.unregister(connection.mount_path)

  -- Early exit: If other Neovim instances are using the mount then do not unmount
  if Lockfile.is_in_use_by_others(connection.mount_path) then
    PRE_MOUNT_DIRS[connection.mount_path] = nil
    if not silent then
      vim.notify(
        "Mount " .. connection.host .. " still in use by other instances, keeping mounted",
        vim.log.levels.INFO
      )
    end
    return true
  end

  -- Unmount the filesystem
  local success = MountPoint.unmount(connection.mount_path)

  -- Cleanup
  if success then
    if not silent then vim.notify("Disconnected from " .. connection.host, vim.log.levels.INFO) end

    PRE_MOUNT_DIRS[connection.mount_path] = nil
    local config = Config.get()
    if config.hooks and config.hooks.on_exit and config.hooks.on_exit.clean_mount_folders then MountPoint.cleanup() end

    return true
  else
    if not silent then vim.notify("Failed to disconnect from " .. connection.host, vim.log.levels.ERROR) end
    return false
  end
end

--- Cleanup all unused mounts on VimLeave
--- Iterates through all active SSHFS mounts and unmounts any not being used by other instances
function Session.cleanup_unused_mounts()
  local MountPoint = require("sshfs.lib.mount_point")
  local all_mounts = MountPoint.list_active()

  for _, connection in ipairs(all_mounts) do
    Session.disconnect_from(connection, true)
  end
end

--- Reload SSH configuration by clearing the cache
function Session.reload()
  local SSHConfig = require("sshfs.lib.ssh_config")
  SSHConfig.refresh()
  vim.notify("SSH configuration reloaded", vim.log.levels.INFO)
end

return Session
