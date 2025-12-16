-- lua/sshfs/ui/autocommands.lua
-- UI-related autocommands for sshfs.nvim

local AutoCommands = {}

local STATE = { armed = false, base_dir = nil }

--- Check if path a starts with path b
--- @param a string|nil First path
--- @param b string|nil Second path
--- @return boolean True if a starts with b
local function starts_with(a, b)
	local norm = vim.fs.normalize
	a, b = norm(a or ""), norm(b or "")
	return a == b or vim.startswith(a, b .. "/")
end

-- Chdir-on-next-open (tab-local, armed once)
-- Changes to tab-local directory when opening file via SSHBrowse
local aug = vim.api.nvim_create_augroup("sshfs_chdir_next_open", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
	group = aug,
	pattern = "*",
	callback = function(args)
		if not STATE.armed then
			return
		end

		local is_not_a_file = vim.bo[args.buf].buftype ~= ""
		if is_not_a_file then
			return
		end

		local path = vim.api.nvim_buf_get_name(args.buf)
		if path == "" then
			return
		end

		local is_outside_base_dir = STATE.base_dir and not starts_with(path, STATE.base_dir)
		if is_outside_base_dir then
			return
		end

		vim.cmd("tcd " .. vim.fs.dirname(path))

		STATE.armed = false
		STATE.base_dir = nil
	end,
})

--- Arm autocommand to change directory on next file open
--- @param base_dir string|nil Base directory to restrict chdir to
function AutoCommands.chdir_on_next_open(base_dir)
	STATE.armed = true
	STATE.base_dir = base_dir
end

return AutoCommands
