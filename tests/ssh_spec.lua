-- tests/ssh_spec.lua
-- SSH command construction

local SOCKET_DIR = "/home/tester/.ssh/sockets"
local CONTROL_PATH = "ControlPath=" .. SOCKET_DIR .. "/%C"

local function load_ssh()
  stub.reload()
  require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR, control_persist = "10m" } })
  return require("sshfs.lib.ssh")
end

describe("Ssh.build_command_string", function()
  it("passes only the control path when reusing a socket", function()
    local Ssh = load_ssh()
    expect.eq(Ssh.build_command_string("socket"), "ssh -o " .. CONTROL_PATH)
  end)

  it("forces a master and disables prompts for batch connections", function()
    local Ssh = load_ssh()
    local command = Ssh.build_command_string("batch")

    expect.contains(command, "ControlMaster=yes")
    expect.contains(command, CONTROL_PATH)
    expect.contains(command, "BatchMode=yes")
  end)

  it("uses an automatic master for interactive sessions", function()
    local Ssh = load_ssh()
    local command = Ssh.build_command_string(nil)

    expect.contains(command, "ControlMaster=auto")
    expect.contains(command, "ControlPersist=10m")
    expect.falsy(command:find("BatchMode", 1, true), "interactive sessions must stay interactive")
  end)
end)

describe("Ssh.build_command", function()
  it("returns a command list rather than a shell string", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", nil)

    expect.eq(cmd[1], "ssh")
    expect.eq(cmd[#cmd], "example.com")
  end)

  it("requests a tty and a login shell when a remote path is given", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", "/srv/app")

    expect.eq(cmd[#cmd - 1], "-t")
    expect.eq(cmd[#cmd], "cd '/srv/app' && exec $SHELL -l")
  end)

  it("expands a bare tilde through the remote shell", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", "~")
    expect.eq(cmd[#cmd], "cd ~ && exec $SHELL -l")
  end)

  it("expands the home prefix while quoting the remainder", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", "~/projects/app")
    expect.eq(cmd[#cmd], "cd ~ && cd 'projects/app' && exec $SHELL -l")
  end)

  it("escapes single quotes in remote paths", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", "/srv/it's here")

    expect.contains(cmd[#cmd], "'/srv/it'\\''s here'")
  end)
end)

describe("Ssh.cleanup_control_master", function()
  it("sends an exit control command for the host", function()
    local Ssh = load_ssh()
    local received = nil
    stub.system(function(cmd)
      received = cmd
      return ""
    end)

    Ssh.cleanup_control_master("example.com")
    stub.restore_all()

    expect.eq(received[1], "ssh")
    expect.eq(received[#received], "example.com")
    expect.eq(received[#received - 2], "-O")
    expect.eq(received[#received - 1], "exit")
  end)
end)
