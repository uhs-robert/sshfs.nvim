-- lua/sshfs/lib/mirror_state.lua
-- Persistent record of each mirror: where it came from, where it lives, and what the server looked like at last sync.
-- Kept apart from lib/mirror.lua so Connections can list mirrors without loading the sync machinery.

local MirrorState = {}

--- Directory holding one JSON state file per mirror
---@return string
function MirrorState.dir()
  return vim.fn.stdpath("state") .. "/sshfs/mirrors"
end

--- State file path for a mirror, keyed by its local root
---@param local_path string
---@return string
function MirrorState.path_for(local_path)
  return MirrorState.dir() .. "/" .. vim.fn.sha256(local_path):sub(1, 16) .. ".json"
end

--- Read one state file
---@param path string State file path
---@return table|nil state
local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()

  local ok, state = pcall(vim.json.decode, content)
  if not ok or type(state) ~= "table" or not state.local_path then return nil end
  -- An empty JSON object decodes as an empty list, which is still an empty map here
  state.manifest = type(state.manifest) == "table" and state.manifest or {}
  state.unsynced = type(state.unsynced) == "table" and state.unsynced or {}
  return state
end

--- Load the state of the mirror rooted at local_path
--- Always reads from disk because other Neovim instances update the manifest.
---@param local_path string
---@return table|nil state
function MirrorState.load(local_path)
  return read_file(MirrorState.path_for(local_path))
end

--- Write a state file, replacing any previous one atomically
--- Only for creating a state: changes to an existing one go through MirrorState.update, so that a write
--- from this instance does not undo another instance's.
---@param state table Fields: host, user, port, remote_path, local_path, manifest, unsynced, connected, git_fingerprint
---@return boolean ok
function MirrorState.save(state)
  local dir = MirrorState.dir()
  if vim.fn.isdirectory(dir) ~= 1 and not pcall(vim.fn.mkdir, dir, "p") then return false end

  local path = MirrorState.path_for(state.local_path)
  local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return false end
  -- Empty maps must stay objects, or a later decode-and-index would see a list
  local encoded = vim.deepcopy(state)
  for _, key in ipairs({ "manifest", "unsynced" }) do
    if type(encoded[key]) ~= "table" or next(encoded[key]) == nil then encoded[key] = vim.empty_dict() end
  end
  file:write(vim.json.encode(encoded))
  file:close()
  return os.rename(tmp, path) == true
end

--- Change a mirror's state as it is on disk now
--- Re-reading right before the write means each caller changes only the keys it owns, and the
--- read-modify-write never yields, so concurrent instances lose nothing short of an exact interleaving.
---@param local_path string
---@param mutate function fun(state: table) Edits the freshly read state in place
---@return table|nil state The written state, or nil when the mirror has no state
function MirrorState.update(local_path, mutate)
  local state = MirrorState.load(local_path)
  if not state then return nil end
  mutate(state)
  MirrorState.save(state)
  return state
end

--- Apply per-file manifest and unsynced changes in one write
---@param local_path string
---@param manifest table<string, string|false> rel -> new entry, or false to drop it
---@param unsynced table<string, string|false> rel -> reason it is not on the server, or false to clear it
---@return table|nil state
function MirrorState.apply(local_path, manifest, unsynced)
  return MirrorState.update(local_path, function(state)
    for rel, entry in pairs(manifest or {}) do
      state.manifest[rel] = entry or nil
    end
    for rel, reason in pairs(unsynced or {}) do
      state.unsynced[rel] = reason or nil
    end
  end)
end

--- Remove the state of the mirror rooted at local_path
---@param local_path string
function MirrorState.delete(local_path)
  os.remove(MirrorState.path_for(local_path))
end

--- Load every mirror state on disk
---@return table[] states Sorted by local_path
function MirrorState.list()
  local states = {}
  for _, path in ipairs(vim.fn.glob(MirrorState.dir() .. "/*.json", false, true)) do
    local state = read_file(path)
    if state then table.insert(states, state) end
  end
  table.sort(states, function(a, b)
    return a.local_path < b.local_path
  end)
  return states
end

return MirrorState
