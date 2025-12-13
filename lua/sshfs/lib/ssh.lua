-- lua/sshfs/lib/ssh.lua
-- SSH operations: terminal sessions, command execution, and connection utilities

local Ssh = {}

--- Build SSH command with optional remote path and ControlMaster options
---@param host string SSH host name
---@param remote_path string|nil Optional remote path to cd into
---@return table SSH command as array (safer than string to avoid shell injection)
function Ssh.build_command(host, remote_path)
	local Config = require("sshfs.config")
	local cmd = { "ssh" }

	-- Add ControlMaster options if enabled (to reuse existing connection)
	local control_opts = Config.get_control_master_options()
	if control_opts then
		for _, opt in ipairs(control_opts) do
			table.insert(cmd, "-o")
			table.insert(cmd, opt)
		end
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
