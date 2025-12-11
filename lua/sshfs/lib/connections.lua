-- lua/sshfs/lib/connections.lua
-- Connection status queries: check active connections and get connection info

local Connections = {}

local MountPoint = require("sshfs.lib.mount_point")

-- Check if currently connected to a remote host
function Connections.has_active(base_dir)
	if not base_dir then
		return false
	end

	local mounts = MountPoint.list_active(base_dir)
	return #mounts > 0
end

-- Get current connection info (first mount for backward compatibility)
function Connections.get_active(base_dir)
	if not base_dir then
		return { host = nil, mount_point = nil }
	end

	local mounts = MountPoint.list_active(base_dir)
	if #mounts > 0 then
		-- Return first active mount as the current connection
		return {
			host = { Name = mounts[1].alias },
			mount_point = mounts[1].path,
		}
	end

	return { host = nil, mount_point = nil }
end

-- Get all active connections
function Connections.get_all(base_dir)
	if not base_dir then
		return {}
	end

	local mounts = MountPoint.list_active(base_dir)

	local connections = {}
	for _, mount in ipairs(mounts) do
		table.insert(connections, {
			host = { Name = mount.alias },
			mount_point = mount.path,
		})
	end

	return connections
end

return Connections
