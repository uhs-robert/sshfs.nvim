-- tests/manual_host_spec.lua
-- Connecting to a host that is not in ssh_config, typed as `user@host`
--
-- A typed user or port cannot come from ssh_config, so it must outrank
-- whatever `ssh -G` reports for the same name.

--- Load SSHConfig against a faked `ssh -G`
--- @param resolved table|nil Key/value lines ssh -G reports, or nil to fail resolution
local function load_config(resolved)
  stub.reload()
  require("sshfs.config").setup({})

  stub.system(function()
    if not resolved then return "", 255 end

    local lines = {}
    for key, value in pairs(resolved) do
      table.insert(lines, key .. " " .. value)
    end
    table.sort(lines)
    return table.concat(lines, "\n") .. "\n", 0
  end)

  return require("sshfs.lib.ssh_config")
end

describe("SSHConfig.resolve_input", function()
  it("keeps a typed user over the one ssh -G reports", function()
    local SSHConfig = load_config({ user = "localuser", port = "22", hostname = "10.0.0.5" })

    local host = SSHConfig.resolve_input("remoteuser@10.0.0.5")
    stub.restore_all()

    expect.eq(host.user, "remoteuser", "the typed user is the whole point of typing it")
    expect.eq(host.name, "10.0.0.5")
  end)

  it("keeps a typed port over the resolved one", function()
    local SSHConfig = load_config({ user = "deploy", port = "22", hostname = "example.com" })

    local host = SSHConfig.resolve_input("example.com -p 2222")
    stub.restore_all()

    expect.eq(host.port, "2222")
  end)

  it("falls back to the resolved values when nothing is typed", function()
    local SSHConfig = load_config({ user = "deploy", port = "2222", hostname = "10.0.0.5" })

    local host = SSHConfig.resolve_input("alias")
    stub.restore_all()

    expect.eq(host.user, "deploy")
    expect.eq(host.port, "2222")
    expect.eq(host.hostname, "10.0.0.5", "an alias must still gain its resolved config")
  end)

  it("still returns a usable host when ssh -G cannot resolve it", function()
    local SSHConfig = load_config(nil)

    local host = SSHConfig.resolve_input("remoteuser@10.0.0.5")
    stub.restore_all()

    expect.truthy(host, "an unresolvable host must still be connectable")
    expect.eq(host.user, "remoteuser")
    expect.eq(host.name, "10.0.0.5")
  end)

  it("carries a typed remote path", function()
    local SSHConfig = load_config({ user = "deploy", port = "22", hostname = "example.com" })

    local host = SSHConfig.resolve_input("deploy@example.com:/srv/app")
    stub.restore_all()

    expect.eq(host.path, "/srv/app")
  end)

  it("returns nil for an empty input", function()
    local SSHConfig = load_config({ user = "deploy", port = "22" })

    expect.is_nil(SSHConfig.resolve_input(""))
    expect.is_nil(SSHConfig.resolve_input("   "))
    stub.restore_all()
  end)
end)

describe("manual host entry", function()
  it("prompts when ssh_config lists no hosts", function()
    load_config({ user = "deploy", port = "22", hostname = "10.0.0.5" })
    package.loaded["sshfs.lib.ssh_config"].get_hosts = function()
      return {}
    end

    local prompted = false
    stub.set("ui.input", function(_, on_input)
      prompted = true
      on_input("remoteuser@10.0.0.5")
    end)

    local selected
    require("sshfs.ui.select").host(function(host)
      selected = host
    end)
    stub.restore_all()

    expect.truthy(prompted, "an empty ssh_config must not be a dead end")
    expect.eq(selected.user, "remoteuser")
  end)

  it("offers a manual entry alongside the configured hosts", function()
    load_config({ user = "deploy", port = "22", hostname = "10.0.0.5" })
    package.loaded["sshfs.lib.ssh_config"].get_hosts = function()
      return { "alpha", "beta" }
    end

    local offered
    stub.set("ui.select", function(items)
      offered = items
    end)

    require("sshfs.ui.select").host(function() end)
    stub.restore_all()

    expect.eq(#offered, 3, "the two hosts plus a manual entry")
    expect.eq(offered[#offered], "Enter host manually...")
  end)

  it("prompts when the manual entry is chosen", function()
    load_config({ user = "deploy", port = "22", hostname = "10.0.0.5" })
    package.loaded["sshfs.lib.ssh_config"].get_hosts = function()
      return { "alpha" }
    end

    stub.set("ui.select", function(items, _, on_choice)
      on_choice(items[#items])
    end)
    stub.set("ui.input", function(_, on_input)
      on_input("remoteuser@10.0.0.5 -p 2222")
    end)

    local selected
    require("sshfs.ui.select").host(function(host)
      selected = host
    end)
    stub.restore_all()

    expect.truthy(selected, "choosing manual entry must reach the callback")
    expect.eq(selected.user, "remoteuser")
    expect.eq(selected.port, "2222")
  end)

  it("does nothing when the prompt is cancelled", function()
    load_config({ user = "deploy", port = "22" })
    package.loaded["sshfs.lib.ssh_config"].get_hosts = function()
      return {}
    end

    stub.set("ui.input", function(_, on_input)
      on_input(nil)
    end)

    local called = false
    require("sshfs.ui.select").host(function()
      called = true
    end)
    stub.restore_all()

    expect.eq(called, false, "cancelling must not connect anywhere")
  end)
end)
