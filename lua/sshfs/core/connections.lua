-- lua/sshfs/core/connections.lua
-- SSH connection orchestration, host management, mount/unmount operations, and state tracking

local ssh_config = require("sshfs.core.config")
local ssh_mount = require("sshfs.core.mount")
local ssh_auth = require("sshfs.core.auth")
local ssh_cache = require("sshfs.core.cache")

local M = {}

-- Plugin configuration
local config = {}
-- Track pre-mount directory for each connection
local pre_mount_directories = {}

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
	local base_dir = config.mounts and config.mounts.base_dir
	if not base_dir then
		return false
	end

	local mounts = ssh_mount.list_active_mounts(base_dir)
	return #mounts > 0
end

-- Get current connection info (first mount for backward compatibility)
function M.get_current_connection()
	local base_dir = config.mounts and config.mounts.base_dir
	if not base_dir then
		return { host = nil, mount_point = nil }
	end

	local mounts = ssh_mount.list_active_mounts(base_dir)
	if #mounts > 0 then
		-- Return first active mount as the current connection
		return {
			host = { Name = mounts[1].alias },
			mount_point = mounts[1].path,
		}
	end

	return { host = nil, mount_point = nil }
end

-- Get all active connections
function M.get_all_connections()
	local base_dir = config.mounts and config.mounts.base_dir
	if not base_dir then
		return {}
	end

	local mounts = ssh_mount.list_active_mounts(base_dir)

	local connections = {}
	for _, mount in ipairs(mounts) do
		table.insert(connections, {
			host = { Name = mount.alias },
			mount_point = mount.path,
		})
	end

	return connections
end

-- Connect to a remote host
function M.connect(host)
	local mount_dir = config.mounts.base_dir .. "/" .. host.Name

	-- Check if already mounted
	if ssh_mount.is_mount_active(mount_dir) then
		vim.notify("Host " .. host.Name .. " is already mounted at " .. mount_dir, vim.log.levels.WARN)
		return true
	end

	-- Capture current directory before mounting for restoration on disconnect
	pre_mount_directories[mount_dir] = vim.uv.cwd()

	-- Ensure mount directory exists
	if not ssh_mount.ensure_mount_directory(mount_dir) then
		vim.notify("Failed to create mount directory: " .. mount_dir, vim.log.levels.ERROR)
		return false
	end

	-- Prompt for mount location
  local function prompt_for_mount_path(callback)
		local choices = {
      "&Home directory (~)",
      "&Root directory (/)",
      "&Manual path",
      "&Configured path"
    }

		local configured_path = config.host_specific_mounts and config.host_specific_mounts[host.Name]
    if not configured_path then
      -- remove configured path if not defined in configuration
      table.remove(choices, 4)
    end

    local choice = vim.fn.confirm("Select mount location:", table.concat(choices, "\n"), 1)
    print("Your choice is " .. choice)

    if choice == 1 then
      callback("$HOME")
    elseif choice == 2 then
      callback("/")
    elseif choice == 4 then
      callback(configured_path)
    else
      -- Get remote path from user
      vim.ui.input({ prompt = "Enter remote path to mount:" }, function(path)
        callback(path)
      end)
    end
	end

	prompt_for_mount_path(function(remote_path_suffix)
		if not remote_path_suffix then
			vim.notify("Connection cancelled.", vim.log.levels.WARN)
			ssh_mount.cleanup_mount_directory(mount_dir)
			return
		end

		-- SSH connection options from config
		local ssh_options = {
			compression = true,
			server_alive_interval = 15,
			server_alive_count_max = 3,
		}

		-- Attempt authentication and mounting
		local user_sshfs_args = config.connections and config.connections.sshfs_args
		local success, result =
			ssh_auth.authenticate_and_mount(host, mount_dir, ssh_options, remote_path_suffix, user_sshfs_args)

		if success then
			vim.notify("Connected to " .. host.Name .. " successfully!", vim.log.levels.INFO)

			-- Handle post-connection actions
			M._handle_post_connect(mount_dir)
		else
			vim.notify("Connection failed: " .. (result or "Unknown error"), vim.log.levels.ERROR)
			ssh_mount.cleanup_mount_directory(mount_dir)
		end
	end)
end

-- Disconnect from current host (backward compatibility)
function M.disconnect()
	local connection = M.get_current_connection()
	if not connection.mount_point then
		vim.notify("No active connection to disconnect", vim.log.levels.WARN)
		return false
	end

	return M.disconnect_specific(connection)
end

-- Disconnect from specific connection
function M.disconnect_specific(connection)
	if not connection or not connection.mount_point then
		vim.notify("Invalid connection to disconnect", vim.log.levels.WARN)
		return false
	end

	local mount_point = connection.mount_point
	local host_name = connection.host and connection.host.Name or "unknown"

	-- Change directory if currently inside mount point
	local cwd = vim.uv.cwd()
	if cwd and mount_point and cwd:find(mount_point, 1, true) == 1 then
		local restore_dir = pre_mount_directories[mount_point]
		if restore_dir and vim.fn.isdirectory(restore_dir) == 1 then
			vim.cmd("tcd " .. vim.fn.fnameescape(restore_dir))
		else
			vim.cmd("tcd " .. vim.fn.expand("~"))
		end
	end

	-- Unmount the filesystem
	local success = ssh_mount.unmount_sshfs(mount_point)

	if success then
		vim.notify("Disconnected from " .. host_name, vim.log.levels.INFO)

		-- Clean up stored pre-mount directory after successful unmount
		pre_mount_directories[mount_point] = nil

		-- Cleanup mount directory if configured
		if config.handlers and config.handlers.on_disconnect and config.handlers.on_disconnect.clean_mount_folders then
			ssh_mount.cleanup_mount_directory(mount_point)
		end

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

-- Change to mounted SSH directory
function M.change_to_mount_dir()
	local connections = M.get_all_connections()

	if #connections == 0 then
		vim.notify("No active SSH connections", vim.log.levels.WARN)
		return
	end

	if #connections == 1 then
		local mount_dir = connections[1].mount_point
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
		vim.notify("Changed to: " .. mount_dir, vim.log.levels.INFO)
		return
	end

	local items = {}
	for _, conn in ipairs(connections) do
		local host_name = conn.host and conn.host.Name or "unknown"
		table.insert(items, host_name)
	end

	vim.ui.select(items, {
		prompt = "Select mount to change to:",
	}, function(_, idx)
		if idx then
			local mount_dir = connections[idx].mount_point
			vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
			vim.notify("Changed to: " .. mount_dir, vim.log.levels.INFO)
		end
	end)
end

-- Handle post-connection actions (auto-open file picker)
function M._handle_post_connect(mount_dir)
	-- Auto-change directory to mount point if configured
	if config.mounts and config.mounts.auto_change_dir_on_mount then
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
	end

	-- Try to auto-open file picker (respects auto_open_on_mount setting)
	if config.ui then
		local picker_module = require("sshfs.ui.picker")
		local success, picker_name = picker_module.try_open_file_picker(mount_dir, config.ui, false)

		if not success and picker_name ~= "Auto-open disabled" then
			vim.notify("Failed to open " .. picker_name .. " for new mount: " .. mount_dir, vim.log.levels.ERROR)
		end
	end
end

return M
