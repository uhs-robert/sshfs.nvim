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

--- Build sshfs options array for mounting via established ControlMaster socket
--- @param auth_type string Authentication type (only "socket" is used in SSH-first flow)
--- @return table Array of sshfs options
local function get_sshfs_options(auth_type)
	local Config = require("sshfs.config")
	local Ssh = require("sshfs.lib.ssh")
	local opts = Config.get()
	local options = {}

	-- Add user-configured sshfs options from config (convert table to array)
	if opts.connections and opts.connections.sshfs_options then
		local sshfs_opts = build_sshfs_args(opts.connections.sshfs_options)
		vim.list_extend(options, sshfs_opts)
	end

	-- Add SSH command to reuse existing ControlMaster socket
	if auth_type == "socket" then
		local ssh_cmd = Ssh.build_command_string("socket")
		if ssh_cmd ~= "ssh" then
			table.insert(options, "ssh_command=" .. ssh_cmd)
		end
	end

	return options
end

--- Mount via established ControlMaster socket (async, private helper)
--- Assumes SSH connection is already authenticated and socket exists
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(success: boolean, result: string)
local function mount_via_socket(host, mount_point, remote_path_suffix, callback)
	remote_path_suffix = remote_path_suffix or (host.path or "")
	local options = get_sshfs_options("socket")

	-- Use host.name (the alias) to let SSH config resolution work properly
	local remote_path = host.name
	if host.user then
		remote_path = host.user .. "@" .. remote_path
	end
	remote_path = remote_path .. ":" .. remote_path_suffix

	-- Add options/port
	local cmd = { "sshfs", remote_path, mount_point, "-o", table.concat(options, ",") }
	if host.port then
		table.insert(cmd, "-p")
		table.insert(cmd, host.port)
	end

	-- Execute mount command asynchronously
	vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			if obj.code == 0 then
				callback(true, "Mount successful")
			else
				local error_msg = obj.stderr or obj.stdout or "Unknown error"
				callback(false, "Mount failed: " .. error_msg)
			end
		end)
	end)
end

--- Authenticate and mount using SSH-first (async)
--- @param host table Host object with name, user, port, and path fields
--- @param mount_point string Local mount point directory
--- @param remote_path_suffix string|nil Remote path to mount
--- @param callback function Callback function(success: boolean, result: string)
function Sshfs.authenticate_and_mount(host, mount_point, remote_path_suffix, callback)
	local Ssh = require("sshfs.lib.ssh")
	vim.notify("Connecting to " .. host.name .. "...", vim.log.levels.INFO)

	-- Try batch connection (non-interactive)
	Ssh.try_batch_connect(host.name, function(success, exit_code, error)
		if success then
			mount_via_socket(host, mount_point, remote_path_suffix, callback)
			return
		end

		-- Batch failed, try interactive terminal
		Ssh.open_auth_terminal(host.name, function(term_success, term_exit_code)
			if term_success then
				mount_via_socket(host, mount_point, remote_path_suffix, callback)
			else
				callback(
					false,
					string.format("SSH authentication failed for %s (exit code: %d)", host.name, term_exit_code)
				)
			end
		end)
	end)
end

return Sshfs
