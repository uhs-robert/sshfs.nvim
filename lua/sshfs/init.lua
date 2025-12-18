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

--- Main entry point for plugin initialization.
---@param user_opts table|nil User configuration options to merge with defaults
function App.setup(user_opts)
	local Config = require("sshfs.config")
	Config.setup(user_opts)
	local opts = Config.get()

	-- Initialize other modules
	local MountPoint = require("sshfs.lib.mount_point")
	MountPoint.get_or_create()
	MountPoint.cleanup_stale()
	require("sshfs.ui.keymaps").setup(opts)

	-- Setup exit handler if enabled
	local hooks = opts.hooks or {}
	local on_exit = hooks.on_exit or {}
	if on_exit.auto_unmount then
		vim.api.nvim_create_autocmd("VimLeave", {
			callback = function()
				local Session = require("sshfs.session")
				-- Make a copy to avoid modifying table during iteration
				local all_connections = vim.list_extend({}, MountPoint.list_active())

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
