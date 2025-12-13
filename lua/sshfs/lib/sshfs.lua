-- lua/sshfs/lib/sshfs.lua
-- SSHFS wrapper with authentication workflows

local Sshfs = {}

--- Convert sshfs_options table to array format for sshfs -o
--- @param options_table table Table of options (e.g., {reconnect = true, ConnectTimeout = 5})
--- @return table Array of option strings (e.g., {"reconnect", "ConnectTimeout=5"})
local function build_sshfs_args(options_table)
	local result = {}

	for key, value in pairs(options_table) do
		if value == true then
			-- Boolean true: just add the key
			table.insert(result, key)
		elseif value ~= false and value ~= nil then
			-- String or number: add as key=value
			table.insert(result, string.format("%s=%s", key, tostring(value)))
		end
		-- false or nil: skip this option
	end

	return result
end

--- Build sshfs options array based on authentication type
--- @param auth_type string Authentication type ("key" or "password")
--- @return table Array of sshfs options
local function get_sshfs_options(auth_type)
	local Config = require("sshfs.config")
	local opts = Config.get()
	local options = {}

	-- Add user-configured sshfs options from config (convert table to array)
	if opts.connections and opts.connections.sshfs_options then
		local sshfs_opts = build_sshfs_args(opts.connections.sshfs_options)
		vim.list_extend(options, sshfs_opts)
	end

	-- Add ControlMaster options if enabled (for connection reuse)
	local control_opts = Config.get_control_master_options()
	if control_opts then
		vim.list_extend(options, control_opts)
	end

	-- Add auth-specific options (essential for authentication to work)
	if auth_type == "key" then
		table.insert(options, "BatchMode=yes")
	elseif auth_type == "password" then
		table.insert(options, "password_stdin")
	end

	return options
end

--- Determine whether password authentication should be attempted based on error type
--- @param error_output string Error output from the sshfs command
--- @param host table Host object with Name and User fields
--- @return boolean True if password auth should be tried
--- @return string Formatted error message describing the error
local function should_retry_with_password(error_output, host)
	if error_output:match("No such file or directory") then
		return false, "Remote path does not exist: " .. (error_output or "Unknown Error")
	end

	return true,
		string.format("Authentication Error for %s@%s: %s", host.User, host.Name, error_output or "Unknown Error")
end

--- Try SSH key-based authentication for mounting
--- @param host table Host object with Name, User, Port, and Path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @return boolean True if authentication succeeded
--- @return string Result message or error output
function Sshfs.try_key_authentication(host, mount_point, remote_path_suffix)
	remote_path_suffix = remote_path_suffix or (host.Path or "")
	local options = get_sshfs_options("key")

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

--- Try password-based authentication for mounting with retry attempts
--- @param host table Host object with Name, User, Port, and Path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param max_attempts number|nil Maximum password attempts (default: 3)
--- @return boolean True if authentication succeeded
--- @return string Result message or error output
function Sshfs.try_password_authentication(host, mount_point, remote_path_suffix, max_attempts)
	remote_path_suffix = remote_path_suffix or (host.Path or "")
	max_attempts = max_attempts or 3
	local options = get_sshfs_options("password")

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

--- Authenticate and mount with automatic fallback from key to password auth
--- @param host table Host object with Name, User, Port, and Path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @return boolean True if authentication and mount succeeded
--- @return string Result message or error output
function Sshfs.authenticate_and_mount(host, mount_point, remote_path_suffix)
	local success, error_output = Sshfs.try_key_authentication(host, mount_point, remote_path_suffix)
	if success then
		return true, "Key authentication successful"
	elseif not error_output then
		return false, string.format("Unknown Error: Key authentication failed for %s@%s", host.User, host.Name)
	end

	local should_try_password, error_message = should_retry_with_password(error_output, host)
	if not should_try_password then
		return false, error_message
	end

	return Sshfs.try_password_authentication(host, mount_point, remote_path_suffix)
end

return Sshfs
