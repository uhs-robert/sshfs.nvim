-- lua/sshfs/lib/mount_point.lua
-- Mount point management, detection, creation, unmounting, cleanup, and command execution

local MountPoint = {}
local Directory = require("sshfs.lib.directory")
local Config = require("sshfs.config")

--- Get all active SSHFS mount paths and remote info from the system
--- @return table Array of mount info tables with {mount_path, remote_spec} where remote_spec is "user@host:/path" or "host:/path"
local function get_system_mounts()
  local mounts = {}

  -- Try findmnt first (Linux only) if available - it can show both SOURCE and TARGET
  if vim.fn.executable("findmnt") == 1 then
    local findmnt_result = vim.fn.system({ "findmnt", "-t", "fuse.sshfs", "-n", "-o", "SOURCE,TARGET" })
    if vim.v.shell_error == 0 then
      for line in findmnt_result:gmatch("[^\r\n]+") do
        -- findmnt output: "user@host:/remote/path /local/mount"
        local remote_spec, mount_path = line:match("^(%S+)%s+(.+)$")
        if remote_spec and mount_path then
          table.insert(mounts, { mount_path = mount_path, remote_spec = remote_spec })
        end
      end
      return mounts
    end
  end

  -- Fallback to mount command for broader compatibility
  local result = vim.fn.system("mount")
  if vim.v.shell_error ~= 0 then return mounts end

  -- Cross-platform patterns for detecting SSHFS mounts with remote spec
  -- Format: "user@host:/remote/path on /mount/path type fuse.sshfs" or "... (macfuse"
  local pattern_templates = {
    "^(%S+)%s+on%s+([^%s]+)%s+type%s+fuse%.sshfs", -- Linux: "user@host:/path on /mount/path type fuse.sshfs"
    "^(%S+)%s+on%s+([^%s]+)%s+%(macfuse", -- macOS/macfuse: "user@host:/path on /mount/path (macfuse"
    "^(%S+)%s+on%s+([^%s]+)%s+%(osxfuse", -- macOS/osxfuse older: "user@host:/path on /mount/path (osxfuse"
    "^(%S+)%s+on%s+([^%s]+)%s+%(fuse", -- Generic FUSE: "user@host:/path on /mount/path (fuse"
  }

  -- Only process lines that contain 'sshfs' to avoid false positives
  for line in result:gmatch("[^\r\n]+") do
    if line:match("sshfs") or line:match("macfuse") then
      for _, pattern in ipairs(pattern_templates) do
        local remote_spec, mount_path = line:match(pattern)
        if remote_spec and mount_path then
          table.insert(mounts, { mount_path = mount_path, remote_spec = remote_spec })
          break
        end
      end
    end
  end

  return mounts
end

--- Check if a mount path is actively mounted
--- @param mount_path string Path to check for active mount
--- @return boolean True if mount is active
function MountPoint.is_active(mount_path)
  local stat = vim.uv.fs_stat(mount_path)
  if not stat or stat.type ~= "directory" then return false end

  local mounts = get_system_mounts()
  for _, mount in ipairs(mounts) do
    if mount.mount_path == mount_path then return true end
  end

  return false
end

--- List all active sshfs mounts
--- @return table Array of mount objects with host, mount_path, and remote_path fields
function MountPoint.list_active()
  local mounts = {}
  local base_mount_dir = Config.get_base_dir()
  local system_mounts = get_system_mounts()

  -- Filter to only include mounts under our base directory
  local mount_dir_escaped = base_mount_dir:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  local prefix_pattern = "^" .. mount_dir_escaped .. "/(.+)$"

  for _, mount_info in ipairs(system_mounts) do
    local host = mount_info.mount_path:match(prefix_pattern)
    if host and host ~= "" then
      -- Parse remote_spec to extract remote path
      -- Format: "user@host:/remote/path" or "host:/remote/path"
      local remote_path = mount_info.remote_spec:match(":(.*)$")

      table.insert(mounts, {
        host = host,
        mount_path = mount_info.mount_path,
        remote_path = remote_path or "/", -- Default to root if parsing fails
      })
    end
  end

  return mounts
end

--- Check if any active mounts exist
--- @return boolean True if any active mounts exist
function MountPoint.has_active()
  local mounts = MountPoint.list_active()
  return #mounts > 0
end

--- Get first active mount (for backward compatibility with single-mount workflows)
--- @return table|nil Mount object with host, mount_path, and remote_path fields, or nil if none
function MountPoint.get_active()
  local mounts = MountPoint.list_active()
  if #mounts > 0 then return mounts[1] end
  return nil
end

--- Get or create mount directory
--- @param mount_dir string|nil Directory path (defaults to base mount dir from config)
--- @return boolean True if directory exists or was created successfully
function MountPoint.get_or_create(mount_dir)
  mount_dir = mount_dir or Config.get_base_dir()
  local stat = vim.uv.fs_stat(mount_dir)
  if stat and stat.type == "directory" then return true end

  local success = vim.fn.mkdir(mount_dir, "p")
  return success == 1
end

