-- Author: Robert Hill
-- Description: SSH utilities for mounting remote servers
-- Usage: Use the check_and_mount function to mount a server if the directory is empty, otherwise explore the directory
--- Requires: snacks.nvim
--- Requires: sshfs
--- Requires: ~/.ssh/config with Host entries
---- Example: require("ssh").check_and_mount("~/Remote")

local M = {}
local utils = require("ssh.utils")
local keymaps = require("ssh.keymaps")

function M.setup()
	utils.refresh_servers(false)
	keymaps.setup()
end

return M
