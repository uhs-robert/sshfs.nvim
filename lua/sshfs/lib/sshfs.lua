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
--- @param host table Host object with name and user fields
--- @return boolean True if password auth should be tried
--- @return string Formatted error message describing the error
local function should_retry_with_password(error_output, host)
	if error_output:match("No such file or directory") then
		return false, "Remote path does not exist: " .. (error_output or "Unknown Error")
	end

	return true,
		string.format(
			"Authentication Error for %s@%s: %s",
			host.user or "user",
			host.name,
			error_output or "Unknown Error"
		)
end

--- Try SSH key-based authentication for mounting (async)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(success: boolean, result: string)
function Sshfs.try_key_authentication(host, mount_point, remote_path_suffix, callback)
	remote_path_suffix = remote_path_suffix or (host.path or "")
	local options = get_sshfs_options("key")

	-- Use host.name (the alias) to let SSH config resolution work properly
	local remote_path = host.name
	if host.user then
		remote_path = host.user .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. remote_path_suffix

	local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }

	if host.port then
		table.insert(cmd, "-p")
		table.insert(cmd, host.port)
	end

	-- Async execution via vim.system
	vim.system(cmd, { text = true }, function(obj)
		local result = obj.stderr or obj.stdout or ""
		-- Schedule to avoid fast event context restrictions
		vim.schedule(function()
			callback(obj.code == 0, result)
		end)
	end)
end

--- Try password-based authentication for mounting with retry attempts (async)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param max_attempts number|nil Maximum password attempts (default: 3)
--- @param callback function Callback function(success: boolean, result: string)
function Sshfs.try_password_authentication(host, mount_point, remote_path_suffix, max_attempts, callback)
	remote_path_suffix = remote_path_suffix or (host.path or "")
	max_attempts = max_attempts or 3
	local options = get_sshfs_options("password")

	-- Use host.name (the alias) to let SSH config resolution work properly
	local remote_path = host.name
	if host.user then
		remote_path = host.user .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. remote_path_suffix

	local function try_attempt(attempt)
		if attempt > max_attempts then
			callback(false, "Authentication failed after " .. max_attempts .. " attempts")
			return
		end

		local password =
			vim.fn.inputsecret(string.format("Password for %s (%d/%d): ", host.name, attempt, max_attempts))

		if not password or password == "" then
			callback(false, "User cancelled")
			return
		end

		local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }

		if host.port then
			table.insert(cmd, "-p")
			table.insert(cmd, host.port)
		end

		-- Async execution via vim.system with password via stdin
		vim.system(cmd, { text = true, stdin = password }, function(obj)
			-- Schedule to avoid fast event context restrictions
			vim.schedule(function()
				if obj.code == 0 then
					callback(true, "Success")
					return
				end

				local error_output = obj.stderr or obj.stdout or ""

				local should_retry, error_message = should_retry_with_password(error_output, host)
				if not should_retry then
					callback(false, error_message)
					return
				end

				if attempt < max_attempts then
					vim.notify(
						string.format("Authentication failed for %s, try again.", remote_path),
						vim.log.levels.WARN
					)
					try_attempt(attempt + 1)
				else
					callback(false, "Authentication failed after " .. max_attempts .. " attempts")
				end
			end)
		end)
	end

	try_attempt(1)
end

--- Authenticate and mount with automatic fallback from key to password auth (async)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(success: boolean, result: string)
function Sshfs.authenticate_and_mount(host, mount_point, remote_path_suffix, callback)
	-- Notify user that connection is starting
	vim.notify("Connecting to " .. host.name .. "...", vim.log.levels.INFO)

	Sshfs.try_key_authentication(host, mount_point, remote_path_suffix, function(success, error_output)
		if success then
			callback(true, "Key authentication successful")
			return
		end

		if not error_output then
			callback(
				false,
				string.format("Unknown Error: Key authentication failed for %s@%s", host.user or "user", host.name)
			)
			return
		end

		local should_try_password, error_message = should_retry_with_password(error_output, host)
		if not should_try_password then
			callback(false, error_message)
			return
		end

		-- Fallback to password authentication
		Sshfs.try_password_authentication(host, mount_point, remote_path_suffix, nil, callback)
	end)
end

return Sshfs
