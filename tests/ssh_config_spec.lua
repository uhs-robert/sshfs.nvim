-- tests/ssh_config_spec.lua
-- Ad-hoc host string parsing used by :SSHConnect and friends

local function load_ssh_config()
  stub.reload()
  return require("sshfs.lib.ssh_config")
end

describe("SSHConfig.parse_host", function()
  it("parses a bare host alias", function()
    local host = load_ssh_config().parse_host("production")

    expect.eq(host.name, "production")
    expect.is_nil(host.user)
    expect.is_nil(host.path)
    expect.is_nil(host.port)
  end)

  it("parses user@host", function()
    local host = load_ssh_config().parse_host("deploy@example.com")

    expect.eq(host.name, "example.com")
    expect.eq(host.user, "deploy")
    expect.is_nil(host.path)
  end)

  it("parses user@host:path", function()
    local host = load_ssh_config().parse_host("deploy@example.com:/srv/app")

    expect.eq(host.name, "example.com")
    expect.eq(host.user, "deploy")
    expect.eq(host.path, "/srv/app")
  end)

  it("parses host:path without a user", function()
    local host = load_ssh_config().parse_host("example.com:/srv/app")

    expect.eq(host.name, "example.com")
    expect.is_nil(host.user)
    expect.eq(host.path, "/srv/app")
  end)

  it("extracts an explicit port and keeps it out of the host name", function()
    local host = load_ssh_config().parse_host("deploy@example.com:/srv/app -p 2222")

    expect.eq(host.port, "2222")
    expect.eq(host.name, "example.com")
    expect.eq(host.path, "/srv/app")
  end)

  it("treats an empty path as absent", function()
    local host = load_ssh_config().parse_host("example.com:")
    expect.is_nil(host.path)
  end)
end)
