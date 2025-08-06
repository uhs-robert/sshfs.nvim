-- Modern SSH connection management using ssh-core modules
local ssh_config = require("nvim_ssh.core.config")
local ssh_mount = require("nvim_ssh.core.mount")
local ssh_auth = require("nvim_ssh.core.auth")
local ssh_cache = require("nvim_ssh.core.cache")
local ui = require("nvim_ssh.ui.prompts")

local M = {}

-- Plugin configuration
local config = {}
local current_connection = {
	host = nil,
	mount_point = nil,
}

-- Initialize plugin with configuration
function M.setup(opts)
	config = opts or {}

	-- Ensure mount base directory exists
	if config.mounts and config.mounts.base_dir then
		ssh_mount.ensure_mount_directory(config.mounts.base_dir)
	end
end

-- Get all available hosts from SSH configs
function M.get_hosts()
	local ssh_configs = config.connections.ssh_configs or ssh_config.get_default_ssh_configs()

	if ssh_cache.is_cache_valid(ssh_configs, nil) then
		return ssh_cache.get_cached_hosts() or {}
	end

	local hosts = ssh_config.parse_hosts_from_configs(ssh_configs)
	ssh_cache.update_cache(hosts, ssh_configs, nil)
	return hosts
end

-- Check if currently connected to a remote host
function M.is_connected()
	if not current_connection.host or not current_connection.mount_point then
		return false
	end

	return ssh_mount.is_mount_active(current_connection.mount_point, config.mounts.base_dir)
end

-- Get current connection info
function M.get_current_connection()
	return current_connection
end

-- Connect to a remote host
function M.connect(host)
	-- Disconnect existing connection first
	if M.is_connected() then
		M.disconnect()
	end

	local mount_dir = config.mounts.base_dir .. "/" .. host.Name

	-- Ensure mount directory exists
	if not ssh_mount.ensure_mount_directory(mount_dir) then
		vim.notify("Failed to create mount directory: " .. mount_dir, vim.log.levels.ERROR)
		return false
	end

	-- Prompt for mount location (home vs root)
	local mount_to_root = ssh_auth.prompt_mount_location()

	-- SSH connection options from config
	local ssh_options = {
		compression = true,
		server_alive_interval = 15,
		server_alive_count_max = 3,
	}

	-- Attempt authentication and mounting
	vim.notify("Connecting to " .. host.Name .. "...", vim.log.levels.INFO)
	local success, result = ssh_auth.authenticate_and_mount(host, mount_dir, ssh_options, mount_to_root)

	if success then
		-- Update connection state
		current_connection.host = host
		current_connection.mount_point = mount_dir

		vim.notify("Connected to " .. host.Name .. " successfully!", vim.log.levels.INFO)

		-- Handle post-connection actions
		M._handle_post_connect(mount_dir)
		return true
	else
		vim.notify("Connection failed: " .. (result or "Unknown error"), vim.log.levels.ERROR)
		ssh_mount.cleanup_mount_directory(mount_dir)
		return false
	end
end

-- Disconnect from current host
function M.disconnect()
	if not current_connection.mount_point then
		vim.notify("No active connection to disconnect", vim.log.levels.WARN)
		return false
	end

	local mount_point = current_connection.mount_point
	local host_name = current_connection.host and current_connection.host.Name or "unknown"

	-- Change directory if currently inside mount point
	local cwd = vim.uv.cwd()
	if cwd and mount_point and cwd:find(mount_point, 1, true) == 1 then
		vim.cmd("cd " .. vim.fn.expand("~"))
	end

	-- Unmount the filesystem
	local success = ssh_mount.unmount_sshfs(mount_point)

	if success then
		vim.notify("Disconnected from " .. host_name, vim.log.levels.INFO)

		-- Cleanup mount directory if configured
		if config.handlers and config.handlers.on_disconnect and config.handlers.on_disconnect.clean_mount_folders then
			ssh_mount.cleanup_mount_directory(mount_point)
		end

		-- Clear connection state
		current_connection.host = nil
		current_connection.mount_point = nil
		return true
	else
		vim.notify("Failed to disconnect from " .. host_name, vim.log.levels.ERROR)
		return false
	end
end

-- Reload SSH configuration
function M.reload()
	ssh_cache.invalidate_cache()
	vim.notify("SSH configuration reloaded", vim.log.levels.INFO)
end

-- Handle post-connection actions (directory change, etc.)
function M._handle_post_connect(mount_dir)
	if not config.handlers or not config.handlers.on_connect or not config.handlers.on_connect.change_dir then
		return
	end

	local should_confirm = config.ui and config.ui.confirm and config.ui.confirm.change_dir

	if should_confirm then
		local prompt = "Change current directory to remote server?"
		ui.prompt_yes_no(prompt, function(response)
			ui.clear_prompt()
			if response == "y" then
				vim.cmd("cd " .. mount_dir)
				vim.notify("Directory changed to " .. mount_dir)
			end
		end)
	else
		vim.cmd("cd " .. mount_dir)
		vim.notify("Directory changed to " .. mount_dir)
	end
end

return M

