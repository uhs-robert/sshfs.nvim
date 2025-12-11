-- lua/sshfs/init.lua
-- Plugin entry point for setup, configuration, and command registration

local App = {}

--- Creates API commands for vim api.
App.setup_api_commands = function()
	local Api = require("sshfs.api")

	-- Create commands
	vim.api.nvim_create_user_command("SSHConnect", function(opts)
		if opts.args and opts.args ~= "" then
			local SSHConfig = require("sshfs.lib.ssh_config")
			local host = SSHConfig.parse_host(opts.args)
			Api.connect(host)
		else
			Api.connect()
		end
	end, { nargs = "?", desc = "Remotely connect to host via picker or command as argument." })

	vim.api.nvim_create_user_command("SSHEdit", function()
		Api.edit()
	end, { desc = "Edit SSH config files" })

	vim.api.nvim_create_user_command("SSHReload", function()
		Api.reload()
	end, { desc = "Reload SSH configuration" })

	vim.api.nvim_create_user_command("SSHDisconnect", function()
		Api.unmount()
	end, { desc = "Disconnect from current SSH host" })

	vim.api.nvim_create_user_command("SSHBrowse", function()
		Api.browse()
	end, { desc = "Browse remote files" })

	vim.api.nvim_create_user_command("SSHGrep", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		Api.grep(pattern)
	end, { nargs = "?", desc = "Search text in remote files" })

	vim.api.nvim_create_user_command("SSHChangeDir", function()
		Api.change_to_mount_dir()
	end, { desc = "Set current directory to SSH mount" })
end

--- Main entry point for plugin initialization.
---@param user_opts table|nil User configuration options to merge with defaults
function App.setup(user_opts)
	local Config = require("sshfs.config")
	Config.setup(user_opts)
	local opts = Config.get()

	-- Initialize other modules
	local MountPoint = require("sshfs.lib.mount_point")
	MountPoint.get_or_create()
	require("sshfs.ui.keymaps").setup(opts)

	-- Setup exit handler if enabled
	if opts.mounts.unmount_on_exit then
		vim.api.nvim_create_autocmd("VimLeave", {
			callback = function()
				local Session = require("sshfs.session")
				local Connections = require("sshfs.lib.connections")
				local all_connections = Connections.get_all()

				for _, connection in ipairs(all_connections) do
					Session.disconnect_from(connection)
				end
			end,
			desc = "Cleanup SSH mounts on exit",
		})
	end

	App.setup_api_commands()
end

return App
