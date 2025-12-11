-- lua/sshfs/init.lua
-- Plugin entry point for setup, configuration management, and command registration

local App = {}
local SSHConfig = require("sshfs.core.config")

local default_opts = {
	connections = {
		ssh_configs = SSHConfig.get_default_files(),
		sshfs_args = {
			"-o reconnect",
			"-o ConnectTimeout=5",
			"-o compression=yes",
			"-o ServerAliveInterval=15",
			"-o ServerAliveCountMax=3",
		},
	},
	mounts = {
		base_dir = vim.fn.expand("$HOME") .. "/mnt",
		unmount_on_exit = true,
		auto_change_dir_on_mount = false,
	},
	host_paths = {},
	handlers = {
		on_disconnect = {
			clean_mount_folders = true,
		},
	},
	ui = {
		file_picker = {
			auto_open_on_mount = true, -- Auto-open file picker after mounting (default: true)
			preferred_picker = "auto", -- "auto", "telescope", "oil", "neo-tree", "nvim-tree", "snacks", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
			fallback_to_netrw = true,
		},
	},
}

App.setup_commands = function()
	local Api = require("sshfs.api")

	-- Create commands
	vim.api.nvim_create_user_command("SSHConnect", function(opts)
		if opts.args and opts.args ~= "" then
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

function App.setup(user_opts)
	local opts = user_opts and vim.tbl_deep_extend("force", default_opts, user_opts) or default_opts

	-- Store config for access by other modules
	App._config = opts

	-- Initialize the session module
	local session = require("sshfs.session")
	session.setup(opts)

	-- Setup other modules
	require("sshfs.ui.keymaps").setup(opts)

	-- Setup exit handler if enabled
	if opts.mounts.unmount_on_exit then
		vim.api.nvim_create_autocmd("VimLeave", {
			callback = function()
				local connections = require("sshfs.lib.connections")
				local base_dir = opts.mounts and opts.mounts.base_dir
				local all_connections = connections.get_all(base_dir)

				for _, connection in ipairs(all_connections) do
					session.disconnect_from(connection)
				end
			end,
			desc = "Cleanup SSH mounts on exit",
		})
	end

	-- Create user commands
	App.setup_commands()
end

return App
