-- lua/sshfs/ui/keymaps.lua
-- Keymap configuration and registration for SSH commands with which-key integration support

local Keymaps = {}

local DEFAULT_PREFIX = "<leader>m"
local DEFAULT_KEYMAPS = {
	change_dir = "d",
	command = "o",
	config = "c",
	explore = "e",
	files = "f",
	grep = "g",
	live_find = "F",
	live_grep = "G",
	mount = "m",
	reload = "r",
	terminal = "t",
	unmount = "u",
	unmount_all = "U",
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
	vim.keymap.set("n", keymaps.unmount_all, Api.unmount_all, { desc = "Unmount all SSH Servers" })
	vim.keymap.set("n", keymaps.explore, Api.explore, { desc = "Explore SSH mount" })
	vim.keymap.set("n", keymaps.change_dir, Api.change_dir, { desc = "Change dir to mount" })
	vim.keymap.set("n", keymaps.command, Api.command, { desc = "Run command on mount" })
	vim.keymap.set("n", keymaps.config, Api.config, { desc = "Edit SSH config" })
	vim.keymap.set("n", keymaps.reload, Api.reload, { desc = "Reload SSH config" })
	vim.keymap.set("n", keymaps.files, Api.files, { desc = "Browse files" })
	vim.keymap.set("n", keymaps.grep, Api.grep, { desc = "Grep files" })
	vim.keymap.set("n", keymaps.live_find, Api.live_find, { desc = "Live find (remote)" })
	vim.keymap.set("n", keymaps.live_grep, Api.live_grep, { desc = "Live grep (remote)" })
	vim.keymap.set("n", keymaps.terminal, Api.ssh_terminal, { desc = "Open SSH Terminal" })

	-- TODO: Delete after January 15th.
	-- Handle deprecated keymap names
	if user_keymaps.open_dir then
		vim.notify("sshfs.nvim: Keymap 'open_dir' is deprecated. Use 'change_dir' instead.", vim.log.levels.WARN)
	end
	if user_keymaps.open then
		vim.notify("sshfs.nvim: Keymap 'open' is deprecated. Use 'files' instead.", vim.log.levels.WARN)
	end
	if user_keymaps.edit then
		vim.notify("sshfs.nvim: Keymap 'edit' is deprecated. Use 'config' instead.", vim.log.levels.WARN)
	end

	-- Check if which-key is installed before registering the group with an icon
	local ok, wk = pcall(require, "which-key")
	if ok then
		wk.add({
			{ "<leader>m", icon = { icon = "󰌘", color = "yellow", h1 = "WhichKey" }, group = "mount" },
		})
	end
end

return Keymaps
