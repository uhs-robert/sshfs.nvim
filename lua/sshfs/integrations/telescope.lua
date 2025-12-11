-- lua/sshfs/integrations/telescope.lua
-- Telescope file picker and search integration

local Telescope = {}

--- Attempts to open telescope file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if telescope was successfully opened
function Telescope.explore_files(cwd)
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok and telescope.explore_files then
		telescope.explore_files({ cwd = cwd })
		return true
	end
	return false
end

--- Attempts to open telescope live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if telescope was successfully opened
function Telescope.grep(cwd, pattern)
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok and telescope.live_grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.default_text = pattern
		end
		telescope.live_grep(opts)
		return true
	end
	return false
end

return Telescope
