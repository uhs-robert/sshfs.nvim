-- lua/sshfs/ui/keymaps.lua
-- Keymap configuration and registration for SSH commands with which-key integration support

local Keymaps = {}

local DEFAULT_PREFIX = "<leader>m"
local DEFAULT_KEYMAPS = {
	change_dir = "d",
	edit = "e",
	grep = "g",
	mount = "m",
	open = "o",
	reload = "r",
	unmount = "u",
}

--- Setup keymaps for SSH commands
--- @param opts table|nil Configuration options with keymaps and lead_prefix
function Keymaps.setup(opts)
	local user_keymaps = opts and opts.keymaps or {}
	local lead_prefix = opts and opts.lead_prefix or DEFAULT_PREFIX

	-- Merge and apply prefix dynamically
	local keymaps = {}
	for key, suffix in pairs(DEFAULT_KEYMAPS) do
		keymaps[key] = user_keymaps[key] or (lead_prefix .. suffix)
	end

	-- Set prefix
	vim.keymap.set("n", lead_prefix, "<nop>", { desc = "mount" })

	-- Assign keymaps
	local Api = require("sshfs.api")
	vim.keymap.set("n", keymaps.mount, Api.mount, { desc = "Mount a SSH Server" })
	vim.keymap.set("n", keymaps.unmount, Api.unmount, { desc = "Unmount a SSH Server" })
	vim.keymap.set("n", keymaps.change_dir, Api.change_to_mount_dir, { desc = "Set current directory to SSH mount" })
	vim.keymap.set("n", keymaps.edit, Api.edit, { desc = "Edit ssh_configs" })
	vim.keymap.set("n", keymaps.reload, Api.reload, { desc = "Reload ssh_configs" })
	vim.keymap.set("n", keymaps.open, Api.browse, { desc = "Browse Mounted Directory" })
	vim.keymap.set("n", keymaps.grep, Api.grep, { desc = "GREP Mounted Directory" })

	-- Check if which-key is installed before registering the group with an icon
	local ok, wk = pcall(require, "which-key")
	if ok then
		wk.add({
			{ "<leader>m", icon = { icon = "󰌘", color = "yellow", h1 = "WhichKey" }, group = "mount" },
		})
	end
end

return Keymaps
