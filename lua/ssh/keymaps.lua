-- Custom keymaps
local M = {}

local default_prefix = "<leader>m"

local default_keymaps = {
	edit = "e",
	find = "f",
	grep = "g",
	mount = "m",
	open = "o",
	reload = "r",
	unmount = "u",
}

local api = require("ssh.api")

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
	vim.keymap.set("n", lead_prefix, "<nop>", { desc = "mount" })

	-- Assign keymaps
	vim.keymap.set("n", keymaps.mount, api.mount, { desc = "Mount a SSH Seever" })
	vim.keymap.set("n", keymaps.unmount, api.unmount, { desc = "Unmount a SSH Server" })
	vim.keymap.set("n", keymaps.edit, api.edit, { desc = "Edit ssh_configs" })
	vim.keymap.set("n", keymaps.reload, api.reload, { desc = "Reload ssh_configs" })
	vim.keymap.set("n", keymaps.open, api.open_directory, { desc = "Open Mounted Directory" })
	vim.keymap.set("n", keymaps.find, api.find_files, { desc = "Find files in Directory" })
	vim.keymap.set("n", keymaps.grep, api.live_grep, { desc = "Live GREP" })

	-- Check if which-key is installed before registering the group with an icon
	local ok, wk = pcall(require, "which-key")
	if ok then
		wk.add({
			{ "<leader>m", icon = "󰌘", group = "mount" },
		})
	end
end

return M
