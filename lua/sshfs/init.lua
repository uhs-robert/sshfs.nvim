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

	-- Setup exit handler if enabled
	local hooks = opts.hooks or {}
	local on_exit = hooks.on_exit or {}
	if on_exit.auto_unmount then
		vim.api.nvim_create_autocmd("VimLeave", {
			callback = function()
				local Session = require("sshfs.session")
				-- Make a copy to avoid modifying table during iteration
				local all_connections = vim.list_extend({}, MountPoint.list_active())

				for _, connection in ipairs(all_connections) do
					Session.disconnect_from(connection)
				end
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
