-- lua/sshfs/api.lua
-- Public API wrapper providing high-level functions (connect, disconnect, browse, grep, edit)

local Api = {}
local Config = require("sshfs.config")

--- Connect to SSH host - use picker if no host provided, otherwise connect directly
--- @param host table|nil SSH host object (optional)
--- @param opts table|nil {mode = "mount"|"mirror"}; hosts in `mirror.hosts` default to mirror
Api.connect = function(host, opts)
  local Session = require("sshfs.session")
  if host then
    Session.connect(host, opts)
  else
    local Select = require("sshfs.ui.select")
    Select.host(function(selected_host)
      if selected_host then Session.connect(selected_host, opts) end
    end)
  end
end

--- Mirror a remote directory locally instead of mounting it
--- @param host table|nil SSH host object (optional)
Api.mirror = function(host)
  Api.connect(host, { mode = "mirror" })
end

--- Run an action on the mirror the user is working in
--- Picks the mirror containing the current buffer or directory, else the only one, else asks.
--- @param action function fun(connection: table)
local function with_mirror(action)
  local unavailable = require("sshfs.config").mirror_unavailable_reason()
  if unavailable then return vim.notify("Mirror mode is unavailable: " .. unavailable, vim.log.levels.ERROR) end

  local mirrors = vim.tbl_filter(function(connection)
    return connection.kind == "mirror"
  end, require("sshfs.lib.connections").list_active())

  if #mirrors == 0 then
    vim.notify("No active mirror", vim.log.levels.WARN)
    return
  end

  local here = vim.api.nvim_buf_get_name(0)
  if here == "" then here = vim.uv.cwd() end
  for _, mirror in ipairs(mirrors) do
    if here == mirror.local_path or vim.startswith(here, mirror.local_path .. "/") then return action(mirror) end
  end

  if #mirrors == 1 then return action(mirrors[1]) end

  local Connections = require("sshfs.lib.connections")
  vim.ui.select(mirrors, { prompt = "Select mirror:", format_item = Connections.format_label }, function(choice)
    if choice then action(choice) end
  end)
end

--- Delete a local mirror (folder and state file), picked from every mirror known locally
--- @param host_name string|nil Only this host's mirrors
--- @param force boolean|nil Delete even if it holds work that never reached the server, after a confirmation
Api.mirror_delete = function(host_name, force)
  local unavailable = require("sshfs.config").mirror_unavailable_reason()
  if unavailable then return vim.notify("Mirror mode is unavailable: " .. unavailable, vim.log.levels.ERROR) end

  local MirrorDelete = require("sshfs.lib.mirror_delete")
  local entries = MirrorDelete.entries(host_name)
  if #entries == 0 then
    return vim.notify(host_name and ("No mirror of " .. host_name) or "No mirrors found", vim.log.levels.WARN)
  end

  local function delete(entry)
    MirrorDelete.run(entry, { force = force })
  end
  if host_name and #entries == 1 then return delete(entries[1]) end
  require("sshfs.ui.select").mirror_delete(entries, delete)
end

--- Pull the remote tree into the current mirror, keeping locally edited files
Api.mirror_pull = function()
  with_mirror(function(mirror)
    local Mirror = require("sshfs.lib.mirror")
    Mirror.pull(mirror.local_path, function(result)
      Mirror.notify_pull(mirror.host, result)
    end)
  end)
end

