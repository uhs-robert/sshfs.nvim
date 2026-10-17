-- lua/sshfs/lib/connections.lua
-- Every live connection, whatever its kind: sshfs mounts read from the system mount table, mirrors from their state files.
-- Both carry `mount_path` as the local root so callers can map remote paths onto it without caring which kind it is.

local Connections = {}

--- Convert a mirror state into the connection shape shared with mounts
---@param state table Mirror state
---@return table connection
local function from_mirror_state(state)
  return {
    kind = "mirror",
    host = state.host,
    user = state.user,
    port = state.port,
    mount_path = state.local_path,
    local_path = state.local_path,
    remote_path = state.remote_path,
    remote_metadata_available = true,
  }
end

--- Whether a mirror is connected: marked so, and held by a running Neovim
--- The flag alone outlives a crash or a killed instance; the owner's PID does not.
---@param state table Mirror state
---@return boolean
function Connections.is_mirror_live(state)
  return state.connected ~= false and require("sshfs.lib.lockfile").has_live_owner(state.local_path)
end

--- List all active connections: mounts first, then mirrors
---@return table[] connections Each tagged kind = "mount" | "mirror"
function Connections.list_active()
  local MountPoint = require("sshfs.lib.mount_point")
  local MirrorState = require("sshfs.lib.mirror_state")
  local connections = {}

  for _, mount in ipairs(MountPoint.list_active()) do
    mount.kind = "mount"
    table.insert(connections, mount)
  end

  for _, state in ipairs(MirrorState.list()) do
    if Connections.is_mirror_live(state) then table.insert(connections, from_mirror_state(state)) end
  end

  return connections
end

--- Get the first active connection
---@return table|nil connection
function Connections.get_active()
  return Connections.list_active()[1]
end

--- Check whether any connection is active
---@return boolean
function Connections.has_active()
  return Connections.get_active() ~= nil
end

--- Display label for a connection; mirrors are marked so they are told apart from mounts of the same path
---@param connection table
---@return string
function Connections.format_label(connection)
  local label = require("sshfs.lib.mount_point").format_label(connection)
  if connection.kind == "mirror" then label = label .. " [mirror]" end
  return label
end

return Connections
