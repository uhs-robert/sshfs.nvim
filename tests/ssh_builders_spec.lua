-- tests/ssh_builders_spec.lua
-- Shared SSH command builders used by both SSHConnect and SSHTest
--
-- SSHTest is only trustworthy if it runs the same commands the real connection
-- path runs, so these cover the builders both sides share.

local SOCKET_DIR = "/home/tester/.ssh/sockets"

local function load_ssh()
  stub.reload()
  require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR, control_persist = "10m" } })
  return require("sshfs.lib.ssh")
end

--- Position of a value in a command list, or nil
local function index_of(cmd, value)
  for index, argument in ipairs(cmd) do
    if argument == value then return index end
  end
  return nil
end

describe("Ssh.build_batch_command", function()
  it("forces a master, disables prompts, and only tests the connection", function()
    local cmd = load_ssh().build_batch_command("example.com")
    local joined = table.concat(cmd, " ")

    expect.contains(joined, "ControlMaster=yes")
    expect.contains(joined, "BatchMode=yes")
    expect.contains(joined, "ControlPath=" .. SOCKET_DIR .. "/%C")
    expect.eq(cmd[#cmd], "exit", "the batch probe must not start a shell")
  end)

  it("accepts a plain host name", function()
    local cmd = load_ssh().build_batch_command("example.com")
    expect.eq(cmd[#cmd - 1], "example.com")
  end)

  it("propagates an explicit user and port from a host object", function()
    local cmd = load_ssh().build_batch_command({ name = "example.com", user = "deploy", port = 2222 })

    expect.eq(cmd[index_of(cmd, "-l") + 1], "deploy")
    expect.eq(cmd[index_of(cmd, "-p") + 1], "2222", "the port must be passed as a string")
    expect.eq(cmd[#cmd - 1], "example.com")
  end)

  it("omits user and port when the host object does not set them", function()
    local cmd = load_ssh().build_batch_command({ name = "example.com" })

    expect.is_nil(index_of(cmd, "-l"))
    expect.is_nil(index_of(cmd, "-p"))
  end)
end)

describe("Ssh.build_home_command", function()
  it("reuses the existing socket without renegotiating a master", function()
    local cmd = load_ssh().build_home_command("example.com")
    local joined = table.concat(cmd, " ")

    expect.contains(joined, "ControlPath=" .. SOCKET_DIR .. "/%C")
    expect.falsy(joined:find("ControlMaster", 1, true), "resolving the home directory must reuse the socket")
  end)

  it("resolves the canonical home directory with a fallback", function()
    local cmd = load_ssh().build_home_command("example.com")
    expect.eq(cmd[#cmd], "readlink -f $HOME 2>/dev/null || echo $HOME")
  end)

  it("propagates an explicit user and port", function()
    local cmd = load_ssh().build_home_command({ name = "example.com", user = "deploy", port = 2222 })

    expect.eq(cmd[index_of(cmd, "-l") + 1], "deploy")
    expect.eq(cmd[index_of(cmd, "-p") + 1], "2222")
  end)
end)

describe("Ssh.build_auth_command", function()
  it("forces a master so interactive authentication creates the socket", function()
    local cmd = load_ssh().build_auth_command("example.com")
    local joined = table.concat(cmd, " ")

    expect.contains(joined, "ControlMaster=yes")
    expect.falsy(joined:find("BatchMode", 1, true), "interactive authentication must be able to prompt")
    expect.eq(cmd[#cmd], "exit")
  end)
end)

describe("Ssh.build_control_command", function()
  it("addresses the socket for a control operation", function()
    local cmd = load_ssh().build_control_command("example.com", "check")

    expect.contains(table.concat(cmd, " "), "ControlPath=" .. SOCKET_DIR .. "/%C")
    expect.eq(cmd[index_of(cmd, "-O") + 1], "check")
    expect.eq(cmd[#cmd], "example.com")
  end)

  it("builds the exit operation used for cleanup", function()
    local cmd = load_ssh().build_control_command({ name = "example.com", port = 2222 }, "exit")

    expect.eq(cmd[index_of(cmd, "-O") + 1], "exit")
    expect.eq(cmd[index_of(cmd, "-p") + 1], "2222")
  end)
end)

describe("Ssh.control_master_pid", function()
  it("returns the pid reported by a running master", function()
    local Ssh = load_ssh()
    stub.system(function()
      return "Master running (pid=4242)\r\n", 0
    end)

    local pid = Ssh.control_master_pid("example.com")
    stub.restore_all()

    expect.eq(pid, 4242)
  end)

  it("returns nil when no master is running", function()
    local Ssh = load_ssh()
    stub.system(function()
      return "Control socket connect(/home/tester/.ssh/sockets/abc): No such file or directory", 255
    end)

    local pid = Ssh.control_master_pid("example.com")
    stub.restore_all()

    expect.is_nil(pid)
  end)

  it("returns nil when the check succeeds without a parseable pid", function()
    local Ssh = load_ssh()
    stub.system(function()
      return "unexpected output", 0
    end)

    local pid = Ssh.control_master_pid("example.com")
    stub.restore_all()

    expect.is_nil(pid)
  end)
end)

describe("Ssh.get_remote_home", function()
  it("accepts a host object and reports the resolved home", function()
    local Ssh = load_ssh()
    stub.set("schedule", function(fn)
      fn()
    end)
    stub.set("system", function(_, _, callback)
      callback({ code = 0, stdout = "/home/deploy\n", stderr = "" })
      return { wait = function() end }
    end)

    local home, err = nil, nil
    Ssh.get_remote_home({ name = "example.com", user = "deploy" }, function(resolved, error_message)
      home, err = resolved, error_message
    end)
    stub.restore_all()

    expect.eq(home, "/home/deploy")
    expect.is_nil(err)
  end)

  it("rejects output that is not an absolute path", function()
    local Ssh = load_ssh()
    stub.set("schedule", function(fn)
      fn()
    end)
    stub.set("system", function(_, _, callback)
      callback({ code = 0, stdout = "not-a-path", stderr = "" })
      return { wait = function() end }
    end)

    local home, err = nil, nil
    Ssh.get_remote_home("example.com", function(resolved, error_message)
      home, err = resolved, error_message
    end)
    stub.restore_all()

    expect.is_nil(home)
    expect.contains(err, "invalid")
  end)
end)
