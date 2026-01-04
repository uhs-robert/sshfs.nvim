-- lua/sshfs/integrations/nnn.lua
-- Nnn file manager integration

local Nnn = {}

--- Attempts to open nnn file manager
---@param cwd string Current working directory to open nnn in
---@return boolean success True if nnn was successfully opened
function Nnn.explore_files(cwd)
  local ok, _ = pcall(require, "nnn")
  if ok then
    -- nnn.nvim uses a command interface
    local success = pcall(function()
      vim.cmd("NnnPicker " .. vim.fn.fnameescape(cwd))
    end)
    return success
  end
  return false
end

return Nnn
