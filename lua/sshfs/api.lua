-- lua/sshfs/api.lua
-- Public API wrapper providing high-level functions (connect, disconnect, browse, grep, edit)

local Api = {}
local Config = require("sshfs.config")

--- Connect to SSH host - use picker if no host provided, otherwise connect directly
--- @param host string|nil SSH host to connect to (optional)
Api.connect = function(host)
	local Session = require("sshfs.session")
	if host then
		Session.connect({ Name = host })
	else
		local Select = require("sshfs.ui.select")
		Select.host(function(selected_host)
			if selected_host then
				Session.connect(selected_host)
			end
		end)
	end
end

--- Mount SSH host (alias for connect)
Api.mount = function()
	Api.connect()
end

--- Disconnect from current SSH host
Api.disconnect = function()
	local Session = require("sshfs.session")
	Session.disconnect()
end

--- Unmount from a SSH host
Api.unmount = function()
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local active_connections = Connections.get_all()

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

--- Check connection status
--- @return boolean True if any active connections exist
Api.has_active = function()
	local Connections = require("sshfs.lib.connections")
	return Connections.has_active()
end

--- Get current connection info
--- @return table|nil Connection info or nil if none active
Api.get_active = function()
	local Connections = require("sshfs.lib.connections")
	return Connections.get_active()
end

--- Edit SSH config files using native picker
Api.edit = function()
	local Select = require("sshfs.ui.select")
	Select.ssh_config(function(config_file)
		if config_file then
			vim.cmd("edit " .. vim.fn.fnameescape(config_file))
		end
	end)
end

--- Reload SSH configuration
Api.reload = function()
	local Session = require("sshfs.session")
	Session.reload()
end

--- Browse remote files using native file browser
--- @param opts table|nil Picker options
Api.find_files = function(opts)
	local Connections = require("sshfs.lib.connections")
	if not Connections.has_active() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local Picker = require("sshfs.ui.picker")
	Picker.browse_remote_files(opts)
end

--- Browse remote files - smart handling for multiple mounts
--- @param opts table|nil Picker options
Api.browse = function(opts)
	local Connections = require("sshfs.lib.connections")
	local active_connections = Connections.get_all()

	if #active_connections == 0 then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	elseif #active_connections == 1 then
		Api.find_files(opts)
	else
		Api.list_mounts()
	end
end

--- Search text in remote files using picker or native grep
--- @param pattern string|nil Search pattern
--- @param opts table|nil Picker options
Api.grep = function(pattern, opts)
	local Connections = require("sshfs.lib.connections")
	if not Connections.has_active() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local Picker = require("sshfs.ui.picker")
	Picker.grep_remote_files(pattern, opts)
end

--- List all active mounts and open file picker for selected mount
Api.list_mounts = function()
	local Select = require("sshfs.ui.select")
	Select.mount(function(selected_mount)
		if selected_mount then
			local Picker = require("sshfs.ui.picker")
			local config = Config.get()
			local success, picker_name = Picker.open_file_picker(selected_mount.mount_path, config, true)

			if not success then
				vim.notify(
					"Could not open file picker (" .. picker_name .. ") for: " .. selected_mount.mount_path,
					vim.log.levels.WARN
				)
			end
		end
	end)
end

--- Change current directory to SSH mount
Api.change_to_mount_dir = function()
	local Navigate = require("sshfs.ui.navigate")
	Navigate.to_mount_dir()
end

--- Open SSH terminal session to remote host
Api.ssh_terminal = function()
	local Navigate = require("sshfs.ui.navigate")
	Navigate.open_ssh_terminal()
end

return Api
