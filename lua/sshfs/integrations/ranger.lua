-- lua/sshfs/integrations/ranger.lua
-- Ranger file manager integration

local Ranger = {}

--- Creates a scratch buffer with a path in the target directory
---@param cwd string Target directory path
---@return number scratch_buf Buffer handle
local function create_scratch_buffer(cwd)
	local scratch_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(scratch_buf, cwd .. "/.ranger_target")
	return scratch_buf
end

--- Restores original buffer in window if showing scratch buffer
---@param win number Window handle
---@param orig_buf number Original buffer handle
---@param scratch_buf number Scratch buffer handle
local function restore_original_buffer(win, orig_buf, scratch_buf)
	if vim.api.nvim_win_get_buf(win) == scratch_buf and vim.api.nvim_buf_is_valid(orig_buf) then
		vim.api.nvim_win_set_buf(win, orig_buf)
	end
end

--- Cleans up scratch buffer and autocommand group
---@param scratch_buf number Scratch buffer handle
---@param augroup number Autocommand group ID
local function cleanup_scratch_resources(scratch_buf, augroup)
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(scratch_buf) then
			pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
		end
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
	end, 100)
end

--- Sets up autocommands to handle cleanup when ranger closes
---@param orig_win number Original window handle
---@param orig_buf number Original buffer handle
---@param scratch_buf number Scratch buffer handle
---@return number augroup Autocommand group ID
local function setup_cleanup_autocmds(orig_win, orig_buf, scratch_buf)
	local augroup = vim.api.nvim_create_augroup("RangerCleanup_" .. scratch_buf, { clear = true })
	local ranger_opened = false

	-- Detect when ranger terminal opens
	vim.api.nvim_create_autocmd("FileType", {
		group = augroup,
		pattern = "ranger",
		once = true,
		callback = function()
			ranger_opened = true
		end,
	})

	-- Detect when we return to the original window after ranger closes
	vim.api.nvim_create_autocmd("WinEnter", {
		group = augroup,
		callback = function()
			if ranger_opened and vim.api.nvim_get_current_win() == orig_win then
				restore_original_buffer(orig_win, orig_buf, scratch_buf)
				cleanup_scratch_resources(scratch_buf, augroup)
			end
		end,
	})

	return augroup
end

--- Opens ranger.nvim in the specified directory
---@param cwd string Directory to open ranger in
---@return boolean success True if ranger was opened successfully
local function open_ranger_nvim(cwd)
	local orig_buf = vim.api.nvim_get_current_buf()
	local orig_win = vim.api.nvim_get_current_win()
	local scratch_buf = create_scratch_buffer(cwd)

	vim.api.nvim_win_set_buf(orig_win, scratch_buf) -- Switch to scratch buffer so expand("%") picks it up
	setup_cleanup_autocmds(orig_win, orig_buf, scratch_buf)
	local ok, ranger = pcall(require, "ranger-nvim")
	ranger.open(true) -- select_current_file= true to use expand("%")

	return true
end

--- Opens rnvimr in the specified directory
---@param cwd string Directory to open rnvimr in
---@return boolean success True if rnvimr was opened successfully
local function open_rnvimr(cwd)
	return pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		vim.cmd("RnvimrToggle")
	end)
end

--- Attempts to open ranger file manager
--- Tries ranger.nvim first, falls back to rnvimr
---@param cwd string Current working directory to open ranger in
---@return boolean success True if ranger was successfully opened
function Ranger.explore_files(cwd)
	local ok, ranger = pcall(require, "ranger-nvim")
	if ok and ranger.open then
		return open_ranger_nvim(cwd)
	end

	return open_rnvimr(cwd)
end

return Ranger
