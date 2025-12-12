-- lua/sshfs/ui/navigate.lua

local Navigate = {}

--- Change to mounted directory
function Navigate.to_mount_dir()
	local Connections = require("sshfs.lib.connections")
	local active_connections = Connections.get_all()

	if #active_connections == 0 then
		vim.notify("No active SSH connections", vim.log.levels.WARN)
		return
	end

	if #active_connections == 1 then
		local mount_dir = active_connections[1].mount_point
		vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
		vim.notify("Changed to: " .. mount_dir, vim.log.levels.INFO)
		return
	end

	local items = {}
	for _, conn in ipairs(active_connections) do
		local host_name = conn.host and conn.host.Name or "unknown"
		table.insert(items, host_name)
	end

	vim.ui.select(items, {
		prompt = "Select mount to change to:",
	}, function(_, idx)
		if idx then
			local mount_dir = active_connections[idx].mount_point
			vim.cmd("tcd " .. vim.fn.fnameescape(mount_dir))
			vim.notify("Changed to: " .. mount_dir, vim.log.levels.INFO)
		end
	end)
end

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

return Navigate
