local connections = require("ssh.core.connections")
local picker = require("ssh.ui.picker")

local M = {}

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

-- Unmount SSH host (alias for disconnect)
M.unmount = function()
	connections.disconnect()
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

-- Browse remote files (alias for find_files)
M.browse = function(opts)
	M.find_files(opts)
end

-- Search remote files (alias for live_grep)
M.grep = function(pattern, opts)
	M.live_grep(pattern, opts)
end

return M
