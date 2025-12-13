-- lua/sshfs/lib/ssh.lua
-- SSH operations: terminal sessions, command execution, and connection utilities

local Ssh = {}

--- Build SSH options array (ControlMaster + optional auth options)
--- @param auth_type string|nil Authentication type:
---   - "batch": ControlMaster=yes + BatchMode=yes (socket creation, non-interactive)
---   - "socket": ControlPath only (reuse existing socket)
---   - nil: ControlMaster=auto (for interactive terminals)
--- @return table Array of SSH option strings (e.g., {"ControlMaster=auto", "ControlPath=...", "BatchMode=yes"})
local function get_ssh_options(auth_type)
	local Config = require("sshfs.config")
	local options = {}

	-- Add ControlMaster options
	local control_opts = Config.get_control_master_options()
	if auth_type == "batch" then
		-- For batch connection: use ControlMaster=yes to force socket creation
		local modified_opts = {}
		for _, opt in ipairs(control_opts) do
			if opt:match("^ControlMaster=") then
				table.insert(modified_opts, "ControlMaster=yes")
			else
				table.insert(modified_opts, opt)
			end
		end
		vim.list_extend(options, modified_opts)
		table.insert(options, "BatchMode=yes")
	elseif auth_type == "socket" then
		-- For socket reuse: only add ControlPath (no ControlMaster/ControlPersist)
		for _, opt in ipairs(control_opts) do
			if opt:match("^ControlPath=") then
				table.insert(options, opt)
				break
			end
		end
	else
		-- Default (nil): use ControlMaster=auto for interactive terminals
		vim.list_extend(options, control_opts)
	end

	return options
end

--- Build SSH command string with options for use with sshfs ssh_command option
--- @param auth_type string|nil Authentication type ("batch", "socket", or nil)
--- @return string SSH command string (e.g., "ssh -o ControlMaster=auto -o ControlPath=... -o BatchMode=yes")
function Ssh.build_command_string(auth_type)
	local options = get_ssh_options(auth_type)
	local cmd_parts = { "ssh" }

	for _, opt in ipairs(options) do
		table.insert(cmd_parts, "-o")
		table.insert(cmd_parts, opt)
	end

	return table.concat(cmd_parts, " ")
end

--- Build SSH command with optional remote path and ControlMaster options
---@param host string SSH host name
---@param remote_path string|nil Optional remote path to cd into
---@return table SSH command as array (safer than string to avoid shell injection)
function Ssh.build_command(host, remote_path)
	local cmd = { "ssh" }

	-- Add SSH options (ControlMaster, etc.)
	local options = get_ssh_options(nil) -- No auth type for interactive terminal
	for _, opt in ipairs(options) do
		table.insert(cmd, "-o")
		table.insert(cmd, opt)
	end

	table.insert(cmd, host)

	-- If remote_path specified, cd into it and start a login shell
	if remote_path and remote_path ~= "" then
		table.insert(cmd, "-t")
		-- Escape remote_path for remote shell by wrapping in single quotes and escaping any single quotes as '\''
		local escaped_path = "'" .. remote_path:gsub("'", "'\\''") .. "'"
		table.insert(cmd, "cd " .. escaped_path .. " && exec $SHELL -l")
	end

	return cmd
end

--- Open SSH terminal session
---@param host string SSH host name
---@param remote_path string|nil Optional remote path to cd into
function Ssh.open_terminal(host, remote_path)
	local ssh_cmd = Ssh.build_command(host, remote_path)
	vim.cmd("enew")
	vim.fn.jobstart(ssh_cmd, { term = true })
	vim.cmd("startinsert")
end

--- Close ControlMaster connection and clean up socket
--- Sends "exit" command to ControlMaster to gracefully close connection and remove socket
---@param host string SSH host name
---@return boolean True if cleanup command was sent successfully
function Ssh.cleanup_control_master(host)
	local Config = require("sshfs.config")
	local control_opts = Config.get_control_master_options()

	-- Build ssh -O exit command for ControlPath
	local cmd = { "ssh" }
	for _, opt in ipairs(control_opts) do
		table.insert(cmd, "-o")
		table.insert(cmd, opt)
	end
	table.insert(cmd, "-O")
	table.insert(cmd, "exit")
	table.insert(cmd, host)

	-- Execute synchronously (must complete before nvim exit)
	vim.fn.system(cmd)
	-- Ignore exit code - socket may already be closed/expired
	return true
end

--- Try batch SSH connection to establish ControlMaster socket (async, non-interactive)
--- Attempts to connect using existing keys without prompting for passwords or passphrases
---@param host string SSH host name
---@param callback function Callback(success: boolean, exit_code: number, error: string|nil)
function Ssh.try_batch_connect(host, callback)
	local cmd = { "ssh" }

	-- Add SSH options for batch connection (ControlMaster=yes + BatchMode=yes)
	local options = get_ssh_options("batch")
	for _, opt in ipairs(options) do
		table.insert(cmd, "-o")
		table.insert(cmd, opt)
	end

	-- Add host and exit command (just test connection, don't start shell)
	table.insert(cmd, host)
	table.insert(cmd, "exit")

	-- Execute asynchronously
	vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			local success = obj.code == 0
			local error_msg = success and nil or (obj.stderr or obj.stdout or "Unknown error")
			callback(success, obj.code, error_msg)
		end)
	end)
end

--- Open interactive SSH terminal for authentication in floating window (async)
--- Allows user to complete any SSH authentication method (password, 2FA, host verification, etc.)
--- Creates floating terminal window and tracks exit code for success/failure
---@param host string SSH host name
---@param callback function Callback(success: boolean, exit_code: number)
function Ssh.open_auth_terminal(host, callback)
	-- Build SSH command for authentication (ControlMaster=yes to create socket)
	local cmd = { "ssh" }
	local options = get_ssh_options(nil) -- Get ControlMaster options
	local modified_opts = {}
	for _, opt in ipairs(options) do
		if opt:match("^ControlMaster=") then
			table.insert(modified_opts, "ControlMaster=yes")
		else
			table.insert(modified_opts, opt)
		end
	end

	-- Finalize command options, end with exit to close shell after authentication flow
	for _, opt in ipairs(modified_opts) do
		table.insert(cmd, "-o")
		table.insert(cmd, opt)
	end
	table.insert(cmd, host)
	table.insert(cmd, "exit")

	-- Open authentication terminal window
	local Terminal = require("sshfs.ui.terminal")
	Terminal.open_auth_floating(cmd, host, callback)
end

return Ssh
