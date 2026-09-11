-- tests/remote_command_spec.lua
-- A `RemoteCommand` in ssh_config makes a mount impossible: OpenSSH refuses to
-- run both it and a command line, and sftp needs a plain session. Every
-- non-interactive path clears it; a bare terminal keeps it.

local SOCKET_DIR = "/home/tester/.ssh/sockets"

local function load_ssh()
  stub.reload()
  require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR, control_persist = "10m" } })
  return require("sshfs.lib.ssh")
end

--- Index of an "-o <value>" pair in a command list, or nil
local function option_index(cmd, value)
  for index, argument in ipairs(cmd) do
    if argument == "-o" and cmd[index + 1] == value then return index end
  end
  return nil
end

local function clears_remote_command(cmd)
  return option_index(cmd, "RemoteCommand=none") ~= nil
end

describe("RemoteCommand handling", function()
  it("clears it on every command that appends a remote command", function()
    local Ssh = load_ssh()

    expect.truthy(clears_remote_command(Ssh.build_batch_command("example.com")), "batch runs exit")
    expect.truthy(clears_remote_command(Ssh.build_home_command("example.com")), "home runs readlink")
    expect.truthy(clears_remote_command(Ssh.build_auth_command("example.com")), "auth runs exit")
  end)

  it("clears it for the ssh command sshfs runs", function()
    local Ssh = load_ssh()
    expect.contains(Ssh.build_command_string("socket"), "-o RemoteCommand=none")
  end)

  it("clears it on the control command", function()
    local Ssh = load_ssh()
    expect.truthy(clears_remote_command(Ssh.build_control_command("example.com", "exit")))
  end)

  it("clears it for a terminal that cds into a remote path", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com", "/srv/app")

    expect.truthy(clears_remote_command(cmd), "the cd would collide with a RemoteCommand")
    expect.truthy(option_index(cmd, "RemoteCommand=none") < #cmd, "options must precede the host")
  end)

  it("keeps it for a bare terminal session", function()
    local Ssh = load_ssh()
    local cmd = Ssh.build_command("example.com")

    expect.is_nil(option_index(cmd, "RemoteCommand=none"), "a plain shell is what RemoteCommand is for")
  end)
end)
