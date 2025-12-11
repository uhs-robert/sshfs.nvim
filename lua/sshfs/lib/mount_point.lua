-- lua/sshfs/lib/mount_point.lua
-- Mount point management, detection, creation, unmounting, and cleanup

local MountPoint = {}
local Directory = require("sshfs.lib.directory")
local Config = require("sshfs.config")
local BASE_MOUNT_DIR = Config.get_base_dir()

--- Check if a mount path is actively mounted
--- @param mount_path string Path to check for active mount
--- @return boolean True if mount is active
function MountPoint.is_active(mount_path)
	local stat = vim.uv.fs_stat(mount_path)
	if not stat or stat.type ~= "directory" then
		return false
	end

	-- Use simpler approach with vim.fn.system for reliability
	local result = vim.fn.system("mount")
	-- Fall back to directory check
	if vim.v.shell_error ~= 0 then
		return not Directory.is_empty(mount_path)
	end

	-- Look for the specific mount path in the mount output
	local mount_path_escaped = mount_path:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	local pattern = "%s+" .. mount_path_escaped .. "%s+type%s+fuse%.sshfs"

	for line in result:gmatch("[^\r\n]+") do
		if line:match(pattern) then
			return true
		end
	end

	-- If not found in mount output, fall back to directory check
	return not Directory.is_empty(mount_path)
end

--- List all active sshfs mounts
--- @return table Array of mount objects with alias and path fields
function MountPoint.list_active()
	local mounts = {}

	local result = vim.fn.system("mount")
	if vim.v.shell_error ~= 0 then
		-- Fall back to directory scanning
		local files = vim.fn.glob(BASE_MOUNT_DIR .. "/*", false, true)
		for _, file in ipairs(files) do
			if vim.fn.isdirectory(file) == 1 and not Directory.is_empty(file) then
				local alias = vim.fn.fnamemodify(file, ":t")
				table.insert(mounts, { alias = alias, path = file })
			end
		end
		return mounts
	end

	-- Look for sshfs mounts in the specified mount directory
	local mount_dir_escaped = BASE_MOUNT_DIR:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	local pattern = "%s+(" .. mount_dir_escaped .. "/[^%s]+)%s+type%s+fuse%.sshfs"

	for line in result:gmatch("[^\r\n]+") do
		local path = line:match(pattern)
		if path then
			local alias = path:match("([^/]+)$")
			if alias then
				table.insert(mounts, { alias = alias, path = path })
			end
		end
	end

	return mounts
end

--- Get or create mount directory
--- @param mount_dir string|nil Directory path (defaults to BASE_MOUNT_DIR)
--- @return boolean True if directory exists or was created successfully
function MountPoint.get_or_create(mount_dir)
	mount_dir = mount_dir or BASE_MOUNT_DIR
	local stat = vim.uv.fs_stat(mount_dir)
	if stat and stat.type == "directory" then
		return true
	end

	local success = vim.fn.mkdir(mount_dir, "p")
	return success == 1
end

--- Unmount an sshfs mount using fusermount/umount
--- @param mount_path string Path to unmount
--- @return boolean True if unmount succeeded
function MountPoint.unmount(mount_path)
	local commands = {
		{ "fusermount", { "-u", mount_path } },
		{ "fusermount3", { "-u", mount_path } },
		{ "umount", { "-l", mount_path } },
	}

	for _, cmd in ipairs(commands) do
		local command, args = cmd[1], cmd[2]
		-- Use jobstart for safer command execution
		local job_id = vim.fn.jobstart(vim.list_extend({ command }, args), {
			stdout_buffered = true,
			stderr_buffered = true,
		})
		local exit_code = -1
		if job_id > 0 then
			local result = vim.fn.jobwait({ job_id }, 5000)[1] -- 5 second timeout
			exit_code = result or -1
		end

		if exit_code == 0 then
			vim.fn.delete(mount_path, "d")
			return true
		end
	end

	return false
end

--- Clean up base mount directory if empty
--- @return boolean True if cleanup succeeded
function MountPoint.cleanup()
	local stat = vim.uv.fs_stat(BASE_MOUNT_DIR)
	if stat and stat.type == "directory" and Directory.is_empty(BASE_MOUNT_DIR) then
		vim.fn.delete(BASE_MOUNT_DIR, "d")
		return true
	end
	return false
end

return MountPoint
