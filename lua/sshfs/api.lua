-- lua/sshfs/api.lua
-- Public API wrapper providing high-level functions (connect, disconnect, browse, grep, edit)

local Api = {}

-- Helper function to get UI config consistently
local function get_ui_config()
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config.ui or {}
	end
	return config
end

-- Connect to SSH host - use picker if no host provided, otherwise connect directly
Api.connect = function(host)
	local Session = require("sshfs.session")
	if host then
		Session.connect(host)
	else
		local Select = require("sshfs.ui.select")
		Select.host(function(selected_host)
			if selected_host then
				Session.connect(selected_host)
			end
		end)
	end
end

-- Mount SSH host (alias for connect)
Api.mount = function()
	Api.connect()
end

-- Disconnect from current SSH host
Api.disconnect = function()
	local Session = require("sshfs.session")
	Session.disconnect()
end

-- Unmount SSH host - smart handling for multiple mounts
Api.unmount = function()
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	local active_connections = Connections.get_all(base_dir)

	if #active_connections == 0 then
		vim.notify("No active mounts to disconnect", vim.log.levels.WARN)
		return
	elseif #active_connections == 1 then
		Session.disconnect_from(active_connections[1])
	else
		local Select = require("sshfs.ui.select")
		Select.unmount(function(selected_mount)
			if selected_mount then
				Session.disconnect_from(selected_mount)
			end
		end)
	end
end

-- Check connection status
Api.has_active = function()
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	return Connections.has_active(base_dir)
end

-- Get current connection info
Api.get_active = function()
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	return Connections.get_active(base_dir)
end

-- Edit SSH config files using native picker
Api.edit = function()
	local Select = require("sshfs.ui.select")
	Select.ssh_config(function(config_file)
		if config_file then
			vim.cmd("edit " .. vim.fn.fnameescape(config_file))
		end
	end)
end

-- Reload SSH configuration
Api.reload = function()
	local Session = require("sshfs.session")
	Session.reload()
end

-- Browse remote files using native file browser
Api.find_files = function(opts)
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	if not Connections.has_active(base_dir) then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local Picker = require("sshfs.ui.picker")
	Picker.browse_remote_files(opts)
end

-- Browse remote files - smart handling for multiple mounts
Api.browse = function(opts)
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	local active_connections = Connections.get_all(base_dir)

	if #active_connections == 0 then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	elseif #active_connections == 1 then
		Api.find_files(opts)
	else
		Api.list_mounts()
	end
end

-- Search text in remote files using picker or native grep
Api.grep = function(pattern, opts)
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()
	if not Connections.has_active(base_dir) then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local Picker = require("sshfs.ui.picker")
	Picker.grep_remote_files(pattern, opts)
end

-- List all active mounts and open file picker for selected mount
Api.list_mounts = function()
	local Select = require("sshfs.ui.select")
	Select.mount(function(selected_mount)
		if selected_mount then
			local Picker = require("sshfs.ui.picker")
			local config = get_ui_config()
			local success, picker_name = Picker.try_open_file_picker(selected_mount.path, config, true)

			if not success then
				vim.notify(
					"Could not open file picker (" .. picker_name .. ") for: " .. selected_mount.path,
					vim.log.levels.WARN
				)
			end
		end
	end)
end

-- Change current directory to SSH mount
Api.change_to_mount_dir = function()
	local Navigate = require("sshfs.ui.navigate")
	Navigate.to_mount_dir()
end

return Api
