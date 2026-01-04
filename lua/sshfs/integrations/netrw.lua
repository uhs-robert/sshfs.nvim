-- lua/sshfs/integrations/netrw.lua
-- Netrw file explorer integration (built-in fallback)

local config = require("sshfs.config")

local Netrw = {}

--- Attempts to open netrw file explorer
---@param cwd string Current working directory to open netrw in
---@return boolean success True if netrw was successfully opened
function Netrw.explore_files(cwd)
  local ok = pcall(function()
    local opts = config.get()
    local netrw_cmd = opts.ui.local_picker.netrw_command or "Explore"
    vim.cmd(netrw_cmd .. " " .. vim.fn.fnameescape(cwd))
  end)
  return ok
end

return Netrw
