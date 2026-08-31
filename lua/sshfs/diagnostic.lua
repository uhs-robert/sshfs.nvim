-- lua/sshfs/diagnostic.lua
-- Read-only SSH connection preflight diagnostics.

local Diagnostic = {}

local function shell_join(cmd)
  return table.concat(vim.tbl_map(vim.fn.shellescape, cmd), " ")
end

local function run(cmd, callback)
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      callback({
        command = cmd,
        code = obj.code,
        stdout = vim.trim(obj.stdout or ""),
        stderr = vim.trim(obj.stderr or ""),
      })
    end)
  end)
end

local function parse_ssh_config(output)
  local resolved = {}
  for line in output:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%S+)%s+(.+)$")
    if key and value then
      if resolved[key] == nil then
        resolved[key] = value
      elseif key == "identityfile" then
        resolved[key] = resolved[key] .. ", " .. value
      end
    end
  end
  return resolved
end

local function append_output(lines, label, output)
  if output == "" then return end
  table.insert(lines, label .. ":")
  for line in output:gmatch("[^\r\n]+") do
    table.insert(lines, "  " .. line)
  end
end

--- @param include_stdout boolean|nil Set to false to omit stdout (already summarized elsewhere)
local function append_result(lines, name, result, include_stdout)
  table.insert(lines, string.format("[%s] %s", result.code == 0 and "PASS" or "FAIL", name))
  table.insert(lines, "Command: " .. shell_join(result.command))
  table.insert(lines, "Exit code: " .. tostring(result.code))
  if include_stdout ~= false then append_output(lines, "stdout", result.stdout) end
  append_output(lines, "stderr", result.stderr)
  table.insert(lines, "")
end

local function show_report(host, resolved, config_result, auth_result, home_result)
  local Sshfs = require("sshfs.lib.sshfs")
  local lines = {
    "sshfs.nvim connection test",
    "============================",
    "",
    "Input",
    "  host: " .. tostring(host.name),
    "  user: " .. tostring(host.user or "(SSH config/default)"),
    "  path: " .. tostring(host.path or "(selected during connect)"),
    "  port: " .. tostring(host.port or "(SSH config/default)"),
    "",
    "Resolved SSH configuration",
    "  hostname: " .. tostring(resolved.hostname or "unknown"),
    "  user: " .. tostring(resolved.user or "unknown"),
    "  port: " .. tostring(resolved.port or "unknown"),
    "  proxyjump: " .. tostring(resolved.proxyjump or "none"),
    "  identityfile: " .. tostring(resolved.identityfile or "default"),
    "",
    "Tests",
    "",
  }

  -- `ssh -G` prints the whole resolved config; the summary above already covers
  -- the fields that matter, so the raw dump is omitted to keep the report readable.
  append_result(lines, "SSH configuration", config_result, false)
  append_result(lines, "SSH authentication", auth_result)
  if home_result then append_result(lines, "Remote home", home_result) end

  table.insert(lines, "SSHFS command")
  if host.path and host.path ~= "" then
    local remote_path = host.path
    if home_result and home_result.code == 0 and remote_path:match("^~") then
      local home_path = vim.trim(home_result.stdout)
      if home_path:sub(1, 1) == "/" then remote_path = remote_path:gsub("^~", home_path) end
    end
    local mount_cmd = Sshfs.build_mount_command(host, "<mount-point>", remote_path)
    table.insert(lines, "  " .. shell_join(mount_cmd))
    table.insert(lines, "  Note: <mount-point> is determined by SSHConnect and is not created by SSHTest.")
  else
    table.insert(lines, "  Not shown: SSHConnect prompts for a remote path before the mount command can be determined.")
  end
  table.insert(lines, "")
  table.insert(lines, "This preflight does not mount SSHFS or leave diagnostic ControlMaster state behind.")

  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, string.format("sshfs://test/%s/%d", host.name, buf))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Run a read-only preflight for a host and show a scratch-buffer report.
---@param host table Host object produced by ssh_config.parse_host/get_host_config
function Diagnostic.test(host)
  local Ssh = require("sshfs.lib.ssh")

  local config_cmd = { "ssh", "-G" }
  if host.port then vim.list_extend(config_cmd, { "-p", tostring(host.port) }) end
  if host.user then vim.list_extend(config_cmd, { "-l", host.user }) end
  table.insert(config_cmd, host.name)

  run(config_cmd, function(config_result)
    local resolved = parse_ssh_config(config_result.stdout)
    local had_control_master = Ssh.has_control_master(host)
    local socket_dir, socket_error = Ssh.prepare_socket_dir()

    if not socket_dir then
      show_report(host, resolved, config_result, {
        command = Ssh.build_batch_command(host),
        code = 1,
        stdout = "",
        stderr = socket_error or "Failed to prepare SSH control socket directory",
      }, nil)
      return
    end

    local function finish(auth_result, home_result)
      if not had_control_master then Ssh.cleanup_control_master(host) end
      show_report(host, resolved, config_result, auth_result, home_result)
    end

    local auth_cmd = Ssh.build_batch_command(host)
    run(auth_cmd, function(auth_result)
      local needs_home = host.path and host.path:match("^~")
      if not needs_home or auth_result.code ~= 0 then
        finish(auth_result, nil)
        return
      end

      run(Ssh.build_home_command(host), function(home_result)
        finish(auth_result, home_result)
      end)
    end)
  end)
end

return Diagnostic
