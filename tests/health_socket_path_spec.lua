-- tests/health_socket_path_spec.lua
-- checkhealth warning for ControlMaster socket paths that exceed sun_path
--
-- A long socket_dir makes every connection fail with a cryptic
-- "unix_listener: path ... too long for Unix domain socket", which is exactly
-- the kind of failure this PR exists to make legible.

--- Run :checkhealth with a given socket directory and collect the reports
--- @param socket_dir string
--- @param platform string|nil "mac" to simulate the 104 byte BSD limit
--- @return table reports List of {level, message, advice}
local function health_reports(socket_dir, platform)
  stub.reload()

  local reports = {}
  local function record(level)
    return function(message, advice)
      table.insert(reports, { level = level, message = message, advice = advice })
    end
  end

  stub.set("health", {
    start = function() end,
    ok = record("ok"),
    info = record("info"),
    warn = record("warn"),
    error = record("error"),
  })
  stub.set("fn.has", function(feature)
    return (platform and feature == platform) and 1 or 0
  end)

  require("sshfs.config").setup({ connections = { socket_dir = socket_dir } })
  require("sshfs.health").check()
  stub.restore_all()

  return reports
end

--- The single report mentioning the socket directory path length
local function socket_path_report(reports)
  for _, report in ipairs(reports) do
    if type(report.message) == "string" and report.message:find("socket directory path", 1, true) then return report end
  end
  return nil
end

--- Build a socket directory of an exact character length
local function dir_of_length(length)
  local prefix = "/tmp/"
  return prefix .. string.rep("s", length - #prefix)
end

-- Linux: 108 byte sun_path, minus the trailing NUL and the 58 characters ssh
-- appends ("/" + 40 character %C hash + "." + 16 character suffix) = 49.
local LINUX_BUDGET = 49
local MAC_BUDGET = 45

describe("checkhealth socket path length", function()
  it("accepts a short socket directory", function()
    local report = socket_path_report(health_reports("/home/me/.ssh/sockets"))

    expect.truthy(report)
    expect.eq(report.level, "ok")
  end)

  it("reports the budget it measured against", function()
    local report = socket_path_report(health_reports("/home/me/.ssh/sockets"))
    expect.contains(report.message, "of " .. LINUX_BUDGET .. " characters")
  end)

  it("errors when the path cannot fit a control socket", function()
    local report = socket_path_report(health_reports(dir_of_length(LINUX_BUDGET + 1)))

    expect.truthy(report)
    expect.eq(report.level, "error", "every connection would fail, so this is not merely a warning")
    expect.contains(report.message, "too long")
  end)

  it("names the real failure the user would otherwise see", function()
    local report = socket_path_report(health_reports(dir_of_length(LINUX_BUDGET + 1)))
    expect.contains(report.advice, "unix_listener")
  end)

  it("suggests a shorter socket directory", function()
    local report = socket_path_report(health_reports(dir_of_length(LINUX_BUDGET + 1)))
    expect.contains(report.advice, "connections.socket_dir")
  end)

  it("accepts a path exactly at the limit", function()
    local report = socket_path_report(health_reports(dir_of_length(LINUX_BUDGET)))
    expect.falsy(report.level == "error", "a path that just fits still works")
  end)

  it("warns before the limit is reached", function()
    local report = socket_path_report(health_reports(dir_of_length(LINUX_BUDGET - 5)))

    expect.eq(report.level, "warn", "a nearly full budget breaks on the next deeper path")
    expect.contains(report.message, "close to the limit")
  end)

  it("applies the smaller BSD limit on macOS", function()
    -- Long enough to overrun the 104 byte BSD sun_path, short enough to still
    -- fit the 108 byte Linux one.
    local length = MAC_BUDGET + 2

    expect.falsy(socket_path_report(health_reports(dir_of_length(length))).level == "error", "still fits on Linux")
    expect.eq(socket_path_report(health_reports(dir_of_length(length), "mac")).level, "error")
  end)

  it("reports the smaller budget on macOS", function()
    local report = socket_path_report(health_reports("/home/me/.ssh/sockets", "mac"))
    expect.contains(report.message, "of " .. MAC_BUDGET .. " characters")
  end)

  it("is reported even when ~/.ssh does not exist", function()
    -- The socket directory is configurable and need not live under ~/.ssh.
    stub.reload()

    local reports = {}
    local function record(level)
      return function(message, advice)
        table.insert(reports, { level = level, message = message, advice = advice })
      end
    end
    stub.set("health", {
      start = function() end,
      ok = record("ok"),
      info = record("info"),
      warn = record("warn"),
      error = record("error"),
    })
    stub.set("fn.has", function()
      return 0
    end)
    local real_isdirectory = vim.fn.isdirectory
    stub.set("fn.isdirectory", function(path)
      if path == vim.fn.expand("~/.ssh") then return 0 end
      return real_isdirectory(path)
    end)

    require("sshfs.config").setup({ connections = { socket_dir = dir_of_length(LINUX_BUDGET + 1) } })
    require("sshfs.health").check()
    stub.restore_all()

    local report = socket_path_report(reports)
    expect.truthy(report, "a missing ~/.ssh must not hide a broken socket path")
    expect.eq(report.level, "error")
  end)
end)
