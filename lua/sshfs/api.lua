-- lua/sshfs/api.lua
-- Public API wrapper providing high-level functions (connect, disconnect, browse, grep, edit)

local Api = {}
local Config = require("sshfs.config")

--- Connect to SSH host - use picker if no host provided, otherwise connect directly
--- @param host table|nil SSH host object (optional)
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
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

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

--- Unmount all active SSH connections
Api.unmount_all = function()
	local Session = require("sshfs.session")
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

	if #active_connections == 0 then
		vim.notify("No active mounts to disconnect", vim.log.levels.WARN)
		return
	end

	-- Make a copy to avoid modifying table during iteration
	local all_connections = vim.list_extend({}, active_connections)
	local disconnected_count = 0
	for _, connection in ipairs(all_connections) do
		if Session.disconnect_from(connection, true) then
			disconnected_count = disconnected_count + 1
		end
	end

	vim.notify(
		string.format("Disconnected from %d mount%s", disconnected_count, disconnected_count == 1 and "" or "s"),
		vim.log.levels.INFO
	)
end

--- Check connection status
--- @return boolean True if any active connections exist
Api.has_active = function()
	local MountPoint = require("sshfs.lib.mount_point")
	return MountPoint.has_active()
end

--- Get current connection info
--- @return table|nil Connection info or nil if none active
Api.get_active = function()
	local MountPoint = require("sshfs.lib.mount_point")
	return MountPoint.get_active()
end

--- Edit SSH config files using native picker
Api.config = function()
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
	local MountPoint = require("sshfs.lib.mount_point")
	if not MountPoint.has_active() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local Picker = require("sshfs.ui.picker")
	Picker.browse_remote_files(opts)
end

--- Browse remote files - smart handling for multiple mounts
--- @param opts table|nil Picker options
Api.files = function(opts)
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

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
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

	if #active_connections == 0 then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	elseif #active_connections == 1 then
		local Picker = require("sshfs.ui.picker")
		Picker.grep_remote_files(pattern, opts)
	else
		local Select = require("sshfs.ui.select")
		Select.mount(function(selected_mount)
			if selected_mount then
				local Picker = require("sshfs.ui.picker")
				local grep_opts = opts or {}
				grep_opts.dir = selected_mount.mount_path
				Picker.grep_remote_files(pattern, grep_opts)
			end
		end)
	end
end

--- List all active mounts and open file picker for selected mount
Api.list_mounts = function()
	local Select = require("sshfs.ui.select")
	Select.mount(function(selected_mount)
		if selected_mount then
			local Picker = require("sshfs.ui.picker")
			local config = Config.get()
			local success, picker_name = Picker.open_file_picker(selected_mount.mount_path, config)

			if not success then
				vim.notify(
					"Could not open file picker (" .. picker_name .. ") for: " .. selected_mount.mount_path,
					vim.log.levels.WARN
				)
			end
		end
	end)
end

--- Run a custom command on SSHFS mount (prompts for command if not provided)
--- @param cmd string|nil Command to run (e.g., "edit", "tcd", "Oil"). If nil, prompts user.
Api.command = function(cmd)
	local MountPoint = require("sshfs.lib.mount_point")
	MountPoint.run_command(cmd)
end

--- Explore SSHFS mount (opens directory as buffer, triggering file explorer)
Api.explore = function()
	local MountPoint = require("sshfs.lib.mount_point")
	MountPoint.run_command("edit")
end

--- Change directory to an SSHFS mount
Api.change_dir = function()
	local MountPoint = require("sshfs.lib.mount_point")
	MountPoint.run_command("tcd")
end

--- Open SSH terminal session to remote host
Api.ssh_terminal = function()
	local Terminal = require("sshfs.ui.terminal")
	Terminal.open_ssh()
end

--- Live grep on mounted remote host (requires telescope or fzf-lua and active connection)
--- Executes ripgrep/grep directly on remote server via SSH and streams results
--- Note: Requires an active mount. Use :SSHConnect first.
---@param path string|nil Remote path to search (defaults to mounted remote path)
Api.live_grep = function(path)
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

	if #active_connections == 0 then
		vim.notify("Not connected to any remote host. Use :SSHConnect first.", vim.log.levels.WARN)
		return
	end

	local function fallback_to_local_grep(connection)
		local Picker = require("sshfs.ui.picker")
		Picker.grep_remote_files(nil, { dir = connection.mount_path })
	end

	local function execute_live_grep(connection)
		local Picker = require("sshfs.ui.picker")
		local config = Config.get()
		local search_path = connection.remote_path or path or "."

		local success, picker_name =
			Picker.open_live_remote_grep(connection.host, connection.mount_path, search_path, config)

		if not success then
			vim.notify(
				"Live grep not available: " .. picker_name .. ". Falling back to local grep on mounted path.",
				vim.log.levels.WARN
			)
			return fallback_to_local_grep(connection)
		end
	end

	if #active_connections == 1 then
		execute_live_grep(active_connections[1])
	else
		-- Multiple mounts - prompt for selection
		local Select = require("sshfs.ui.select")
		Select.mount(function(selected_mount)
			if selected_mount then
				execute_live_grep(selected_mount)
			end
		end)
	end
