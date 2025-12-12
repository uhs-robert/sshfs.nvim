-- lua/sshfs/lib/ssh.lua
-- SSH operations: terminal sessions, command execution, and connection utilities

local Ssh = {}

--- Build SSH command with optional remote path
---@param host string SSH host name
---@param remote_path string|nil Optional remote path to cd into
---@return string SSH command string
function Ssh.build_command(host, remote_path)
	local ssh_cmd = "ssh " .. vim.fn.shellescape(host)

	-- If remote_path specified, cd into it and start a login shell
	if remote_path and remote_path ~= "" then
		ssh_cmd = ssh_cmd .. " -t " .. vim.fn.shellescape("cd " .. remote_path .. " && exec $SHELL -l")
	end

	return ssh_cmd
end

--- Open SSH terminal session
---@param host string SSH host name
---@param remote_path string|nil Optional remote path to cd into
function Ssh.open_terminal(host, remote_path)
	local ssh_cmd = Ssh.build_command(host, remote_path)
	vim.cmd("terminal " .. ssh_cmd)
	vim.cmd("startinsert")
end

return Ssh
