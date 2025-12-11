-- lua/sshfs/integrations/builtin.lua
-- Built-in grep integration (fallback)

local Builtin = {}

--- Attempts to use built-in grep via quickfix window
--- Falls back to opening empty quickfix if no pattern provided
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to execute
---@return boolean success True if built-in grep was successfully executed
function Builtin.grep(cwd, pattern)
	local ok = pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		if pattern and pattern ~= "" then
			vim.fn.setreg("/", pattern)
			vim.cmd("grep -r " .. vim.fn.shellescape(pattern) .. " .")
		else
			-- Open empty quickfix window for manual search
			vim.cmd("copen")
			vim.notify("Ready to search in " .. cwd .. ". Use :grep <pattern> to search.", vim.log.levels.INFO)
		end
	end)
	return ok
end

return Builtin
