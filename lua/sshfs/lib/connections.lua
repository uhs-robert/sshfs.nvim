-- lua/sshfs/lib/connections.lua
-- Connection status queries: checks active mounted connections and gets connection info

local Connections = {}

local MountPoint = require("sshfs.lib.mount_point")

--- Check if currently connected to a remote host
--- @return boolean True if any active mounts exist
function Connections.has_active()
	local mounts = MountPoint.list_active()
	return #mounts > 0
end

--- Get current connection info (first mount for backward compatibility)
--- @return table Connection info with host and mount_point fields
function Connections.get_active()
	local mounts = MountPoint.list_active()
	if #mounts > 0 then
		-- Return first active mount as the current connection
		return {
			host = { Name = mounts[1].alias },
			mount_point = mounts[1].path,
		}
	end

	return { host = nil, mount_point = nil }
end

--- Get all active connections
--- @return table Array of connection info objects with host and mount_point fields
function Connections.get_all()
	local mounts = MountPoint.list_active()

	local all_connections = {}
	for _, mount in ipairs(mounts) do
		table.insert(all_connections, {
			host = { Name = mount.alias },
			mount_point = mount.path,
		})
	end

	return all_connections
end

return Connections
