-- lua/sshfs/ui/hooks.lua

local Hooks = {}

--- Run post-mount action (tcd + optional hook)
--- @param mount_dir string Mount directory path
--- @param host string Host name
--- @param remote_path string|nil Remote path used for the mount
--- @param config table Plugin configuration
function Hooks.on_mount(mount_dir, host, remote_path, config)
	local hook_cfg = (config.hooks and config.hooks.on_mount) or {}
	local auto_change_to_dir = hook_cfg.auto_change_to_dir
	local action = hook_cfg.auto_run

	-- Auto-change directory to mount point if configured
	if auto_change_to_dir then
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
	end

	if action == nil or action == "none" then
		return
	end

	-- Allow custom handler
	if type(action) == "function" then
		local ok, err = pcall(action, {
			mount_path = mount_dir,
			host = host,
			remote_path = remote_path,
		})
		if not ok then
			vim.notify("on_mount callback failed: " .. err, vim.log.levels.ERROR)
		end
		return
	end

	-- Normalize preset names
	local preset = string.lower(action)
	if preset == "livefiles" then
		preset = "live_find"
	elseif preset == "livegrep" then
		preset = "live_grep"
	elseif preset == "files" or preset == "live_find" or preset == "live_grep" or preset == "grep" or preset == "terminal" then
		-- keep as is
	else
		preset = "files"
	end

	-- Resolve connection info for live_* actions
	local function get_connection()
		local Connections = require("sshfs.lib.connections")
		for _, conn in ipairs(Connections.get_all()) do
			if conn.mount_path == mount_dir then
				return conn
			end
		end
		return nil
	end

	if preset == "files" then
		local Picker = require("sshfs.ui.picker")
		local success, picker_name = Picker.open_file_picker(mount_dir, config, false)
		if not success then
			vim.notify("Failed to open " .. picker_name .. " for new mount: " .. mount_dir, vim.log.levels.ERROR)
		end
	elseif preset == "grep" then
		local Picker = require("sshfs.ui.picker")
		Picker.grep_remote_files(nil, { dir = mount_dir })
	elseif preset == "live_grep" or preset == "live_find" then
		local conn = get_connection()
		if not conn then
			vim.notify("No connection found for on_mount action: " .. mount_dir, vim.log.levels.WARN)
			return
		end
		local Picker = require("sshfs.ui.picker")
		local fn = preset == "live_grep" and Picker.open_live_remote_grep or Picker.open_live_remote_find
		local success, picker_name = fn(conn.host, conn.mount_path, conn.remote_path or ".", config)
		if not success then
			vim.notify("Live action failed: " .. picker_name, vim.log.levels.ERROR)
		end
	elseif preset == "terminal" then
		local Terminal = require("sshfs.ui.terminal")
		Terminal.open_ssh()
	end
end

return Hooks
