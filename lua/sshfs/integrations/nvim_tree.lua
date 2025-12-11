-- lua/sshfs/integrations/nvim_tree.lua
-- Nvim-tree file explorer integration

local NvimTree = {}

--- Attempts to open nvim-tree file explorer
---@param cwd string Current working directory to open nvim-tree in
---@return boolean success True if nvim-tree was successfully opened
function NvimTree.try_files(cwd)
	local ok = pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		vim.cmd("NvimTreeOpen")
	end)
	return ok
end

return NvimTree
