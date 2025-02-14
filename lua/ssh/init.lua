-- Author: Robert Hill
-- Description: SSH utilities for mounting remote servers
-- Usage: Use the check_and_mount function to mount a server if the directory is empty, otherwise explore the directory
--- Requires: sshfs
--- Optional: Snacks.explorer

local M = {}
local config = require("ssh.config")
local utils = require("ssh.utils")
local keymaps = require("ssh.keymaps")

function M.setup(user_opts)
	config.setup(user_opts)
	utils.get_ssh_config(false)
	keymaps.setup()
end

return M
