-- lua/sshfs/lib/lockfile.lua
-- Lockfile management for tracking which Neovim instances are using mounts

local Lockfile = {}

--- Get the lockfile directory path
---@return string
local function get_lock_dir()
  return vim.fn.stdpath("cache") .. "/sshfs"
end

--- Get the lockfile path for a mount
---@param mount_path string The mount path
---@return string
local function get_lock_path(mount_path)
  -- Use a hash of the mount path to create a safe filename
  local hash = vim.fn.sha256(mount_path):sub(1, 16)
  return get_lock_dir() .. "/" .. hash .. ".lock"
end

--- Ensure the lock directory exists
---@return boolean
local function ensure_lock_dir()
  local lock_dir = get_lock_dir()
  if vim.fn.isdirectory(lock_dir) == 1 then return true end
  return vim.fn.mkdir(lock_dir, "p") == 1
end

--- Read PIDs from lockfile
---@param lock_path string
---@return table Array of PID strings
local function read_pids(lock_path)
  local pids = {}
  local f = io.open(lock_path, "r")
  if not f then return pids end
  for line in f:lines() do
    local pid = line:match("^%s*(%d+)%s*$")
    if pid then table.insert(pids, pid) end
  end
  f:close()
  return pids
end

--- Write PIDs to lockfile
---@param lock_path string
---@param pids table Array of PID strings
local function write_pids(lock_path, pids)
  local f = io.open(lock_path, "w")
  if not f then return false end
  for _, pid in ipairs(pids) do
    f:write(pid .. "\n")
  end
  f:close()
  return true
end

--- Check if a PID is still running
---@param pid string
---@return boolean
local function is_pid_alive(pid)
  local ok = pcall(vim.uv.kill, tonumber(pid), 0) -- checks if process existing without actually sending a signal
  return ok
end

--- Register current Neovim instance as using a mount
---@param mount_path string The mount path
---@return boolean Success
function Lockfile.register(mount_path)
  if not ensure_lock_dir() then return false end

  local lock_path = get_lock_path(mount_path)
  local pids = read_pids(lock_path)
  local current_pid = tostring(vim.fn.getpid())

  -- Check if already registered
  for _, pid in ipairs(pids) do
    if pid == current_pid then return true end
  end

  -- Add current PID
  table.insert(pids, current_pid)
  return write_pids(lock_path, pids)
end

--- Unregister current Neovim instance from a mount
---@param mount_path string The mount path
---@return boolean Success
function Lockfile.unregister(mount_path)
  local lock_path = get_lock_path(mount_path)
  local pids = read_pids(lock_path)
  local current_pid = tostring(vim.fn.getpid())

  -- Filter out current PID
  local new_pids = {}
  for _, pid in ipairs(pids) do
    if pid ~= current_pid then table.insert(new_pids, pid) end
  end

  -- If no PIDs left, remove the file
  if #new_pids == 0 then
    os.remove(lock_path)
    return true
  end

  return write_pids(lock_path, new_pids)
end

--- Check if other Neovim instances are using the mount
---@param mount_path string The mount path
---@return boolean True if other instances are using the mount
function Lockfile.is_in_use_by_others(mount_path)
  local lock_path = get_lock_path(mount_path)
  local pids = read_pids(lock_path)
  local current_pid = tostring(vim.fn.getpid())

  -- Clean up stale PIDs and check for others
  local valid_pids = {}
  local has_others = false

  for _, pid in ipairs(pids) do
    if is_pid_alive(pid) then
      table.insert(valid_pids, pid)
      if pid ~= current_pid then has_others = true end
    end
  end

  -- Write back cleaned up PIDs if any were stale
  if #valid_pids ~= #pids then
    if #valid_pids == 0 then
      os.remove(lock_path)
    else
      write_pids(lock_path, valid_pids)
    end
  end

  return has_others
end

--- Unregister current instance from all mounts
---@return number Count of mounts unregistered from
function Lockfile.unregister_all()
  local lock_dir = get_lock_dir()
  if vim.fn.isdirectory(lock_dir) ~= 1 then return 0 end

  local count = 0
  local files = vim.fn.glob(lock_dir .. "/*.lock", false, true)
  local current_pid = tostring(vim.fn.getpid())

  for _, lock_path in ipairs(files) do
    local pids = read_pids(lock_path)
    local new_pids = {}
    local had_current = false

    for _, pid in ipairs(pids) do
      if pid == current_pid then
        had_current = true
      else
        table.insert(new_pids, pid)
      end
    end

    if had_current then
      count = count + 1
      if #new_pids == 0 then
        os.remove(lock_path)
      else
        write_pids(lock_path, new_pids)
      end
    end
  end

  return count
end

return Lockfile
