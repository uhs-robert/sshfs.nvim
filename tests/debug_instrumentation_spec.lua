-- tests/debug_instrumentation_spec.lua
-- What debug logging actually records for a connection attempt
--
-- Issue #9 was hard to diagnose because subprocess details were discarded.
-- These cover that the details survive when logging is on, and that nothing is
-- recorded when it is off.

--- Run a connection attempt with logging configured, returning the log lines
--- @param opts table {enabled, batch_success, mount_code, mount_stderr}
--- @return table lines
local function connect_and_read_log(opts)
  stub.reload()
  local log_path = vim.fn.tempname() .. "/sshfs.nvim.log"
  require("sshfs.config").setup({ debug = { enabled = opts.enabled, log_file = log_path } })

  package.loaded["sshfs.lib.ssh"] = {
    try_batch_connect = function(_, callback)
      callback(opts.batch_success or false, opts.batch_success and 0 or 255, "Permission denied (publickey).")
    end,
    open_auth_terminal = function(_, callback)
      callback(false, 1)
    end,
    build_command_string = function()
      return "ssh"
    end,
  }

  stub.notifications()
  stub.set("schedule", function(fn)
    fn()
  end)
  stub.set("system", function(_, _, callback)
    local result = { code = opts.mount_code or 0, stdout = "", stderr = opts.mount_stderr or "" }
    if callback then callback(result) end
    return {
      wait = function()
        return result
      end,
    }
  end)

  require("sshfs.lib.sshfs").authenticate_and_mount(
    { name = "example.com", user = "deploy" },
    "/home/tester/mnt/example",
    "/srv/app",
    function() end
  )
  stub.restore_all()

  local lines = vim.fn.filereadable(log_path) == 1 and vim.fn.readfile(log_path) or {}
  vim.fn.delete(vim.fn.fnamemodify(log_path, ":h"), "rf")
  return lines
end

--- Find the first log line containing a substring
local function line_with(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then return line end
  end
  return nil
end

describe("connection diagnostics with logging enabled", function()
  it("records the mount attempt with its host and target", function()
    local lines = connect_and_read_log({ enabled = true, batch_success = true })
    local line = line_with(lines, "Starting SSHFS mount")

    expect.truthy(line, "the mount attempt must be recorded")
    expect.contains(line, "host=example.com")
    expect.contains(line, "mount_point=/home/tester/mnt/example")
  end)

  it("records the exit code and stderr of a failed mount", function()
    local lines = connect_and_read_log({
      enabled = true,
      batch_success = true,
      mount_code = 1,
      mount_stderr = "read: Connection reset by peer",
    })
    local line = line_with(lines, "SSHFS mount failed")

    expect.truthy(line)
    expect.contains(line, "exit_code=1")
    expect.contains(line, "Connection reset by peer")
  end)

  it("records the fallback from batch to interactive authentication", function()
    local lines = connect_and_read_log({ enabled = true, batch_success = false })

    expect.truthy(line_with(lines, "falling back to interactive authentication"))
    expect.truthy(line_with(lines, "Permission denied"), "the SSH reason must be preserved")
  end)

  it("records an authentication failure", function()
    local lines = connect_and_read_log({ enabled = true, batch_success = false })
    local line = line_with(lines, "SSH authentication failed")

    expect.truthy(line)
    expect.contains(line, "[ERROR]")
  end)
end)

describe("connection diagnostics with logging disabled", function()
  it("records nothing at all", function()
    local lines = connect_and_read_log({
      enabled = false,
      batch_success = true,
      mount_code = 1,
      mount_stderr = "read: Connection reset by peer",
    })

    expect.eq(lines, {}, "normal usage must not write a log file")
  end)
end)
