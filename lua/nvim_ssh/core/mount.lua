local M = {}


function M.is_directory_empty(path)
	local handle = vim.uv.fs_scandir(path)
	if not handle then
		return true
	end

	local name = vim.uv.fs_scandir_next(handle)
	return name == nil
end

function M.is_mount_active(mount_path, mount_dir)
	local stat = vim.uv.fs_stat(mount_path)
	if not stat or stat.type ~= "directory" then
		return false
	end

	-- Use simpler approach with vim.fn.system for reliability
	local result = vim.fn.system("mount")
	if vim.v.shell_error ~= 0 then
		-- Fall back to directory check
		return not M.is_directory_empty(mount_path)
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
	return not M.is_directory_empty(mount_path)
end

function M.list_active_mounts(mount_dir)
	local mounts = {}

	local result = vim.fn.system("mount")
	if vim.v.shell_error ~= 0 then
		-- Fall back to directory scanning
		local files = vim.fn.glob(mount_dir .. "/*", false, true)
		for _, file in ipairs(files) do
			if vim.fn.isdirectory(file) == 1 and not M.is_directory_empty(file) then
				local alias = vim.fn.fnamemodify(file, ":t")
				table.insert(mounts, { alias = alias, path = file })
			end
		end
		return mounts
	end

	-- Look for sshfs mounts in the specified mount directory
	local mount_dir_escaped = mount_dir:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
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

function M.ensure_mount_directory(mount_dir)
	local stat = vim.uv.fs_stat(mount_dir)
	if stat and stat.type == "directory" then
		return true
	end

	local success = vim.fn.mkdir(mount_dir, "p")
	return success == 1
end

function M.unmount_sshfs(mount_path)
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

function M.cleanup_mount_directory(mount_dir)
	local stat = vim.uv.fs_stat(mount_dir)
	if stat and stat.type == "directory" and M.is_directory_empty(mount_dir) then
		vim.fn.delete(mount_dir, "d")
		return true
	end
	return false
end

return M

