-- lua/sshfs/lib/mount_point.lua
-- Mount point management, detection, creation, unmounting, and cleanup

local MountPoint = {}
local Directory = require("sshfs.lib.directory")
local Config = require("sshfs.config")

--- Get all active SSHFS mount paths from the system
--- @return table Array of mount path strings
local function get_system_mounts()
	local mount_paths = {}

	-- Try findmnt first (Linux only)
	local findmnt_result = vim.fn.system({ "findmnt", "-t", "fuse.sshfs", "-n", "-o", "TARGET" })
	if vim.v.shell_error == 0 then
		for line in findmnt_result:gmatch("[^\r\n]+") do
			table.insert(mount_paths, line)
		end
		return mount_paths
	end

	-- Fallback to mount command for broader compatibility
	local result = vim.fn.system("mount")
	if vim.v.shell_error ~= 0 then
		return mount_paths
	end

	-- Cross-platform patterns for detecting SSHFS mounts
	local pattern_templates = {
		"%s+on%s+([^%s]+)%s+type%s+fuse%.sshfs", -- Linux: "on /mount/path type fuse.sshfs"
		"%s+on%s+([^%s]+)%s+%(macfuse", -- macOS/osxfuse: "on /mount/path (macfuse"
		"%s+on%s+([^%s]+)%s+%(osxfuse", -- macOS/osxfuse older: "on /mount/path (osxfuse"
		"%s+on%s+([^%s]+)%s+%(fuse", -- Generic FUSE: "on /mount/path (fuse"
	}

	-- Only process lines that contain 'sshfs' to avoid false positives
	for line in result:gmatch("[^\r\n]+") do
		if line:match("sshfs") then
			for _, pattern in ipairs(pattern_templates) do
				local mount_path = line:match(pattern)
				if mount_path then
					table.insert(mount_paths, mount_path)
					break
				end
			end
		end
	end

	return mount_paths
end

--- Check if a mount path is actively mounted
--- @param mount_path string Path to check for active mount
--- @return boolean True if mount is active
function MountPoint.is_active(mount_path)
	local stat = vim.uv.fs_stat(mount_path)
	if not stat or stat.type ~= "directory" then
		return false
	end

	local mount_paths = get_system_mounts()
	for _, path in ipairs(mount_paths) do
		if path == mount_path then
			return true
		end
	end

	return false
end

--- List all active sshfs mounts
--- @return table Array of mount objects with host and mount_path fields
function MountPoint.list_active()
	local mounts = {}
	local base_mount_dir = Config.get_base_dir()
	local mount_paths = get_system_mounts()

	-- Filter to only include mounts under our base directory
	local mount_dir_escaped = base_mount_dir:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	local prefix_pattern = "^" .. mount_dir_escaped .. "/(.+)$"

	for _, mount_path in ipairs(mount_paths) do
		local host = mount_path:match(prefix_pattern)
		if host and host ~= "" then
			table.insert(mounts, { host = host, mount_path = mount_path })
		end
	end

	return mounts
end

--- Get or create mount directory
--- @param mount_dir string|nil Directory path (defaults to base mount dir from config)
--- @return boolean True if directory exists or was created successfully
function MountPoint.get_or_create(mount_dir)
	mount_dir = mount_dir or Config.get_base_dir()
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
	local base_mount_dir = Config.get_base_dir()
	local stat = vim.uv.fs_stat(base_mount_dir)
	if stat and stat.type == "directory" and Directory.is_empty(base_mount_dir) then
		vim.fn.delete(base_mount_dir, "d")
		return true
	end
	return false
end

--- Clean up stale mount directories that are empty and not actively mounted
--- Only removes empty directories to avoid interfering with user-managed mounts.
--- This is useful after unclean unmounts (crashes, force-kills, etc.) that leave empty mount points.
--- @return number Count of directories removed
function MountPoint.cleanup_stale()
	local base_mount_dir = Config.get_base_dir()
	local stat = vim.uv.fs_stat(base_mount_dir)
	if not stat or stat.type ~= "directory" then
		return 0
	end

	-- Scan for directories in base_mount_dir
	local files = vim.fn.glob(base_mount_dir .. "/*", false, true)
	local removed_count = 0

	for _, file in ipairs(files) do
		if vim.fn.isdirectory(file) == 1 then
			-- Only remove if directory is empty AND not actively mounted
			if Directory.is_empty(file) and not MountPoint.is_active(file) then
				MountPoint.unmount(file)
				local success = pcall(vim.fn.delete, file, "d")
				if success then
					removed_count = removed_count + 1
				end
			end
		end
	end

	return removed_count
end

return MountPoint
