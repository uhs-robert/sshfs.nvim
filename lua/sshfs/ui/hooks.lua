-- lua/sshfs/ui/hooks.lua

local Hooks = {}

-- Normalize hook config value into either a callable or a known preset string.
--- @param action string|function|nil
--- @return string|function|nil normalized
local function normalize_action(action)
	if action == nil or action == "none" then
		return nil
	end

	if type(action) == "function" then
		return action
	end

	local preset = string.lower(action)
	if preset == "livefind" or preset == "live-find" then
		preset = "live_find"
	elseif preset == "livegrep" or preset == "live-grep" then
		preset = "live_grep"
	end

	local allowed = {
		find = true,
		live_find = true,
		live_grep = true,
		grep = true,
		terminal = true,
	}

	if not allowed[preset] then
		preset = "find"
	end

	return preset
end

-- Fetch the connection associated with a mount directory.
--- @param mount_dir string
--- @return table|nil connection
local function find_connection_by_mount(mount_dir)
	local Connections = require("sshfs.lib.connections")
	for _, conn in ipairs(Connections.get_all()) do
		if conn.mount_path == mount_dir then
			return conn
		end
	end
	return nil
end

-- Execute one of the built-in preset actions.
--- @param preset string
--- @param mount_dir string
--- @param config table
--- @return nil
local function run_preset_action(preset, mount_dir, config)
	if preset == "find" then
		local Picker = require("sshfs.ui.picker")
		local ok, picker_name = Picker.open_file_picker(mount_dir, config, false)
		if not ok then
			vim.notify("Failed to open " .. picker_name .. " for new mount: " .. mount_dir, vim.log.levels.ERROR)
		end
		return
	end

	if preset == "grep" then
		local Picker = require("sshfs.ui.picker")
		Picker.grep_remote_files(nil, { dir = mount_dir })
		return
	end

	if preset == "live_grep" or preset == "live_find" then
		local conn = find_connection_by_mount(mount_dir)
		if not conn then
			vim.notify("No connection found for on_mount action: " .. mount_dir .. " – falling back to local " .. (preset == "live_grep" and "grep" or "find"), vim.log.levels.WARN)
			return run_preset_action(preset == "live_grep" and "grep" or "find", mount_dir, config)
		end
		local Picker = require("sshfs.ui.picker")
		local fn = preset == "live_grep" and Picker.open_live_remote_grep or Picker.open_live_remote_find
		local ok, picker_name = fn(conn.host, conn.mount_path, conn.remote_path or ".", config)
		if not ok then
			vim.notify("Live action failed: " .. picker_name .. " – falling back to local " .. (preset == "live_grep" and "grep" or "find"), vim.log.levels.WARN)
			return run_preset_action(preset == "live_grep" and "grep" or "find", mount_dir, config)
		end
		return
	end

	if preset == "terminal" then
		local Terminal = require("sshfs.ui.terminal")
		Terminal.open_ssh()
	end
end

--- Run post-mount action (tcd + optional hook)
--- @param mount_dir string Mount directory path
--- @param host string Host name
--- @param remote_path string|nil Remote path used for the mount
--- @param config table Plugin configuration
function Hooks.on_mount(mount_dir, host, remote_path, config)
	local hook_cfg = (config.hooks and config.hooks.on_mount) or {}
	local auto_change_to_dir = hook_cfg.auto_change_to_dir
	local action = normalize_action(hook_cfg.auto_run)

	-- Auto-change directory to mount point if configured
	if auto_change_to_dir then
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
	end

	if action == nil then
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

	run_preset_action(action, mount_dir, config)
end

return Hooks
