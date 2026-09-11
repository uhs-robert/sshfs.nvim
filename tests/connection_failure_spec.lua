-- tests/connection_failure_spec.lua
-- Connection failure diagnostics and mount directory ownership

local RESOLVE_ERROR = "ssh: Could not resolve hostname nope: Name or service not known"

--- Drive authenticate_and_mount with stubbed SSH and sshfs subprocesses
--- @param opts table {batch_success, batch_code, batch_error, interactive_success,
---   interactive_code, mount_code, mount_stdout, mount_stderr}
--- @return table result Callback result table
--- @return table events Ordered list of the SSH stages that ran
local function connect(opts)
  stub.reload()
  require("sshfs.config").setup({})

  local events = {}
  package.loaded["sshfs.lib.ssh"] = {
    try_batch_connect = function(_, callback)
      table.insert(events, "batch")
      callback(opts.batch_success or false, opts.batch_code or 255, opts.batch_error)
    end,
    open_auth_terminal = function(_, callback)
      table.insert(events, "interactive")
      callback(opts.interactive_success or false, opts.interactive_code or 1)
    end,
    build_command_string = function()
      return "ssh"
    end,
    get_remote_home = function(_, callback)
      table.insert(events, "remote_home")
      callback("/home/deploy", nil)
    end,
  }

  stub.notifications()
  stub.set("schedule", function(fn)
    fn()
  end)
  stub.set("system", function(_, _, callback)
    table.insert(events, "sshfs")
    local result = {
      code = opts.mount_code or 0,
      stdout = opts.mount_stdout or "",
      stderr = opts.mount_stderr or "",
    }
    if callback then callback(result) end
    return {
      wait = function()
        return result
      end,
    }
  end)

  local result = nil
  require("sshfs.lib.sshfs").authenticate_and_mount(
    { name = "example.com" },
    "/home/tester/mnt/example",
    "/srv/app",
    function(callback_result)
      result = callback_result
    end
  )
  stub.restore_all()

  return result, events
end

describe("unresolved host handling", function()
  it("fails fast instead of opening an interactive prompt", function()
    local result, events = connect({ batch_error = RESOLVE_ERROR })

    expect.eq(events, { "batch" }, "an unresolved host cannot be fixed by authenticating")
    expect.falsy(result.success)
    expect.eq(result.stage, "connection")
  end)

  it("surfaces the underlying SSH message", function()
    local result = connect({ batch_error = RESOLVE_ERROR })

    expect.contains(result.message, "Could not resolve hostname")
    expect.contains(result.message, "example.com")
    expect.eq(result.exit_code, 255)
  end)

  it("recognizes the macOS resolver wording", function()
    local _, events = connect({
      batch_error = "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known",
    })

    expect.eq(events, { "batch" })
  end)

  it("still offers interactive authentication for other batch failures", function()
    local _, events = connect({ batch_error = "Permission denied (publickey,password)." })

    expect.eq(events, { "batch", "interactive" }, "a credential failure is worth prompting for")
  end)
end)

describe("authentication failure reporting", function()
  it("reports both the batch and interactive exit codes", function()
    local result = connect({
      batch_error = "Permission denied (publickey).",
      batch_code = 255,
      interactive_code = 1,
    })

    expect.eq(result.stage, "authentication")
    expect.contains(result.message, "batch exit code: 255")
    expect.contains(result.message, "interactive exit code: 1")
    expect.contains(result.message, "Permission denied")
  end)
end)

describe("mount failure reporting", function()
  it("preserves the sshfs exit code and stderr", function()
    local result = connect({
      batch_success = true,
      mount_code = 1,
      mount_stderr = "read: Connection reset by peer",
    })

    expect.falsy(result.success)
    expect.eq(result.stage, "mount")
    expect.eq(result.exit_code, 1)
    expect.eq(result.stderr, "read: Connection reset by peer")
    expect.contains(result.message, "exit code: 1")
    expect.contains(result.message, "Connection reset by peer")
  end)

  it("falls back to stdout when stderr is empty", function()
    local result = connect({
      batch_success = true,
      mount_code = 1,
      mount_stdout = "remote host has disconnected",
      mount_stderr = "   ",
    })

    expect.contains(result.message, "remote host has disconnected")
    expect.is_nil(result.stderr, "whitespace-only stderr is not real output")
  end)

  it("still reports an exit code when the process says nothing", function()
    local result = connect({ batch_success = true, mount_code = 32 })

    expect.contains(result.message, "exit code: 32")
    expect.is_nil(result.stdout)
    expect.is_nil(result.stderr)
  end)

  it("reports success for a clean mount", function()
    local result = connect({ batch_success = true, mount_code = 0 })

    expect.truthy(result.success)
    expect.eq(result.resolved_path, "/srv/app")
  end)
end)

describe("MountPoint.get_or_create ownership", function()
  local function temp_path()
    return vim.fn.tempname() .. "/sshfs-test"
  end

  it("claims ownership of a directory it created", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    local path = temp_path()

    local success, created = MountPoint.get_or_create(path)
    expect.truthy(success)
    expect.truthy(created)

    vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
  end)

  it("does not claim ownership of a pre-existing directory", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    local path = temp_path()
    vim.fn.mkdir(path, "p")

    local success, created = MountPoint.get_or_create(path)
    expect.truthy(success)
    expect.falsy(created, "another process may still be using a directory we did not create")

    vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
  end)

  it("treats a directory that appears mid-call as usable but unowned", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    local path = temp_path()

    -- Simulate losing the creation race: the directory really is on disk (so the
    -- leaf mkdir raises E739 for real), but the initial stat reports it missing,
    -- exactly as it would if another process created it a moment later.
    vim.fn.mkdir(path, "p")
    local real_fs_stat = vim.uv.fs_stat
    local stats = 0
    stub.set("uv.fs_stat", function(target)
      stats = stats + 1
      if stats == 1 and target == path then return nil end
      return real_fs_stat(target)
    end)

    local success, created = expect.no_error(function()
      return MountPoint.get_or_create(path)
    end)
    stub.restore_all()

    expect.truthy(success, "the directory exists and is usable")
    expect.falsy(created, "the race loser must not claim ownership")

    vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
  end)

  it("reports failure without raising when the directory cannot be created", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")

    local success, created = expect.no_error(function()
      return MountPoint.get_or_create("/proc/definitely-not-writable/mount")
    end)

    expect.falsy(success, "vim.fn.mkdir raises E739 rather than returning 0")
    expect.falsy(created)
  end)
end)
