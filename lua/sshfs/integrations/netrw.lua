-- lua/sshfs/integrations/netrw.lua
-- Netrw file explorer integration (built-in fallback)

local Netrw = {}

--- Attempts to open netrw file explorer
---@param cwd string Current working directory to open netrw in
---@return boolean success True if netrw was successfully opened
function Netrw.explore_files(cwd)
	local ok = pcall(function()
		vim.cmd("Explore " .. vim.fn.fnameescape(cwd))
	end)
	return ok
end

return Netrw
