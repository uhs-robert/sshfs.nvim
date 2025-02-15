local M = {}

local default_prefix = "<leader>m"

local default_keymaps = {
	edit = "e",
	find = "f",
	mount = "m",
	open = "o",
	reload = "r",
	unmount = "u",
}

local utils = require("ssh.utils")

function M.setup(opts)
	opts = opts or {}
	local user_keymaps = opts.keymaps or {}
	local lead_prefix = opts.lead_prefix or default_prefix

	-- Merge and apply prefix dynamically
	local keymaps = {}
	for key, suffix in pairs(default_keymaps) do
		keymaps[key] = user_keymaps[key] or (lead_prefix .. suffix)
	end

	-- Set prefix
	vim.keymap.set("n", lead_prefix, "<nop>", { desc = "SSH Mount Prefix" })

	-- Assign keymaps
	vim.keymap.set("n", keymaps.mount, function()
		utils.user_pick_mount()
	end, { desc = "Mount a SSH Server" })

	vim.keymap.set("n", keymaps.unmount, function()
		utils.user_pick_unmount()
	end, { desc = "Unmount a SSH Server" })

	vim.keymap.set("n", keymaps.reload, function()
		utils.get_ssh_config(true)
	end, { desc = "Reload SSH Server Config List" })

	vim.keymap.set("n", keymaps.open, function()
		utils.open_directory()
	end, { desc = "Open Mounted Directory" })
end

return M
