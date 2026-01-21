-- lua/sshfs/init.lua
-- Plugin entry point for setup, configuration, and command registration

local App = {}

--- Main entry point for plugin initialization.
---@param user_opts table|nil User configuration options to merge with defaults
function App.setup(user_opts)
  local Config = require("sshfs.config")
  Config.setup(user_opts)
  local opts = Config.get()

  -- Initialize other modules
  local MountPoint = require("sshfs.lib.mount_point")
  MountPoint.get_or_create()
  MountPoint.cleanup_stale()
  require("sshfs.ui.keymaps").setup(opts)

  -- Register in lockfile when opening files from a mount (for instances that didn't create the mount)
  local base_dir = opts.mounts.base_dir
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(ev)
      local buf_path = vim.api.nvim_buf_get_name(ev.buf)
      if buf_path == "" then return end

      -- Check if buffer path is inside the mount base directory
      local base_dir_slash = base_dir .. "/"
      if buf_path:sub(1, #base_dir_slash) ~= base_dir_slash then return end

      -- Extract mount path (base_dir/hostname)
      local rest = buf_path:sub(#base_dir_slash + 1)
      local hostname = rest:match("^([^/]+)")
      if not hostname then return end

      local mount_path = base_dir .. "/" .. hostname

      -- Only register if this is an active mount
      if MountPoint.is_active(mount_path) then
        local Lockfile = require("sshfs.lib.lockfile")
        Lockfile.register(mount_path)
      end
    end,
    desc = "Register in lockfile when accessing SSHFS mount",
  })

  -- Setup exit handler if enabled
  local hooks = opts.hooks or {}
  local on_exit = hooks.on_exit or {}
  if on_exit.auto_unmount then
    vim.api.nvim_create_autocmd("VimLeave", {
      callback = function()
        local Session = require("sshfs.session")
        Session.cleanup_unused_mounts()
      end,
      desc = "Cleanup SSH mounts on exit",
    })
  end

  local Api = require("sshfs.api")
  Api.setup()
end

-- Expose public API methods on App object for require("sshfs").method() usage
local Api = require("sshfs.api")
App.connect = Api.connect
App.mount = Api.mount
App.disconnect = Api.disconnect
App.unmount = Api.unmount
App.unmount_all = Api.unmount_all
App.has_active = Api.has_active
App.get_active = Api.get_active
App.config = Api.config
App.reload = Api.reload
App.files = Api.files
App.grep = Api.grep
App.live_grep = Api.live_grep
App.live_find = Api.live_find
App.explore = Api.explore
App.change_dir = Api.change_dir
App.ssh_terminal = Api.ssh_terminal
App.command = Api.command

return App
