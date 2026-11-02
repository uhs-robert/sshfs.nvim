-- tests/keepalive_spec.lua
-- Keepalive options on the SSH process that becomes the ControlMaster
--
-- sshfs mounts through the master socket, so only the master can notice a
-- dead network. Without keepalives it hangs after a drop and sshfs never
-- reconnects.

local SOCKET_DIR = "/home/tester/.ssh/sockets"

local function load_ssh(sshfs_options)
  stub.reload()
  require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR, sshfs_options = sshfs_options } })
  return require("sshfs.lib.ssh")
end

describe("master keepalives", function()
  it("adds the default keepalives to the batch master", function()
    local joined = table.concat(load_ssh().build_batch_command("example.com"), " ")

    expect.contains(joined, "ServerAliveInterval=15")
    expect.contains(joined, "ServerAliveCountMax=3")
  end)

  it("adds the keepalives to the interactive master", function()
    local joined = table.concat(load_ssh().build_auth_command("example.com"), " ")

    expect.contains(joined, "ServerAliveInterval=15")
    expect.contains(joined, "ServerAliveCountMax=3")
  end)

  it("follows the configured sshfs_options values", function()
    local joined = table.concat(load_ssh({ ServerAliveInterval = 30 }).build_batch_command("example.com"), " ")

    expect.contains(joined, "ServerAliveInterval=30")
  end)

  it("omits a keepalive the user disabled", function()
    local joined = table.concat(load_ssh({ ServerAliveInterval = false }).build_batch_command("example.com"), " ")

    expect.falsy(joined:find("ServerAliveInterval", 1, true))
  end)

  it("leaves socket clients alone because they ignore keepalives", function()
    local joined = table.concat(load_ssh().build_control_command("example.com", "check"), " ")

    expect.falsy(joined:find("ServerAlive", 1, true))
  end)
end)
