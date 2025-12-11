-- lua/sshfs/integrations/yazi.lua
-- Yazi file manager integration

local Yazi = {}

--- Attempts to open yazi file manager
---@param cwd string Current working directory to open yazi in
---@return boolean success True if yazi was successfully opened
function Yazi.try_files(cwd)
	local ok, yazi = pcall(require, "yazi")
	if ok and yazi.yazi then
		yazi.yazi({ open_for_directories = true }, cwd)
		return true
	end
	return false
end

return Yazi
