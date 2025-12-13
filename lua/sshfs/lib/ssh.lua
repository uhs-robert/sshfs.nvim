-- lua/sshfs/lib/ssh.lua
-- SSH operations: terminal sessions, command execution, and connection utilities

local Ssh = {}

--- Build SSH options array (ControlMaster + optional auth options)
--- @param auth_type string|nil Authentication type ("key" for BatchMode, nil for no auth options)
--- @return table Array of SSH option strings (e.g., {"ControlMaster=auto", "ControlPath=...", "BatchMode=yes"})
local function get_ssh_options(auth_type)
	local Config = require("sshfs.config")
	local options = {}

	-- Add ControlMaster options if enabled
	local control_opts = Config.get_control_master_options()
	if control_opts then
		vim.list_extend(options, control_opts)
	end

	-- Add auth-specific SSH options
	if auth_type == "key" then
		table.insert(options, "BatchMode=yes")
	end

	return options
end

--- Build SSH command string with options for use with sshfs ssh_command option
--- @param auth_type string|nil Authentication type ("key" or nil for no auth options)
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

return Ssh
