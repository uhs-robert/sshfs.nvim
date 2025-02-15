-- Author: Robert Hill
-- Fork of nosduco/remote-sshfs.nvim
-- Description: SSH utilities for mounting remote servers

local M = {}

local default_opts = {
	connections = {
		ssh_configs = {
			vim.fn.expand("$HOME") .. "/.ssh/config",
			"/etc/ssh/ssh_config",
			-- "/path/to/custom/ssh_config"
		},
		sshfs_args = {
			"-o reconnect",
			"-o ConnectTimeout=5",
		},
	},
	mounts = {
		base_dir = vim.fn.expand("$HOME") .. "/.sshfs/",
		unmount_on_exit = true,
	},
	handlers = {
		on_connect = {
			change_dir = true,
		},
		on_disconnect = {
			clean_mount_folders = true,
		},
	},
	ui = {
		confirm = {
			change_dir = false,
		},
	},
	log = {
		enable = false,
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
	local api = require("ssh.api")

	-- Create commands to connect/edit/reload/disconnect/find_files/live_grep
	vim.api.nvim_create_user_command("SSHConnect", function(opts)
		if opts.args and opts.args ~= "" then
			local host = require("ssh.utils").parse_host_from_command(opts.args)
			api.connect(host)
		else
			api.connect()
		end
	end, { nargs = "?", desc = "Remotely connect to host via picker or command as argument." })
	vim.api.nvim_create_user_command("SSHEdit", function()
		api.edit()
	end, {})
	vim.api.nvim_create_user_command("SSHReload", function()
		api.reload()
	end, {})
	vim.api.nvim_create_user_command("SSHDisconnect", function()
		api.unmount()
	end, {})
	vim.api.nvim_create_user_command("SSHFindFiles", function()
		api.find_files()
	end, {})
	vim.api.nvim_create_user_command("SSHLiveGrep", function()
		api.live_grep()
	end, {})
end

function M.setup(user_opts)
	local opts = user_opts and vim.tbl_deep_extend("force", default_opts, user_opts) or default_opts
	require("ssh.connections").setup(opts)
	require("ssh.ui").setup(opts)
	require("ssh.handlers").setup(opts)
	require("ssh.log").setup(opts)
	require("ssh.keymaps").setup(opts)
	M.setup_commands()
end

return M
