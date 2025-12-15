-- lua/sshfs/ui/navigate.lua

local Navigate = {}

--- Navigate with file picker (with auto-change of dir if enabled)
--- @param mount_dir string Mount directory path
--- @param config table Plugin configuration
function Navigate.with_picker(mount_dir, config)
	-- Auto-change directory to mount point if configured
	if config.mounts and config.mounts.auto_change_dir_on_mount then
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
	end

	-- Try to auto-open file picker (respects auto_open_on_mount setting)
	if config.ui then
		local Picker = require("sshfs.ui.picker")
		local success, picker_name = Picker.open_file_picker(mount_dir, config, false)

		if not success and picker_name ~= "Auto-open disabled" then
			vim.notify("Failed to open " .. picker_name .. " for new mount: " .. mount_dir, vim.log.levels.ERROR)
		end
	end
end

--- Open SSH terminal session to remote host
function Navigate.open_ssh_terminal()
	local Connections = require("sshfs.lib.connections")
	local Ssh = require("sshfs.lib.ssh")
	local active_connections = Connections.get_all()

	if #active_connections == 0 then
		vim.notify("No active SSH connections", vim.log.levels.WARN)
		return
	end

	if #active_connections == 1 then
		local conn = active_connections[1]
		Ssh.open_terminal(conn.host, conn.remote_path)
		return
	end

	local items = {}
	for _, conn in ipairs(active_connections) do
		table.insert(items, conn.host)
	end

	vim.ui.select(items, {
		prompt = "Select host for SSH terminal:",
	}, function(_, idx)
		if idx then
			local conn = active_connections[idx]
			Ssh.open_terminal(conn.host, conn.remote_path)
		end
	end)
end

return Navigate
