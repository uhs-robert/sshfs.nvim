-- lua/sshfs/session.lua
-- SSH session lifecycle management: setup, connect, disconnect, reload

local Session = {}
local Config = require("sshfs.config")
local PRE_MOUNT_DIRS = {} -- Track pre-mount directory for each connection

--- Connect to a remote SSH host via SSHFS
---@param host table Host object with name, user, port, and path fields
---@return boolean|nil Success status (or nil if async callback)
function Session.connect(host)
	local MountPoint = require("sshfs.lib.mount_point")
	local config = Config.get()
	local mount_dir = config.mounts.base_dir .. "/" .. host.name

	-- Check if already mounted
	if MountPoint.is_active(mount_dir) then
		vim.notify("Host " .. host.name .. " is already mounted at " .. mount_dir, vim.log.levels.WARN)
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

		-- Attempt authentication and mounting (async)
		local Sshfs = require("sshfs.lib.sshfs")
		Sshfs.authenticate_and_mount(host, mount_dir, remote_path_suffix, function(success, result)
			-- Handle connection failure
			if not success then
				vim.notify("Connection failed: " .. (result or "Unknown error"), vim.log.levels.ERROR)
				MountPoint.cleanup()
				return
			end

			-- Add connection to cache and navigate to remote directory with picker
			vim.notify("Connected to " .. host.name, vim.log.levels.INFO)
			local Connections = require("sshfs.lib.connections")
			local Navigate = require("sshfs.ui.navigate")
			Connections.add(host.name, mount_dir, remote_path_suffix)
			Navigate.with_picker(mount_dir, config)
		end)
	end)
end

--- Disconnect from the currently active SSH mount
---@return boolean Success status
function Session.disconnect()
	local Connections = require("sshfs.lib.connections")
	local active_connection = Connections.get_active()
	if not active_connection or not active_connection.mount_path then
		vim.notify("No active connection to disconnect", vim.log.levels.WARN)
		return false
	end

	return Session.disconnect_from(active_connection)
end

--- Disconnect from a specific SSH connection
---@param connection table Connection object with host and mount_path fields
---@return boolean Success status
function Session.disconnect_from(connection)
	local MountPoint = require("sshfs.lib.mount_point")
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

	-- Unmount the filesystem
	local success = MountPoint.unmount(connection.mount_path)

	-- Cleanup
	if success then
		vim.notify("Disconnected from " .. connection.host, vim.log.levels.INFO)

		-- Remove connection from cache
		local Connections = require("sshfs.lib.connections")
		Connections.remove(connection.mount_path)

		-- Remove pre-mount cache and mount point
		PRE_MOUNT_DIRS[connection.mount_path] = nil
		local config = Config.get()
		if config.handlers and config.handlers.on_disconnect and config.handlers.on_disconnect.clean_mount_folders then
			MountPoint.cleanup()
		end

		return true
	else
		vim.notify("Failed to disconnect from " .. connection.host, vim.log.levels.ERROR)
		return false
	end
end

--- Reload SSH configuration by clearing the cache
function Session.reload()
	local SSHConfig = require("sshfs.lib.ssh_config")
	SSHConfig.refresh()
	vim.notify("SSH configuration reloaded", vim.log.levels.INFO)
end

return Session