--- Push every file changed locally since the last sync
--- @param delete boolean|nil Also delete server files removed locally (after a confirmation listing them)
Api.mirror_push = function(delete)
  with_mirror(function(mirror)
    require("sshfs.lib.mirror").push_all(mirror.local_path, { delete = delete }, function(result)
      if not result.ok then
        if result.message ~= "cancelled" then
          vim.notify("Mirror push failed: " .. result.message, vim.log.levels.ERROR)
        end
        return
      end
      if result.nothing then return vim.notify("Nothing to push to " .. mirror.host, vim.log.levels.INFO) end

      local message = string.format("Pushed %d file(s) to %s", result.pushed, mirror.host)
      if delete then message = message .. string.format(", deleted %d", result.deleted) end
      vim.notify(message, vim.log.levels.INFO)
      if #result.conflicts > 0 then
        vim.notify(
          "Not pushed, changed on the server since the last sync:\n" .. table.concat(result.conflicts, "\n"),
          vim.log.levels.WARN
        )
      end
      if #result.errors > 0 then
        vim.notify("Not pushed, could not check or send:\n" .. table.concat(result.errors, "\n"), vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Sync status of the current buffer for statuslines
--- @return string status "" outside a mirror, else pending, pushing, synced, conflict or error
Api.mirror_status = function()
  return vim.b.sshfs_mirror or ""
end

--- Test an SSH host without mounting - use picker if no host provided.
--- @param host table|nil SSH host object (optional)
Api.test = function(host)
  local Diagnostic = require("sshfs.diagnostic")
  if host then
    Diagnostic.test(host)
  else
    local Select = require("sshfs.ui.select")
    Select.host(function(selected_host)
      if selected_host then Diagnostic.test(selected_host) end
    end)
  end
end

--- Mount SSH host (alias for connect)
Api.mount = function()
  Api.connect()
end

--- Disconnect from current SSH host
Api.disconnect = function()
  local Session = require("sshfs.session")
  Session.disconnect()
end

--- Unmount from a SSH host
Api.unmount = function()
  local Session = require("sshfs.session")
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("No active mounts to disconnect", vim.log.levels.WARN)
    return
  elseif #active_connections == 1 then
    Session.disconnect_from(active_connections[1])
  else
    local Select = require("sshfs.ui.select")
    Select.unmount(function(selected_mount)
      if selected_mount then Session.disconnect_from(selected_mount) end
    end)
  end
end

--- Unmount all active SSH connections
Api.unmount_all = function()
  local Session = require("sshfs.session")
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("No active mounts to disconnect", vim.log.levels.WARN)
    return
  end

  -- Make a copy to avoid modifying table during iteration
  local all_connections = vim.list_extend({}, active_connections)
  local disconnected_count = 0
  for _, connection in ipairs(all_connections) do
    if Session.disconnect_from(connection, true) then disconnected_count = disconnected_count + 1 end
  end

  vim.notify(
    string.format("Disconnected from %d mount%s", disconnected_count, disconnected_count == 1 and "" or "s"),
    vim.log.levels.INFO
  )
end

--- Check connection status
--- @return boolean True if any active connections exist
Api.has_active = function()
  local Connections = require("sshfs.lib.connections")
  return Connections.has_active()
end

--- Get current connection info
--- @return table|nil Connection info or nil if none active
Api.get_active = function()
  local Connections = require("sshfs.lib.connections")
  return Connections.get_active()
end

--- Edit SSH config files using native picker
Api.config = function()
  local Select = require("sshfs.ui.select")
  Select.ssh_config(function(config_file)
    if config_file then vim.cmd("edit " .. vim.fn.fnameescape(config_file)) end
  end)
end

--- Reload SSH configuration
Api.reload = function()
  local Session = require("sshfs.session")
  Session.reload()
end

--- Toggle debug logging for the current Neovim session
--- @param mode string|nil Optional explicit mode: "on" or "off"
Api.debug = function(mode)
  local Logger = require("sshfs.lib.logger")
  local enabled

  if mode == nil or mode == "" then
    enabled = Logger.toggle()
  elseif mode == "on" then
    Logger.enable()
    enabled = true
  elseif mode == "off" then
    Logger.disable()
    enabled = false
  else
    vim.notify("Usage: :SSHDebug [on|off]", vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format("sshfs.nvim debug logging %s: %s", enabled and "enabled" or "disabled", Logger.path()),
    vim.log.levels.INFO
  )
end

--- Browse remote files using native file browser
--- @param opts table|nil Picker options
Api.find_files = function(opts)
  local Connections = require("sshfs.lib.connections")
  if not Connections.has_active() then
    vim.notify("Not connected to any remote host", vim.log.levels.WARN)
    return
  end

  local Picker = require("sshfs.ui.picker")
  Picker.browse_remote_files(opts)
end

--- Browse remote files - smart handling for multiple mounts
--- @param opts table|nil Picker options
Api.files = function(opts)
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("Not connected to any remote host", vim.log.levels.WARN)
    return
  elseif #active_connections == 1 then
    Api.find_files(opts)
  else
    Api.list_mounts()
  end
end

--- Search text in remote files using picker or native grep
--- @param pattern string|nil Search pattern
--- @param opts table|nil Picker options
Api.grep = function(pattern, opts)
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("Not connected to any remote host", vim.log.levels.WARN)
    return
  elseif #active_connections == 1 then
    local Picker = require("sshfs.ui.picker")
    Picker.grep_remote_files(pattern, opts)
  else
    local Select = require("sshfs.ui.select")
    Select.mount(function(selected_mount)
      if selected_mount then
        local Picker = require("sshfs.ui.picker")
        local grep_opts = opts or {}
        grep_opts.dir = selected_mount.mount_path
        Picker.grep_remote_files(pattern, grep_opts)
      end
    end)
  end
end

--- List all active mounts and open file picker for selected mount
Api.list_mounts = function()
  local Select = require("sshfs.ui.select")
  Select.mount(function(selected_mount)
    if selected_mount then
      local Picker = require("sshfs.ui.picker")
      local config = Config.get()
      local success, picker_name = Picker.open_file_picker(selected_mount.mount_path, config)

      if not success then
        vim.notify(
          "Could not open file picker (" .. picker_name .. ") for: " .. selected_mount.mount_path,
          vim.log.levels.WARN
        )
      end
    end
  end)
end

--- Run a custom command on SSHFS mount (prompts for command if not provided)
--- @param cmd string|nil Command to run (e.g., "edit", "tcd", "Oil"). If nil, prompts user.
Api.command = function(cmd)
  local MountPoint = require("sshfs.lib.mount_point")
  MountPoint.run_command(cmd)
end

--- Explore SSHFS mount (opens directory as buffer, triggering file explorer)
Api.explore = function()
  local MountPoint = require("sshfs.lib.mount_point")
  MountPoint.run_command("edit")
end

--- Change directory to an SSHFS mount
Api.change_dir = function()
  local MountPoint = require("sshfs.lib.mount_point")
  MountPoint.run_command("tcd")
end

--- Open SSH terminal session to remote host
Api.ssh_terminal = function()
  local Terminal = require("sshfs.ui.terminal")
  Terminal.open_ssh()
end

--- Live grep on mounted remote host (requires telescope or fzf-lua and active connection)
--- Executes ripgrep/grep directly on remote server via SSH and streams results
--- Note: Requires an active mount. Use :SSHConnect first.
---@param path string|nil Remote path to search (defaults to mounted remote path)
Api.live_grep = function(path)
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("Not connected to any remote host. Use :SSHConnect first.", vim.log.levels.WARN)
    return
  end

  local function fallback_to_local_grep(connection)
    local Picker = require("sshfs.ui.picker")
    Picker.grep_remote_files(nil, { dir = connection.mount_path })
  end

  local function execute_live_grep(connection)
    if connection.remote_metadata_available == false then
      vim.notify(
        "Remote host/path metadata is unavailable for this mount. Falling back to local grep on the mounted path.",
        vim.log.levels.WARN
      )
      return fallback_to_local_grep(connection)
    end

    local Picker = require("sshfs.ui.picker")
    local config = Config.get()
    local search_path = connection.remote_path or path or "."

    local success, picker_name =
      Picker.open_live_remote_grep(connection.host, connection.mount_path, search_path, config)

    if not success then
      vim.notify(
        "Live grep not available: " .. picker_name .. ". Falling back to local grep on mounted path.",
        vim.log.levels.WARN
      )
      return fallback_to_local_grep(connection)
    end
  end

  if #active_connections == 1 then
    execute_live_grep(active_connections[1])
  else
    -- Multiple mounts - prompt for selection
    local Select = require("sshfs.ui.select")
    Select.mount(function(selected_mount)
      if selected_mount then execute_live_grep(selected_mount) end
    end)
  end
end

--- Live find on mounted remote host (requires telescope or fzf-lua and active connection)
--- Executes fd/find directly on remote server via SSH and streams results
--- Note: Requires an active mount. Use :SSHConnect first.
---@param path string|nil Remote path to search (defaults to mounted remote path)
Api.live_find = function(path)
  local Connections = require("sshfs.lib.connections")
  local active_connections = Connections.list_active()

  if #active_connections == 0 then
    vim.notify("Not connected to any remote host. Use :SSHConnect first.", vim.log.levels.WARN)
    return
  end

  local function fallback_to_local_find(connection)
    local Picker = require("sshfs.ui.picker")
    local config = Config.get()
    local ok, picker_name = Picker.open_file_picker(connection.mount_path, config)
    if not ok then
      vim.notify(
        "Fallback file picker failed for "
          .. connection.mount_path
          .. " ("
          .. picker_name
          .. "). Install a supported picker.",
        vim.log.levels.ERROR
      )
    end
  end

  local function execute_live_find(connection)
    if connection.remote_metadata_available == false then
      vim.notify(
        "Remote host/path metadata is unavailable for this mount. Falling back to the mounted path.",
        vim.log.levels.WARN
      )
      return fallback_to_local_find(connection)
    end

    local Picker = require("sshfs.ui.picker")
    local config = Config.get()
    local search_path = connection.remote_path or path or "."

    local success, picker_name =
      Picker.open_live_remote_find(connection.host, connection.mount_path, search_path, config)

    if not success then
      vim.notify(
        "Live find not available: " .. picker_name .. ". Falling back to local find on mounted path.",
        vim.log.levels.WARN
      )
      return fallback_to_local_find(connection)
    end
  end

  if #active_connections == 1 then
    execute_live_find(active_connections[1])
  else
    -- Multiple mounts - prompt for selection
    local Select = require("sshfs.ui.select")
    Select.mount(function(selected_mount)
      if selected_mount then execute_live_find(selected_mount) end
    end)
  end
end

-- TODO: Remove these after January 15th
-- Deprecated aliases (kept for backward compatibility)
--- @deprecated Use config instead
Api.edit = Api.config

--- @deprecated Use files instead
Api.browse = Api.files

--- @deprecated Use explore instead
Api.change_to_mount_dir = Api.explore

--- Creates API commands for vim api.
Api.setup = function()
  vim.api.nvim_create_user_command("SSHConnect", function(opts)
    if opts.args and opts.args ~= "" then
      local SSHConfig = require("sshfs.lib.ssh_config")
      local host = SSHConfig.resolve_input(opts.args)
      if not host then
        vim.notify("Could not read a host from: " .. opts.args, vim.log.levels.ERROR)
        return
      end
      Api.connect(host)
    else
      Api.connect()
    end
  end, { nargs = "?", desc = "Remotely connect to host via picker or command as argument." })

  vim.api.nvim_create_user_command("SSHMirror", function(opts)
    if opts.args and opts.args ~= "" then
      local SSHConfig = require("sshfs.lib.ssh_config")
      local host = SSHConfig.resolve_input(opts.args)
      if not host then
        vim.notify("Could not read a host from: " .. opts.args, vim.log.levels.ERROR)
        return
      end
      Api.mirror(host)
    else
      Api.mirror()
    end
  end, { nargs = "?", desc = "Mirror a remote directory locally (edit at local speed, sync on save)." })

  vim.api.nvim_create_user_command("SSHMirrorPull", function()
    Api.mirror_pull()
  end, { desc = "Pull the remote tree into the mirror, keeping locally edited files" })

  vim.api.nvim_create_user_command("SSHMirrorPush", function(opts)
    Api.mirror_push(opts.bang)
  end, { bang = true, desc = "Push locally changed mirror files (! also deletes server files removed locally)" })

  vim.api.nvim_create_user_command("SSHMirrorDelete", function(opts)
    local host_name = opts.args ~= "" and opts.args or nil
    Api.mirror_delete(host_name, opts.bang)
  end, {
    nargs = "?",
    bang = true,
    complete = function()
      local hosts, seen = {}, {}
      for _, state in ipairs(require("sshfs.lib.mirror_state").list()) do
        if not seen[state.host] then
          seen[state.host] = true
          table.insert(hosts, state.host)
        end
      end
      return hosts
    end,
    desc = "Delete a local mirror and its record (! even with unpushed work, after a confirmation)",
  })

  vim.api.nvim_create_user_command("SSHTest", function(opts)
    if opts.args and opts.args ~= "" then
      local SSHConfig = require("sshfs.lib.ssh_config")
      local host = SSHConfig.resolve_input(opts.args)
      if not host then
        vim.notify("Could not read a host from: " .. opts.args, vim.log.levels.ERROR)
        return
      end
      Api.test(host)
    else
      Api.test()
    end
  end, { nargs = "?", desc = "Test SSH connection and show resolved parameters and exit codes" })

  vim.api.nvim_create_user_command("SSHConfig", function()
    Api.config()
  end, { desc = "Edit SSH config files" })

  vim.api.nvim_create_user_command("SSHReload", function()
    Api.reload()
  end, { desc = "Reload SSH configuration" })

  vim.api.nvim_create_user_command("SSHDebug", function(opts)
    Api.debug(opts.args)
  end, {
    nargs = "?",
    complete = function()
      return { "on", "off" }
    end,
    desc = "Toggle sshfs.nvim debug logging",
  })

  vim.api.nvim_create_user_command("SSHDisconnect", function()
    Api.unmount()
  end, { desc = "Disconnect from current SSH host" })

  vim.api.nvim_create_user_command("SSHDisconnectAll", function()
    Api.unmount_all()
  end, { desc = "Disconnect from all SSH hosts" })

  vim.api.nvim_create_user_command("SSHTerminal", function()
    Api.ssh_terminal()
  end, { desc = "Open SSH terminal session to remote host" })

  vim.api.nvim_create_user_command("SSHFiles", function()
    Api.files()
  end, { desc = "Browse remote files" })

  vim.api.nvim_create_user_command("SSHLiveFind", function(opts)
    local pattern = opts.args and opts.args ~= "" and opts.args or nil
    Api.live_find(pattern)
  end, { nargs = "?", desc = "Live find on mounted remote host" })

  vim.api.nvim_create_user_command("SSHGrep", function(opts)
    local pattern = opts.args and opts.args ~= "" and opts.args or nil
    Api.grep(pattern)
  end, { nargs = "?", desc = "Search text in remote files" })

  vim.api.nvim_create_user_command("SSHLiveGrep", function(opts)
    local pattern = opts.args and opts.args ~= "" and opts.args or nil
    Api.live_grep(pattern)
  end, { nargs = "?", desc = "Live grep on mounted remote host" })

  vim.api.nvim_create_user_command("SSHExplore", function()
    Api.explore()
  end, { desc = "Explore SSH mount" })

  vim.api.nvim_create_user_command("SSHCommand", function(opts)
    local cmd = opts.args and opts.args ~= "" and opts.args or nil
    Api.command(cmd)
  end, { nargs = "?", desc = "Run command on SSH mount (e.g., :SSHCommand tcd)" })

  vim.api.nvim_create_user_command("SSHChangeDir", function()
    Api.change_dir()
  end, { desc = "Change directory to SSH mount" })

  -- TODO: Delete these after January 15th
  -- Deprecated command aliases
  vim.api.nvim_create_user_command("SSHEdit", function()
    vim.notify("SSHEdit is deprecated. Use :SSHConfig instead.", vim.log.levels.WARN)
    Api.config()
  end, { desc = "Edit SSH config files (deprecated: use SSHConfig)" })

  vim.api.nvim_create_user_command("SSHBrowse", function()
    vim.notify("SSHBrowse is deprecated. Use :SSHFiles instead.", vim.log.levels.WARN)
    Api.files()
  end, { desc = "Browse remote files (deprecated: use SSHFiles)" })
end

return Api
