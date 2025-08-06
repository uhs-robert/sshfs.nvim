-- Author: Robert Hill
-- Fork of nosduco/remote-sshfs.nvim
-- Description: SSH utilities for mounting remote servers

local M = {}
local ssh_config = require("nvim_ssh.core.config")

local default_opts = {
	connections = {
		ssh_configs = ssh_config.get_default_ssh_configs(),
		sshfs_args = {
			"-o reconnect",
			"-o ConnectTimeout=5",
			"-o compression=true",
			"-o server_alive_interval=15",
			"-o server_alive_count_max=3",
		},
	},
	mounts = {
		base_dir = vim.fn.expand("$HOME") .. "/mnt",
		unmount_on_exit = true,
	},
	handlers = {
		on_disconnect = {
			clean_mount_folders = true,
		},
	},
	ui = {
		select_prompts = true,
		file_picker = {
			auto_open = true,
			auto_open_on_mount = true, -- Auto-open file picker after mounting (default: true)
			preferred_picker = "auto", -- "auto", "telescope", "oil", "neo-tree", "nvim-tree", "snacks", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
			fallback_to_netrw = true,
		},
	},
	log = {
		enabled = false,
		truncate = false,
		types = {
			all = false,
			util = false,
			handler = false,
			sshfs = false,
		},
	},
}

M.setup_commands = function()
	local api = require("nvim_ssh.api")

	-- Create commands
	vim.api.nvim_create_user_command("SSHConnect", function(opts)
		if opts.args and opts.args ~= "" then
			local host = ssh_config.parse_host_from_command(opts.args)
			api.connect(host)
		else
			api.connect()
		end
	end, { nargs = "?", desc = "Remotely connect to host via picker or command as argument." })

	vim.api.nvim_create_user_command("SSHEdit", function()
		api.edit()
	end, { desc = "Edit SSH config files" })

	vim.api.nvim_create_user_command("SSHReload", function()
		api.reload()
	end, { desc = "Reload SSH configuration" })

	vim.api.nvim_create_user_command("SSHDisconnect", function()
		api.unmount()
	end, { desc = "Disconnect from current SSH host" })

	vim.api.nvim_create_user_command("SSHFindFiles", function()
		api.find_files()
	end, { desc = "Find files on remote host" })

	vim.api.nvim_create_user_command("SSHLiveGrep", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		api.live_grep(pattern)
	end, { nargs = "?", desc = "Search text in remote files" })

	vim.api.nvim_create_user_command("SSHBrowse", function()
		api.browse()
	end, { desc = "Browse remote files" })

	vim.api.nvim_create_user_command("SSHGrep", function(opts)
		local pattern = opts.args and opts.args ~= "" and opts.args or nil
		api.grep(pattern)
	end, { nargs = "?", desc = "Search text in remote files (alias)" })

	vim.api.nvim_create_user_command("SSHListMounts", function()
		api.list_mounts()
	end, { desc = "List all mounted SSH directories and jump to selected one" })
end

function M.setup(user_opts)
	local opts = user_opts and vim.tbl_deep_extend("force", default_opts, user_opts) or default_opts

	-- Store config for access by other modules
	M._config = opts

	-- Initialize the connections module
	local connections = require("nvim_ssh.core.connections")
	connections.setup(opts)

	-- Setup other modules
	require("nvim_ssh.ui.prompts").setup(opts.ui or {})
	require("nvim_ssh.utils.log").setup(opts)
	require("nvim_ssh.ui.keymaps").setup(opts)

	-- Setup exit handler if enabled
	if opts.mounts.unmount_on_exit then
		vim.api.nvim_create_autocmd("VimLeave", {
			callback = function()
				local connections = require("nvim_ssh.core.connections")
				local all_connections = connections.get_all_connections()
				
				for _, connection in ipairs(all_connections) do
					connections.disconnect_specific(connection)
				end
			end,
			desc = "Cleanup SSH mounts on exit"
		})
	end

	-- Create user commands
	M.setup_commands()
end

return M
