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

return Navigate
