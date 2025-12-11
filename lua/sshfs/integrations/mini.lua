-- lua/sshfs/integrations/mini.lua
-- Mini.pick file picker and search integration

local Mini = {}

--- Attempts to open mini.pick file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if mini.pick was successfully opened
function Mini.explore_files(cwd)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.files then
		mini_pick.builtin.files({ source = { cwd = cwd } })
		return true
	end
	return false
end

--- Attempts to open mini.pick live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if mini.pick was successfully opened
function Mini.grep(cwd, pattern)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.grep_live then
		local opts = {}
		if pattern and pattern ~= "" then
			opts.default_text = pattern
		end
		mini_pick.builtin.grep_live({ source = { cwd = cwd } }, opts)
		return true
	end
	return false
end

return Mini
