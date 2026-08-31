-- tests/logger_spec.lua
-- Opt-in debug logging: gating, formatting, and runtime toggling

--- Load the logger against a temporary log file
--- @param debug_config table|nil Value for the `debug` configuration table
--- @return table Logger, string log_path
local function load_logger(debug_config)
  stub.reload()
  local log_path = vim.fn.tempname() .. "/sshfs.nvim.log"
  if debug_config then debug_config.log_file = debug_config.log_file or log_path end
  require("sshfs.config").setup({ debug = debug_config })
  return require("sshfs.lib.logger"), log_path
end

--- Read a log file, returning an empty list when it was never created
local function read_log(path)
  if vim.fn.filereadable(path) == 0 then return {} end
  return vim.fn.readfile(path)
end

local function cleanup(path)
  vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
end

describe("debug logging gate", function()
  it("writes nothing at all while disabled", function()
    local Logger, log_path = load_logger({ enabled = false })

    Logger.debug("a message")
    Logger.error("another message")

    expect.eq(vim.fn.filereadable(log_path), 0, "a disabled logger must not even create the file")
    cleanup(log_path)
  end)

  it("writes when enabled through configuration", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.debug("a message")

    expect.eq(#read_log(log_path), 1)
    cleanup(log_path)
  end)

  it("is disabled by default", function()
    stub.reload()
    require("sshfs.config").setup({})

    expect.falsy(require("sshfs.lib.logger").is_enabled())
  end)

  it("does not raise when used before setup has run", function()
    stub.reload()
    local Logger = require("sshfs.lib.logger")

    expect.no_error(function()
      Logger.is_enabled()
    end, "configuration may not exist yet")
    expect.no_error(function()
      Logger.path()
    end)
  end)
end)

describe("runtime toggling", function()
  it("enables logging without rewriting configuration", function()
    local Logger, log_path = load_logger({ enabled = false })

    expect.truthy(Logger.toggle())
    Logger.debug("now recorded")

    expect.eq(#read_log(log_path), 1)
    expect.falsy(require("sshfs.config").get().debug.enabled, "user configuration stays untouched")
    cleanup(log_path)
  end)

  it("disables logging that configuration had enabled", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.disable()
    Logger.debug("not recorded")

    expect.eq(read_log(log_path), {})
    cleanup(log_path)
  end)

  it("toggles back and forth", function()
    local Logger, log_path = load_logger({ enabled = false })

    expect.truthy(Logger.toggle())
    expect.falsy(Logger.toggle())
    expect.truthy(Logger.toggle())
    cleanup(log_path)
  end)

  it("reports the active log path", function()
    local Logger, log_path = load_logger({ enabled = true })
    expect.eq(Logger.path(), log_path)
    cleanup(log_path)
  end)
end)

describe("log formatting", function()
  it("records a timestamp, level, and message", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.warn("something happened")
    local line = read_log(log_path)[1]

    expect.truthy(line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %[WARN%] something happened$"), line)
    cleanup(log_path)
  end)

  it("renders context in a stable order", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.debug("mount", { host = "example.com", exit_code = 1, mount_point = "/mnt/x" })
    local line = read_log(log_path)[1]

    expect.contains(line, "exit_code=1 host=example.com mount_point=/mnt/x")
    cleanup(log_path)
  end)

  it("keeps multi-line subprocess output on one line", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.error("mount failed", { stderr = "first line\nsecond line\twith a tab" })
    local log = read_log(log_path)

    expect.eq(#log, 1, "an embedded newline must not split the record")
    expect.contains(log[1], "stderr=first line\\nsecond line\\twith a tab")
    cleanup(log_path)
  end)

  it("appends rather than truncating", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.debug("first")
    Logger.debug("second")

    expect.eq(#read_log(log_path), 2)
    cleanup(log_path)
  end)

  it("creates the log directory when it does not exist", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.debug("first")

    expect.eq(vim.fn.isdirectory(vim.fn.fnamemodify(log_path, ":h")), 1)
    cleanup(log_path)
  end)

  it("writes the log file readable only by its owner", function()
    local Logger, log_path = load_logger({ enabled = true })

    Logger.debug("sensitive output")
    local mode = vim.fn.getfperm(log_path)

    expect.eq(mode, "rw-------", "logs can contain hostnames and SSH output")
    cleanup(log_path)
  end)
end)

describe("log write failures", function()
  it("reports a write failure once rather than on every call", function()
    local Logger = load_logger({ enabled = true, log_file = "/proc/definitely-not-writable/sshfs.log" })
    local notifications = stub.notifications()
    -- The failure notice is scheduled onto the event loop; run it inline.
    stub.set("schedule", function(fn)
      fn()
    end)

    Logger.debug("first")
    Logger.debug("second")
    Logger.debug("third")
    stub.restore_all()

    expect.eq(#notifications, 1, "a broken log path must not spam the user")
    expect.contains(notifications[1].message, "failed to write debug log")
  end)

  it("does not raise out of the caller", function()
    local Logger = load_logger({ enabled = true, log_file = "/proc/definitely-not-writable/sshfs.log" })
    stub.notifications()
    stub.set("schedule", function(fn)
      fn()
    end)

    expect.no_error(function()
      Logger.debug("a message")
    end, "logging is diagnostic and must never break the operation it describes")
    stub.restore_all()
  end)
end)

describe(":SSHDebug", function()
  local function run_debug(mode)
    stub.reload()
    local log_path = vim.fn.tempname() .. "/sshfs.nvim.log"
    require("sshfs.config").setup({ debug = { enabled = false, log_file = log_path } })
    local notifications = stub.notifications()

    require("sshfs.api").debug(mode)
    local enabled = require("sshfs.lib.logger").is_enabled()
    stub.restore_all()
    cleanup(log_path)

    return enabled, notifications
  end

  it("toggles when given no argument", function()
    local enabled, notifications = run_debug(nil)

    expect.truthy(enabled)
    expect.contains(notifications[1].message, "enabled")
  end)

  it("treats an empty argument as a toggle", function()
    expect.truthy(run_debug(""))
  end)

  it("enables explicitly with on", function()
    local enabled, notifications = run_debug("on")

    expect.truthy(enabled)
    expect.contains(notifications[1].message, "enabled")
  end)

  it("disables explicitly with off", function()
    local enabled, notifications = run_debug("off")

    expect.falsy(enabled)
    expect.contains(notifications[1].message, "disabled")
  end)

  it("reports the log path so the user can find it", function()
    local _, notifications = run_debug("on")
    expect.contains(notifications[1].message, "sshfs.nvim.log")
  end)

  it("rejects an unknown argument without changing state", function()
    local enabled, notifications = run_debug("maybe")

    expect.falsy(enabled)
    expect.contains(notifications[1].message, "Usage: :SSHDebug [on|off]")
    expect.eq(notifications[1].level, vim.log.levels.ERROR)
  end)
end)
