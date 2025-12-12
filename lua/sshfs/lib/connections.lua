-- lua/sshfs/lib/connections.lua
-- Connection status queries: checks active mounted connections and gets connection info

local Connections = {}

local ACTIVE_CONNECTIONS = nil

--- Get all active connections
--- @return table Array of connections with { host = "name", mount_path = "/path" }
function Connections.get_all()
	if ACTIVE_CONNECTIONS then
		return ACTIVE_CONNECTIONS
	end

	-- Fetch and cache active mounts
	local MountPoint = require("sshfs.lib.mount_point")
	ACTIVE_CONNECTIONS = MountPoint.list_active()
	return ACTIVE_CONNECTIONS
end

--- Check if currently connected to a remote host
--- @return boolean True if any active mounts exist
function Connections.has_active()
	local connections = Connections.get_all()
	return #connections > 0
end

--- Get current connection info (first mount for backward compatibility)
--- @return table|nil Connection with host and mount_path fields, or nil if none
function Connections.get_active()
	local connections = Connections.get_all()
	if #connections > 0 then
		return connections[1]
	end

	return nil
end

--- Clear the connections cache to force re-querying on next access
function Connections.refresh()
	ACTIVE_CONNECTIONS = nil
end

--- Add a new connection to the cache
---@param host string Hostname/alias
---@param mount_path string Mount point path
---@param remote_path string|nil Remote path on the host (optional)
function Connections.add(host, mount_path, remote_path)
	if not ACTIVE_CONNECTIONS then
		ACTIVE_CONNECTIONS = {}
	end

	table.insert(ACTIVE_CONNECTIONS, {
		host = host,
		mount_path = mount_path,
		remote_path = remote_path,
	})
end

--- Remove a connection from the cache by mount_path
---@param mount_path string Mount point path to remove
function Connections.remove(mount_path)
	if not ACTIVE_CONNECTIONS then
		return
	end

	for i, conn in ipairs(ACTIVE_CONNECTIONS) do
		if conn.mount_path == mount_path then
			table.remove(ACTIVE_CONNECTIONS, i)
			break
		end
	end
end

return Connections
