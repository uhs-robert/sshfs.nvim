-- lua/sshfs/session.lua
-- SSH session lifecycle management: setup, connect, disconnect, reload

local Session = {}
local Config = require("sshfs.config")
local PRE_MOUNT_DIRS = {} -- Track pre-mount directory for each connection

-- Get all available hosts from SSH configs
function Session.get_hosts()
	local SSHConfig = require("sshfs.lib.ssh_config")
	local Cache = require("sshfs.cache")
	local config = Config.get()
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
	local MountPoint = require("sshfs.lib.mount_point")
	local config = Config.get()
	local mount_dir = config.mounts.base_dir .. "/" .. host.Name

	-- Check if already mounted
	if MountPoint.is_active(mount_dir) then
		vim.notify("Host " .. host.Name .. " is already mounted at " .. mount_dir, vim.log.levels.WARN)
		return true
	end

	-- Capture current directory before mounting for restoration on disconnect
	PRE_MOUNT_DIRS[mount_dir] = vim.uv.cwd()

	-- Ensure mount directory exists
	if not MountPoint.get_or_create(mount_dir) then
		vim.notify("Failed to create mount directory: " .. mount_dir, vim.log.levels.ERROR)
		return false
	end

	-- Ask the user for the mount path
	local Ask = require("sshfs.ui.ask")
	Ask.for_mount_path(host, config, function(remote_path_suffix)
		if not remote_path_suffix then
			vim.notify("Connection cancelled.", vim.log.levels.WARN)
			MountPoint.cleanup()
			return
		end

		-- SSH connection options from config
		local ssh_options = {
			compression = true,
			server_alive_interval = 15,
			server_alive_count_max = 3,
		}

		-- Attempt authentication and mounting
		local Sshfs = require("sshfs.lib.sshfs")
		local user_sshfs_args = config.connections and config.connections.sshfs_args
		local success, result =
			Sshfs.authenticate_and_mount(host, mount_dir, ssh_options, remote_path_suffix, user_sshfs_args)

		-- Handle connection failure
		if not success then
			vim.notify("Connection failed: " .. (result or "Unknown error"), vim.log.levels.ERROR)
			MountPoint.cleanup()
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
	local Connections = require("sshfs.lib.connections")
	local active_connection = Connections.get_active()
	if not active_connection.mount_point then
		vim.notify("No active connection to disconnect", vim.log.levels.WARN)
		return false
	end

	return Session.disconnect_from(active_connection)
end

-- Disconnect from specific connection
function Session.disconnect_from(connection)
	local MountPoint = require("sshfs.lib.mount_point")
	if not connection or not connection.mount_point then
		vim.notify("Invalid connection to disconnect", vim.log.levels.WARN)
		return false
	end

	-- Change directory if currently inside mount point
	local cwd = vim.uv.cwd()
	if cwd and connection.mount_point and cwd:find(connection.mount_point, 1, true) == 1 then
		local restore_dir = PRE_MOUNT_DIRS[connection.mount_point]
		if restore_dir and vim.fn.isdirectory(restore_dir) == 1 then
			vim.cmd("tcd " .. vim.fn.fnameescape(restore_dir))
		else
			vim.cmd("tcd " .. vim.fn.expand("~"))
		end
	end

	-- Unmount the filesystem
	local success = MountPoint.unmount(connection.mount_point)

	-- Cleanup
	local host_name = connection.host and connection.host.Name or "unknown"
	if success then
		vim.notify("Disconnected from " .. host_name, vim.log.levels.INFO)

		-- Remove pre-mount cache and mount point
		PRE_MOUNT_DIRS[connection.mount_point] = nil
		local config = Config.get()
		if config.handlers and config.handlers.on_disconnect and config.handlers.on_disconnect.clean_mount_folders then
			MountPoint.cleanup()
		end

		return true
	else
		vim.notify("Failed to disconnect from " .. host_name, vim.log.levels.ERROR)
		return false
	end
end

-- Reload SSH configuration
function Session.reload()
	local Cache = require("sshfs.cache")
	Cache.reset()
	vim.notify("SSH configuration reloaded", vim.log.levels.INFO)
end

return Session
