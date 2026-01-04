-- lua/sshfs/integrations/neo_tree.lua
-- Neo-tree file explorer integration

local NeoTree = {}

--- Attempts to open neo-tree file explorer
---@param cwd string Current working directory to reveal in neo-tree
---@return boolean success True if neo-tree was successfully opened
function NeoTree.explore_files(cwd)
  local ok = pcall(function()
    vim.cmd("Neotree filesystem reveal dir=" .. vim.fn.fnameescape(cwd))
  end)
  return ok
end

return NeoTree
