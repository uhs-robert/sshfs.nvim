-- lua/sshfs/integrations/oil.lua
-- Oil.nvim file manager integration

local Oil = {}

--- Attempts to open oil.nvim file manager
---@param cwd string Current working directory to open oil in
---@return boolean success True if oil was successfully opened
function Oil.try_files(cwd)
	local ok, oil = pcall(require, "oil")
	if ok and oil.open then
		oil.open(cwd)
		return true
	end
	return false
end

return Oil
