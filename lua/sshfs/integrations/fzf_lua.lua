-- lua/sshfs/integrations/fzf_lua.lua
-- Fzf-lua file picker and search integration

local FzfLua = {}

--- Attempts to open fzf-lua file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if fzf-lua was successfully opened
function FzfLua.explore_files(cwd)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.files then
		fzf.files({ cwd = cwd })
		return true
	end
	return false
end

--- Attempts to open fzf-lua live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if fzf-lua was successfully opened
function FzfLua.grep(cwd, pattern)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.live_grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.query = pattern
		end
		fzf.live_grep(opts)
		return true
	end
	return false
end

return FzfLua
