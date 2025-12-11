-- lua/sshfs/integrations/lf.lua
-- Lf file manager integration

local Lf = {}

--- Attempts to open lf file manager
---@param cwd string Current working directory to open lf in
---@return boolean success True if lf was successfully opened
function Lf.try_files(cwd)
	local ok, lf = pcall(require, "lf")
	if ok and lf.start then
		lf.start(cwd)
		return true
	end
	return false
end

return Lf
