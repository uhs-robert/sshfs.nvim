-- lua/sshfs/core/auth.lua
-- SSH authentication flows (key-based and password-based) with fallback mechanisms

local Sshfs = {} -- TODO: Rename file and move to lib

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

-- Determines whether password authentication should be attempted based on the error type
-- @param error_output string: The error output from the sshfs command
-- @param host table: Host object with Name/User field (e.g., {Name = "my-server", User = "my-username"})
-- @return boolean: true if password auth should be tried else false
-- @return string: Formatted error message describing the error
local function should_retry_with_password(error_output, host)
	if error_output:match("No such file or directory") then
		return false, "Remote path does not exist: " .. (error_output or "Unknown Error")
	end

	return true,
		string.format("Authentication Error for %s@%s: %s", host.User, host.Name, error_output or "Unknown Error")
end

function Sshfs.try_key_authentication(host, mount_point, ssh_options, remote_path_suffix, user_sshfs_args)
	remote_path_suffix = remote_path_suffix or (host.Path or "")
	local options = get_sshfs_options("key", ssh_options, user_sshfs_args)

	local remote_path = host.Name
	if host.User then
		remote_path = host.User .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. remote_path_suffix

	local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }

	if host.Port then
		table.insert(cmd, "-p")
		table.insert(cmd, host.Port)
	end

	local result = vim.fn.system(table.concat(cmd, " "))
	return vim.v.shell_error == 0, result
end

function Sshfs.try_password_authentication(
	host,
	mount_point,
	ssh_options,
	remote_path_suffix,
	max_attempts,
	user_sshfs_args
)
	remote_path_suffix = remote_path_suffix or (host.Path or "")
	max_attempts = max_attempts or 3
	local options = get_sshfs_options("password", ssh_options, user_sshfs_args)

	local remote_path = host.Name
	if host.User then
		remote_path = host.User .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. remote_path_suffix

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
		local error_output = vim.fn.system(table.concat(cmd, " "), password)

		if vim.v.shell_error == 0 then
			return true, "Success"
		end

		local should_retry, error_message = should_retry_with_password(error_output, host)
		if not should_retry then
			return false, error_message
		end

		if attempt < max_attempts then
			vim.notify(string.format("Authentication failed for %s, try again.", remote_path), vim.log.levels.WARN)
		end
	end

	return false, "Authentication failed after " .. max_attempts .. " attempts"
end

function Sshfs.authenticate_and_mount(host, mount_point, ssh_options, remote_path_suffix, user_sshfs_args)
	local success, error_output =
		Sshfs.try_key_authentication(host, mount_point, ssh_options, remote_path_suffix, user_sshfs_args)
	if success then
		return true, "Key authentication successful"
	elseif not error_output then
		return false, string.format("Unknown Error: Key authentication failed for %s@%s", host.User, host.Name)
	end

	local should_try_password, error_message = should_retry_with_password(error_output, host)
	if not should_try_password then
		return false, error_message
	end

	return Sshfs.try_password_authentication(host, mount_point, ssh_options, remote_path_suffix, nil, user_sshfs_args)
end

return Sshfs