end

--- Live find on mounted remote host (requires telescope or fzf-lua and active connection)
--- Executes fd/find directly on remote server via SSH and streams results
--- Note: Requires an active mount. Use :SSHConnect first.
---@param path string|nil Remote path to search (defaults to mounted remote path)
Api.live_find = function(path)
	local MountPoint = require("sshfs.lib.mount_point")
	local active_connections = MountPoint.list_active()

	if #active_connections == 0 then
		vim.notify("Not connected to any remote host. Use :SSHConnect first.", vim.log.levels.WARN)
		return
	end

	local function fallback_to_local_find(connection)
		local Picker = require("sshfs.ui.picker")
		local config = Config.get()
		local ok, picker_name = Picker.open_file_picker(connection.mount_path, config)
		if not ok then
			vim.notify(
				"Fallback file picker failed for "
					.. connection.mount_path
					.. " ("
					.. picker_name
					.. "). Install a supported picker.",
				vim.log.levels.ERROR
			)
		end
	end

	local function execute_live_find(connection)
		local Picker = require("sshfs.ui.picker")
		local config = Config.get()
		local search_path = connection.remote_path or path or "."

		local success, picker_name =
			Picker.open_live_remote_find(connection.host, connection.mount_path, search_path, config)

		if not success then
			vim.notify(
				"Live find not available: " .. picker_name .. ". Falling back to local find on mounted path.",
				vim.log.levels.WARN
			)
			return fallback_to_local_find(connection)
		end
	end

	if #active_connections == 1 then
		execute_live_find(active_connections[1])
	else
		-- Multiple mounts - prompt for selection
		local Select = require("sshfs.ui.select")
		Select.mount(function(selected_mount)
			if selected_mount then
				execute_live_find(selected_mount)
			end
		end)
	end
end

-- TODO: Remove these after January 15th
-- Deprecated aliases (kept for backward compatibility)
--- @deprecated Use config instead
Api.edit = Api.config

--- @deprecated Use files instead
Api.browse = Api.files

--- @deprecated Use explore instead
Api.change_to_mount_dir = Api.explore

--- Creates API commands for vim api.
Api.setup = function()
	vim.api.nvim_create_user_command("SSHConnect", function(opts)
		if opts.args and opts.args ~= "" then
			local SSHConfig = require("sshfs.lib.ssh_config")
			local host = SSHConfig.parse_host(opts.args)
			Api.connect(host)
		else
			Api.connect()
		end
	end, { nargs = "?", desc = "Remotely connect to host via picker or command as argument." })

	vim.api.nvim_create_user_command("SSHConfig", function()
		Api.config()
	end, { desc = "Edit SSH config files" })

	vim.api.nvim_create_user_command("SSHReload", function()
		Api.reload()
	end, { desc = "Reload SSH configuration" })

	vim.api.nvim_create_user_command("SSHDisconnect", function()
		Api.unmount()
	end, { desc = "Disconnect from current SSH host" })

	vim.api.nvim_create_user_command("SSHDisconnectAll", function()
		Api.unmount_all()
	end, { desc = "Disconnect from all SSH hosts" })

	vim.api.nvim_create_user_command("SSHTerminal", function()
		Api.ssh_terminal()
	end, { desc = "Open SSH terminal session to remote host" })

	vim.api.nvim_create_user_command("SSHFiles", function()
		Api.files()
	end, { desc = "Browse remote files" })

	vim.api.nvim_create_user_command("SSHLiveFind", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		Api.live_find(pattern)
	end, { nargs = "?", desc = "Live find on mounted remote host" })

	vim.api.nvim_create_user_command("SSHGrep", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		Api.grep(pattern)
	end, { nargs = "?", desc = "Search text in remote files" })

	vim.api.nvim_create_user_command("SSHLiveGrep", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		Api.live_grep(pattern)
	end, { nargs = "?", desc = "Live grep on mounted remote host" })

	vim.api.nvim_create_user_command("SSHExplore", function()
		Api.explore()
	end, { desc = "Explore SSH mount" })

	vim.api.nvim_create_user_command("SSHCommand", function(opts)
		local cmd = opts.args and opts.args ~= "" and opts.args or nil
		Api.command(cmd)
	end, { nargs = "?", desc = "Run command on SSH mount (e.g., :SSHCommand tcd)" })

	vim.api.nvim_create_user_command("SSHChangeDir", function()
		Api.change_dir()
	end, { desc = "Change directory to SSH mount" })

	-- TODO: Delete these after January 15th
	-- Deprecated command aliases
	vim.api.nvim_create_user_command("SSHEdit", function()
		vim.notify("SSHEdit is deprecated. Use :SSHConfig instead.", vim.log.levels.WARN)
		Api.config()
	end, { desc = "Edit SSH config files (deprecated: use SSHConfig)" })

	vim.api.nvim_create_user_command("SSHBrowse", function()
		vim.notify("SSHBrowse is deprecated. Use :SSHFiles instead.", vim.log.levels.WARN)
		Api.files()
	end, { desc = "Browse remote files (deprecated: use SSHFiles)" })
end

return Api
