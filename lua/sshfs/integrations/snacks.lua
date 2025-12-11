-- lua/sshfs/integrations/snacks.lua
-- Snacks.nvim picker and search integration

local Snacks = {}

--- Attempts to open snacks.nvim file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if snacks picker was successfully opened
function Snacks.explore_files(cwd)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.files then
		snacks.picker.files({ cwd = cwd })
		return true
	end
	return false
end

--- Attempts to open snacks.nvim grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if snacks grep was successfully opened
function Snacks.grep(cwd, pattern)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.search = pattern
		end
		snacks.picker.grep(opts)
		return true
	end
	return false
end

return Snacks
