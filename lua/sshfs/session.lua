-- lua/sshfs/session.lua
-- SSH session lifecycle management: setup, connect, disconnect, reload

local Session = {}
local config = {}
local pre_mount_directories = {} -- Track pre-mount directory for each connection

-- Initialize plugin with configuration
function Session.setup(opts)
	local MountPoint = require("sshfs.core.mount")
	config = opts or {}

	-- Ensure mount base directory exists
	if config.mounts and config.mounts.base_dir then
		MountPoint.ensure(config.mounts.base_dir)
	end
end

-- Get the configured base directory for mounts
function Session.get_base_dir()
	return config.mounts and config.mounts.base_dir
end

-- Get all available hosts from SSH configs
function Session.get_hosts()
	local SSHConfig = require("sshfs.core.config")
	local Cache = require("sshfs.core.cache")
	local config_files = config.connections.ssh_configs or SSHConfig.get_default_files()

	if Cache.is_valid(config_files, nil) then
		return Cache.get_hosts() or {}
	end

	local hosts = SSHConfig.get_hosts(config_files)
	Cache.update(hosts, config_files, nil)
	return hosts
end

-- Connect to a remote host
function Session.connect(host)
	local MountPoint = require("sshfs.core.mount")
	local mount_dir = config.mounts.base_dir .. "/" .. host.Name

	-- Check if already mounted
	if MountPoint.is_active(mount_dir) then
		vim.notify("Host " .. host.Name .. " is already mounted at " .. mount_dir, vim.log.levels.WARN)
		return true
	end

	-- Capture current directory before mounting for restoration on disconnect
	pre_mount_directories[mount_dir] = vim.uv.cwd()

	-- Ensure mount directory exists
	if not MountPoint.ensure(mount_dir) then
		vim.notify("Failed to create mount directory: " .. mount_dir, vim.log.levels.ERROR)
		return false
	end

	-- Ask the user for the mount path
	local Ask = require("sshfs.ui.ask")
	Ask.for_mount_path(host, config, function(remote_path_suffix)
		if not remote_path_suffix then
			vim.notify("Connection cancelled.", vim.log.levels.WARN)
			MountPoint.cleanup(mount_dir)
			return
		end

		-- SSH connection options from config
		local ssh_options = {
			compression = true,
			server_alive_interval = 15,
			server_alive_count_max = 3,
		}

		-- Attempt authentication and mounting
		local Sshfs = require("sshfs.core.auth")
		local user_sshfs_args = config.connections and config.connections.sshfs_args
		local success, result =
			Sshfs.authenticate_and_mount(host, mount_dir, ssh_options, remote_path_suffix, user_sshfs_args)

		-- Handle connection failure
		if not success then
			vim.notify("Connection failed: " .. (result or "Unknown error"), vim.log.levels.ERROR)
			MountPoint.cleanup(mount_dir)
			return false
		end

		-- Handle post-connection success
		vim.notify("Connected to " .. host.Name .. " successfully!", vim.log.levels.INFO)
		local Navigate = require("sshfs.ui.navigate")
		Navigate.with_picker(mount_dir, config)
		return true
	end)
end

-- Disconnect from current host (backward compatibility)
function Session.disconnect()
	local Connections = require("sshfs.core.connections")
	local base_dir = config.mounts and config.mounts.base_dir
	local active_connection = Connections.get_active(base_dir)
	if not active_connection.mount_point then
		vim.notify("No active connection to disconnect", vim.log.levels.WARN)
		return false
	end

	return Session.disconnect_from(active_connection)
end

-- Disconnect from specific connection
function Session.disconnect_from(connection)
	local MountPoint = require("sshfs.core.mount")
	if not connection or not connection.mount_point then
		vim.notify("Invalid connection to disconnect", vim.log.levels.WARN)
		return false
	end

	local host_name = connection.host and connection.host.Name or "unknown"

	-- Change directory if currently inside mount point
	local cwd = vim.uv.cwd()
	if cwd and connection.mount_point and cwd:find(connection.mount_point, 1, true) == 1 then
		local restore_dir = pre_mount_directories[connection.mount_point]
		if restore_dir and vim.fn.isdirectory(restore_dir) == 1 then
			vim.cmd("tcd " .. vim.fn.fnameescape(restore_dir))
		else
			vim.cmd("tcd " .. vim.fn.expand("~"))
		end
	end

	-- Unmount the filesystem
	local success = MountPoint.unmount(connection.mount_point)

	if success then
		vim.notify("Disconnected from " .. host_name, vim.log.levels.INFO)

		-- Clean up stored pre-mount directory after successful unmount
		pre_mount_directories[connection.mount_point] = nil

		-- Cleanup mount directory if configured
		if config.handlers and config.handlers.on_disconnect and config.handlers.on_disconnect.clean_mount_folders then
			MountPoint.cleanup(connection.mount_point)
		end

		return true
	else
		vim.notify("Failed to disconnect from " .. host_name, vim.log.levels.ERROR)
		return false
	end
end

-- Reload SSH configuration
function Session.reload()
	local Cache = require("sshfs.core.cache")
	Cache.reset()
	vim.notify("SSH configuration reloaded", vim.log.levels.INFO)
end

return Session
