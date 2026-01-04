-- lua/sshfs/lib/ssh_config.lua
-- SSH configuration parsing using 'ssh -G' for proper config resolution
-- Handles Include, Match, ProxyJump, and all SSH config features

local SSHConfig = {}

-- Cache state for parsed ssh config files
local CACHE = {
  hosts = nil,
  last_modified = 0,
  resolved_configs = {}, -- Cache for ssh -G results
}

--- Get the most recent modification time from a list of files
---@param files table List of file paths to check
---@return number The latest modification timestamp (seconds since epoch)
local function get_last_modified(files)
  local modified_time = 0
  for _, file in ipairs(files) do
    local stat = vim.uv.fs_stat(vim.fn.expand(file))
    if stat and stat.mtime.sec > modified_time then modified_time = stat.mtime.sec end
  end
  return modified_time
end

--- Parse SSH config files to extract Host entries (aliases only)
--- This provides the list of available hosts for selection
--- @param config_files table List of SSH config file paths to parse
--- @return table List of host aliases (strings)
local function parse_host_aliases(config_files)
  local hosts = {}
  local seen = {}

  for _, path in ipairs(config_files) do
    local expanded_path = vim.fn.expand(path)
    if vim.fn.filereadable(expanded_path) == 1 then
      for line in io.lines(expanded_path) do
        -- Skip comments and empty lines
        if line:sub(1, 1) ~= "#" and line:match("%S") then
          local host_names = line:match("^%s*Host%s+(.+)$")
          if host_names then
            -- Extract all host aliases from this Host line
            for host_name in host_names:gmatch("%S+") do
              -- Skip wildcards: *, ?, and patterns containing * or ?
              if not host_name:match("[*?]") and not seen[host_name] then
                table.insert(hosts, host_name)
                seen[host_name] = true
              end
            end
          end
        end
      end
    end
  end

  return hosts
end

--- Execute 'ssh -G hostname' to get fully resolved SSH configuration
--- This handles Include, Match, ProxyJump, HostName resolution, and all SSH features
--- @param hostname string The host alias or hostname to resolve
--- @return table|nil Resolved configuration as key-value table, or nil on error
--- @return string|nil Error message if resolution failed
local function resolve_host_config(hostname)
  local cmd = { "ssh", "-G", hostname }
  local output = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    return nil, string.format("Failed to resolve SSH config for '%s': %s", hostname, output)
  end

  -- Parse the output (format: "key value" per line)
  local config = {}
  for line in output:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%S+)%s+(.+)$")
    if key and value then
      local normalized_key = key:lower()
      -- Handle multiple values (e.g., multiple IdentityFile entries)
      if config[normalized_key] then
        if type(config[normalized_key]) ~= "table" then config[normalized_key] = { config[normalized_key] } end
        table.insert(config[normalized_key], value)
      else
        config[normalized_key] = value
      end
    end
  end

  return config, nil
end

--- Get default SSH config file paths
--- @return table List of default SSH config file paths to check
function SSHConfig.get_default_files()
  return {
    vim.fn.expand("$HOME") .. "/.ssh/config",
    "/etc/ssh/ssh_config",
  }
end

--- Get all SSH host aliases from configured SSH config files
--- Returns only the host aliases (names) without resolved configuration
--- Use get_host_config() to get the full resolved configuration for a specific host
--- Automatically caches results and invalidates cache when config files are modified
--- @return table Array of host alias strings
function SSHConfig.get_hosts()
  local Config = require("sshfs.config")
  local opts = Config.get()
  local config_files = opts.connections.ssh_configs

  -- Return cached hosts if files haven't changed
  local modified_time = get_last_modified(config_files)
  local is_config_same = CACHE.hosts and CACHE.last_modified == modified_time
  if is_config_same then return CACHE.hosts end

  -- File has changes, parse config files to get host aliases
  local hosts = parse_host_aliases(config_files)
  CACHE.hosts = hosts
  CACHE.last_modified = modified_time
  CACHE.resolved_configs = {}
  return hosts
end

--- Get fully resolved SSH configuration for a specific host using 'ssh -G'
--- This provides the complete configuration that SSH will actually use.
--- @param hostname string The host alias to resolve
--- @return table|nil Host configuration with fields like: name, hostname, user, port, identityfile, proxyjump, etc.
--- @return string|nil Error message if resolution failed
function SSHConfig.get_host_config(hostname)
  if CACHE.resolved_configs[hostname] then return CACHE.resolved_configs[hostname], nil end

  -- Resolve using ssh -G
  local config, err = resolve_host_config(hostname)
  if not config then return nil, err end

  -- Build host object with commonly used fields
  -- Note: 'name' is the alias, 'hostname' is the resolved target address
  local host = {
    name = hostname,
    hostname = config.hostname or hostname,
    user = config.user,
    port = config.port,
    identityfile = config.identityfile, -- May be table if multiple
    proxyjump = config.proxyjump,
    proxycommand = config.proxycommand,
    -- Store full config for advanced use cases
    _raw_config = config,
  }

  CACHE.resolved_configs[hostname] = host

  return host, nil
end

--- Parse a host connection string into a host object
--- Used for parsing command-line arguments like: `:SSHConnect user@host:path -p 2222`
--- @param command string SSH command string (e.g., "user@host:path" or "host -p 2222")
--- @return table Host object with name, user, path, and port fields
function SSHConfig.parse_host(command)
  local host = {}

  -- Get port and remove port from command
  local port = command:match("%-p (%d+)")
  host.port = port
  command = command:gsub("%s*%-p %d+%s*", "")

  -- Parse user@hostname:path format
  local user, hostname, path = command:match("^([^@]+)@([^:]+):?(.*)$")
  if not user then
    hostname, path = command:match("^([^:]+):?(.*)$")
  end

  host.name = hostname
  host.hostname = hostname -- For CLI parsing, name and hostname are the same
  host.user = user
  host.path = path ~= "" and path or nil

  return host
end

--- Clear the hosts and resolved_configs caches to force re-parsing on next get_hosts() call
function SSHConfig.refresh()
  CACHE.hosts = nil
  CACHE.last_modified = 0
  CACHE.resolved_configs = {}
end

return SSHConfig