--- Release buffers associated with sshfs mount
--- @param mount_path string Path to unmount
--- @param is_q_exit boolean|nil Indicator if signal comes from command or :q
--- @return boolean True if all buffers are cleaned up
function MountPoint.release_mount(mount_path, is_q_exit)
  -- Normalize mount path to remove trailing slash for consistent comparison
  local safe_mount_path = mount_path:gsub("/$", "")
  local safe_mount_path_slash = safe_mount_path .. "/"

  local buffers_to_clean = {}

  -- Find valid buffers to release
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)

      -- Check if buffer is the mount root OR a file inside it
      local is_inside = buf_name == safe_mount_path or buf_name:sub(1, #safe_mount_path_slash) == safe_mount_path_slash

      if is_inside then
        -- If no write since last change, throw error for disconnect commands similar as in :q
        if vim.bo[buf].modified and not is_q_exit then
          local name = vim.fn.fnamemodify(buf_name, ":t")
          vim.notify('No write since last change for buffer "' .. name .. '"', vim.log.levels.ERROR)
          return false
        end

        table.insert(buffers_to_clean, buf)
      end
    end
  end

  -- Release LSP clients and buffers after verifying safe to do so
  for _, buf in ipairs(buffers_to_clean) do
    -- Stop terminal buffers
    if vim.bo[buf].buftype == "terminal" then
      local job_id = vim.b[buf].terminal_job_id
      if job_id then vim.fn.jobstop(job_id) end
    else -- Stop LSPs
      local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
      local clients = get_clients({ bufnr = buf })
      for _, client in ipairs(clients) do
        if client.stop then client.stop(true) end
      end
    end

    -- Wipe buffer
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  collectgarbage("collect")
  return true
end

--- Unmount an sshfs mount using fusermount/umount
--- @param mount_path string Path to unmount
--- @return boolean True if unmount succeeded
function MountPoint.unmount(mount_path)
  local commands = {
    { "fusermount", { "-u", mount_path } },
    { "fusermount3", { "-u", mount_path } },
    { "umount", { "-l", mount_path } }, -- Linux: lazy unmount
    { "umount", { mount_path } }, -- macOS/BSD: standard unmount
    { "diskutil", { "unmount", mount_path } }, -- macOS: fallback
  }

  for _, cmd in ipairs(commands) do
    local command, args = cmd[1], cmd[2]

    -- Try command if executable with jobstart
    if vim.fn.executable(command) == 1 then
      local job_id = vim.fn.jobstart(vim.list_extend({ command }, args), {
        stdout_buffered = true,
        stderr_buffered = true,
      })
      local exit_code = -1
      if job_id > 0 then
        local result = vim.fn.jobwait({ job_id }, 5000)[1] -- 5 second timeout
        exit_code = result or -1
      end

      if exit_code == 0 then
        vim.fn.delete(mount_path, "d")
        return true
      end
    end
  end

  return false
end

--- Clean up base mount directory if empty
--- @return boolean True if cleanup succeeded
function MountPoint.cleanup()
  local base_mount_dir = Config.get_base_dir()
  local stat = vim.uv.fs_stat(base_mount_dir)
  if stat and stat.type == "directory" and Directory.is_empty(base_mount_dir) then
    vim.fn.delete(base_mount_dir, "d")
    return true
  end
  return false
end

--- Clean up stale mount directories that are empty and not actively mounted
--- Only removes empty directories to avoid interfering with user-managed mounts.
--- This is useful after unclean unmounts (crashes, force-kills, etc.) that leave empty mount points.
--- @return number Count of directories removed
function MountPoint.cleanup_stale()
  local base_mount_dir = Config.get_base_dir()
  local stat = vim.uv.fs_stat(base_mount_dir)
  if not stat or stat.type ~= "directory" then return 0 end

  -- Scan for directories in base_mount_dir
  local files = vim.fn.glob(base_mount_dir .. "/*", false, true)
  local removed_count = 0

  for _, file in ipairs(files) do
    if vim.fn.isdirectory(file) == 1 then
      -- Only remove if directory is empty AND not actively mounted
      if Directory.is_empty(file) and not MountPoint.is_active(file) then
        MountPoint.unmount(file)
        local success = pcall(vim.fn.delete, file, "d")
        if success then removed_count = removed_count + 1 end
      end
    end
  end

  return removed_count
end

--- Run a command on a mounted directory
--- Prompts user to select a mount if multiple connections are active
--- @param command string|nil Command to run on mount path (e.g., "edit", "tcd", "Oil"). If nil, prompts user for input.
function MountPoint.run_command(command)
  local active_connections = MountPoint.list_active()

  if #active_connections == 0 then
    vim.notify("No active SSH connections", vim.log.levels.WARN)
    return
  end

  -- Prompt for command if not provided
  if not command then
    vim.ui.input({ prompt = "Command to run on mount: ", default = "" }, function(input)
      if input and input ~= "" then MountPoint.run_command(input) end
    end)
    return
  end

  if #active_connections == 1 then
    local mount_dir = active_connections[1].mount_path
    vim.cmd(command .. " " .. vim.fn.fnameescape(mount_dir))
    return
  end

  local items = {}
  for _, conn in ipairs(active_connections) do
    table.insert(items, conn.host)
  end

  vim.ui.select(items, {
    prompt = "Select mount to " .. command .. ":",
  }, function(_, idx)
    if idx then
      local mount_dir = active_connections[idx].mount_path
      vim.cmd(command .. " " .. vim.fn.fnameescape(mount_dir))
    end
  end)
end

return MountPoint
