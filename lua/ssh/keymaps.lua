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
	vim.keymap.set("n", lead_prefix, "<nop>", { desc = "Mount" })

	-- Assign keymaps
	vim.keymap.set("n", keymaps.mount, function()
		api.mount()
	end, { desc = "Mount a SSH Server" })

	vim.keymap.set("n", keymaps.unmount, function()
		api.unmount()
	end, { desc = "Unmount a SSH Server" })

	vim.keymap.set("n", keymaps.edit, function()
		api.open_directory()
	end, { desc = "Edit ssh_configs" })

	vim.keymap.set("n", keymaps.reload, function()
		api.reload()
	end, { desc = "Reload ssh_configs" })

	vim.keymap.set("n", keymaps.open, function()
		api.open_directory()
	end, { desc = "Open Mounted Directory" })

	vim.keymap.set("n", keymaps.find, function()
		api.find_files()
	end, { desc = "Find files in Directory" })

	vim.keymap.set("n", keymaps.grep, function()
		api.open_directory()
	end, { desc = "Live GREP" })
end

return M
