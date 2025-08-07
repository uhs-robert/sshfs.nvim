local M = {}

local function get_sshfs_options(auth_type, ssh_options, user_sshfs_args)
	ssh_options = ssh_options or {}

	local options = {}

	-- Add user-configured sshfs args first (so they take precedence)
	if user_sshfs_args then
		for _, arg in ipairs(user_sshfs_args) do
			if arg:match("^%-o%s+(.+)") then
				local opt = arg:match("^%-o%s+(.+)")
				table.insert(options, opt)
			end
		end
	end

	-- Add optional dir_cache options if configured
	if ssh_options.dir_cache then
		vim.list_extend(options, {
			"dir_cache=yes",
			string.format("dcache_timeout=%d", ssh_options.dcache_timeout or 300),
			string.format("dcache_max_size=%d", ssh_options.dcache_max_size or 10000),
		})
	end

	-- Add auth-specific options (essential for authentication to work)
	if auth_type == "key" then
		table.insert(options, "BatchMode=yes")
	elseif auth_type == "password" then
		table.insert(options, "password_stdin")
	end

	return options
end

function M.try_key_authentication(host, mount_point, ssh_options, mount_to_root, user_sshfs_args)
	mount_to_root = mount_to_root or false
	local options = get_sshfs_options("key", ssh_options, user_sshfs_args)

	local remote_path = host.Name
	if host.User then
		remote_path = host.User .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. (mount_to_root and "/" or (host.Path or ""))

	local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }

	if host.Port then
		table.insert(cmd, "-p")
		table.insert(cmd, host.Port)
	end

	local result = vim.fn.system(table.concat(cmd, " "))
	return vim.v.shell_error == 0, result
end

function M.try_password_authentication(host, mount_point, ssh_options, mount_to_root, max_attempts, user_sshfs_args)
	mount_to_root = mount_to_root or false
	max_attempts = max_attempts or 3
	local options = get_sshfs_options("password", ssh_options, user_sshfs_args)

	local remote_path = host.Name
	if host.User then
		remote_path = host.User .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. (mount_to_root and "/" or (host.Path or ""))

	for attempt = 1, max_attempts do
		local password =
			vim.fn.inputsecret(string.format("Password for %s (%d/%d): ", host.Name, attempt, max_attempts))

		if not password or password == "" then
			return false, "User cancelled"
		end

		local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }

		if host.Port then
			table.insert(cmd, "-p")
			table.insert(cmd, host.Port)
		end

		-- Use more secure password passing to avoid shell injection
		local result = vim.fn.system(table.concat(cmd, " "), password)

		if vim.v.shell_error == 0 then
			return true, "Success"
		end

		if attempt < max_attempts then
			vim.notify("Authentication failed, try again.", vim.log.levels.WARN)
		end
	end

	return false, "Authentication failed after " .. max_attempts .. " attempts"
end

function M.authenticate_and_mount(host, mount_point, ssh_options, mount_to_root, user_sshfs_args)
	local success, result = M.try_key_authentication(host, mount_point, ssh_options, mount_to_root, user_sshfs_args)

	if success then
		return true, "Key authentication successful"
	end

	vim.notify("Key authentication failed, trying password authentication...", vim.log.levels.INFO)
	return M.try_password_authentication(host, mount_point, ssh_options, mount_to_root, nil, user_sshfs_args)
end

function M.prompt_mount_location()
	local choice = vim.fn.confirm("Mount location:", "&Home directory (~)\n&Root directory (/)", 1)
	return choice == 2
end

return M
