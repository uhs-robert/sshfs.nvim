-- lua/sshfs/integrations/ranger.lua
-- Ranger file manager integration

local Ranger = {}

--- Attempts to open ranger file manager
--- Tries ranger.nvim first, falls back to rnvimr
---@param cwd string Current working directory to open ranger in
---@return boolean success True if ranger was successfully opened
function Ranger.try_files(cwd)
	-- Try ranger.nvim first
	local ok, ranger = pcall(require, "ranger-nvim")
	if ok and ranger.open then
		ranger.open(true)
		return true
	end

	-- Try rnvimr as alternative
	local rnvimr_ok = pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		vim.cmd("RnvimrToggle")
	end)
	return rnvimr_ok
end

return Ranger
