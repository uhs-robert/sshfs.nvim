local connections = require("nvim_ssh.core.connections")
local picker = require("nvim_ssh.ui.picker")

local M = {}

-- Helper function to get UI config consistently
local function get_ui_config()
	local config = {}
	local config_ok, init_module = pcall(require, "nvim_ssh")
	if config_ok and init_module._config then
		config = init_module._config.ui or {}
	end
	return config
end

-- Connect to SSH host - use picker if no host provided, otherwise connect directly
M.connect = function(host)
	if host then
		-- Direct connection with provided host
		connections.connect(host)
	else
		-- Use picker to select host
		picker.pick_host(function(selected_host)
			if selected_host then
				connections.connect(selected_host)
			end
		end)
	end
end

-- Mount SSH host (alias for connect)
M.mount = function()
	M.connect()
end

-- Disconnect from current SSH host
M.disconnect = function()
	connections.disconnect()
end

-- Unmount SSH host - smart handling for multiple mounts
M.unmount = function()
	local all_connections = connections.get_all_connections()

	if #all_connections == 0 then
		vim.notify("No active mounts to disconnect", vim.log.levels.WARN)
		return
	elseif #all_connections == 1 then
		-- Single mount: disconnect directly
		connections.disconnect_specific(all_connections[1])
	else
		-- Multiple mounts: show picker to select which to unmount
		picker.pick_mount_to_unmount(function(selected_mount)
			if selected_mount then
				connections.disconnect_specific(selected_mount)
			end
		end)
	end
end

-- Check connection status
M.is_connected = function()
	return connections.is_connected()
end

-- Get current connection info
M.get_current_connection = function()
	return connections.get_current_connection()
end

-- Edit SSH config files using native picker
M.edit = function()
	picker.pick_ssh_config(function(config_file)
		if config_file then
			vim.cmd("edit " .. vim.fn.fnameescape(config_file))
		end
	end)
end

-- Reload SSH configuration
M.reload = function()
	connections.reload()
end

-- Browse remote files using native file browser
M.find_files = function(opts)
	if not connections.is_connected() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	picker.browse_remote_files(opts)
end

-- Search text in remote files using native grep
M.live_grep = function(pattern, opts)
	if not connections.is_connected() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	picker.grep_remote_files(pattern, opts)
end

-- Browse remote files - smart handling for multiple mounts
M.browse = function(opts)
	local all_connections = connections.get_all_connections()

	if #all_connections == 0 then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	elseif #all_connections == 1 then
		-- Single mount: browse directly
		M.find_files(opts)
	else
		-- Multiple mounts: show picker to select which mount to browse
		M.list_mounts()
	end
end

-- Search remote files (alias for live_grep)
M.grep = function(pattern, opts)
	M.live_grep(pattern, opts)
end

-- List all active mounts and open file picker for selected mount
M.list_mounts = function()
	picker.pick_mount(function(selected_mount)
		if selected_mount then
			local config = get_ui_config()
			local success, picker_name = picker.try_open_file_picker(selected_mount.path, config)

			if not success then
				vim.notify("Could not open file picker for: " .. selected_mount.path, vim.log.levels.WARN)
			end
		end
	end)
end

return M
