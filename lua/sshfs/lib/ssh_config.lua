-- lua/sshfs/lib/ssh_config.lua
-- SSH configuration parsing from system config files and host discovery

local SSHConfig = {}

-- Cache state for parsed ssh config files
local CACHE = {
	hosts = nil,
	last_modified = 0,
}

--- Get the most recent modification time from a list of files
---@param files table List of file paths to check
---@return number The latest modification timestamp (seconds since epoch)
local function get_last_modifed(files)
	local modifed_time = 0
	for _, file in ipairs(files) do
		local stat = vim.uv.fs_stat(vim.fn.expand(file))
		if stat and stat.mtime.sec > modifed_time then
			modifed_time = stat.mtime.sec
		end
	end
	return modifed_time
end

--- Parse SSH config files and extract host definitions
---@param config_files table List of SSH config file paths to parse
---@return table Parsed hosts indexed by hostname, with their configuration
local function parse_ssh_configs(config_files)
	local hosts = {}
	local current_hosts = {}

	for _, path in ipairs(config_files) do
		local expanded_path = vim.fn.expand(path)
		if vim.fn.filereadable(expanded_path) == 1 then
			for line in io.lines(expanded_path) do
				if line:sub(1, 1) ~= "#" and line:match("%S") then
					local host_names = line:match("^%s*Host%s+(.+)$")
					if host_names then
						current_hosts = {}
						for host_name in host_names:gmatch("%S+") do
							if host_name ~= "*" then
								table.insert(current_hosts, host_name)
								hosts[host_name] = { ["Config"] = path, ["Name"] = host_name }
							end
						end
					elseif line:match("^%s*Match%s+") then
						current_hosts = {}
					else
						if #current_hosts > 0 then
							local key, value = line:match("^%s*(%S+)%s+(.+)$")
							if key and value then
								for _, host in ipairs(current_hosts) do
									hosts[host][key] = value
								end
							end
						end
					end
				end
			end
		end
	end

	return hosts
end

--- Get default SSH config file paths
---@return table List of default SSH config file paths to check
function SSHConfig.get_default_files()
	return {
		vim.fn.expand("$HOME") .. "/.ssh/config",
		"/etc/ssh/ssh_config",
	}
end

--- Get all SSH hosts from configured SSH config files
--- Automatically caches results and invalidates cache when config files are modified
---@return table Hosts indexed by hostname with their configuration
function SSHConfig.get_hosts()
	local Config = require("sshfs.config")
	local opts = Config.get()
	local config_files = opts.connections.ssh_configs

	-- Return cached hosts if files haven't changed
	local modifed_time = get_last_modifed(config_files)
	if CACHE.hosts and CACHE.last_modified == modifed_time then
		return CACHE.hosts
	end

	-- Otherwise cache was cleared or one of the files were modifed; parse and cache
	local hosts = parse_ssh_configs(config_files)
	CACHE.hosts = hosts
	CACHE.last_modified = modifed_time

	return hosts
end

--- Parse a host connection string into a host object
---@param command string SSH command string (e.g., "user@host:path" or "host -p 2222")
---@return table Host object with Name, User, Path, and Port fields
function SSHConfig.parse_host(command)
	local host = {}

	local port = command:match("%-p (%d+)")
	host["Port"] = port

	command = command:gsub("%s*%-p %d+%s*", "")

	local user, hostname, path = command:match("^([^@]+)@([^:]+):?(.*)$")
	if not user then
		hostname, path = command:match("^([^:]+):?(.*)$")
	end

	host["Name"] = hostname
	host["User"] = user
	host["Path"] = path

	return host
end

--- Clear the hosts cache to force re-parsing on next get_hosts() call
function SSHConfig.refresh()
	CACHE.hosts = nil
	CACHE.last_modified = 0
end

return SSHConfig
