-- tests/host_targeting_spec.lua
-- The mount path passes whole host objects to the SSH builders, so every
-- command carries an explicit -l/-p. These lock those flags to the values
-- `ssh -G` resolves, so the plugin can never target a different account or
-- port than plain `ssh <alias>` would.

local SOCKET_DIR = "/home/tester/.ssh/sockets"

--- Resolve a host through the real SSHConfig parser against a faked `ssh -G`
--- @param resolved table Lines `ssh -G` should report, as key/value pairs
--- @return table host
local function host_from_config(resolved)
  stub.reload()
  require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR } })

  local lines = {}
  for key, value in pairs(resolved) do
    table.insert(lines, key .. " " .. value)
  end
  table.sort(lines)

  stub.system(function()
    return table.concat(lines, "\n") .. "\n", 0
  end)

  local host = require("sshfs.lib.ssh_config").get_host_config("alias")
  stub.restore_all()
  return host
end

--- Value following a flag in a command list, or nil
local function flag_value(cmd, flag)
  for index, argument in ipairs(cmd) do
    if argument == flag then return cmd[index + 1] end
  end
  return nil
end

describe("resolved host targeting", function()
  it("carries the user and port ssh -G reports", function()
    local host = host_from_config({ user = "deploy", port = "2222", hostname = "10.0.0.5" })
    local Ssh = require("sshfs.lib.ssh")

    for _, cmd in ipairs({
      Ssh.build_batch_command(host),
      Ssh.build_home_command(host),
      Ssh.build_auth_command(host),
      Ssh.build_control_command(host, "exit"),
    }) do
      expect.eq(flag_value(cmd, "-l"), "deploy")
      expect.eq(flag_value(cmd, "-p"), "2222")
    end
  end)

  it("keeps a wildcard-inherited user, since ssh -G already applied it", function()
    -- `Host *` defaults arrive resolved, so the explicit -l matches what plain ssh uses.
    local host = host_from_config({ user = "shared", port = "22", hostname = "alias" })
    local cmd = require("sshfs.lib.ssh").build_batch_command(host)

    expect.eq(flag_value(cmd, "-l"), "shared")
  end)

  it("still targets the alias, not the resolved hostname", function()
    local host = host_from_config({ user = "deploy", port = "22", hostname = "10.0.0.5" })
    local cmd = require("sshfs.lib.ssh").build_batch_command(host)

    expect.eq(cmd[#cmd - 1], "alias", "ssh must re-resolve the alias so Match blocks still apply")
  end)
end)

describe("manually entered host targeting", function()
  it("carries a user and port typed as user@host -p", function()
    stub.reload()
    require("sshfs.config").setup({ connections = { socket_dir = SOCKET_DIR } })

    local host = require("sshfs.lib.ssh_config").parse_host("deploy@example.com -p 2222")
    local cmd = require("sshfs.lib.ssh").build_batch_command(host)
    stub.restore_all()

    expect.eq(flag_value(cmd, "-l"), "deploy", "a typed user is not in ssh_config, so it must be passed")
    expect.eq(flag_value(cmd, "-p"), "2222", "a typed port is not in ssh_config, so it must be passed")
  end)
end)
