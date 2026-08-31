-- tests/config_spec.lua
-- Configuration merging, accessors, and deprecation shims

local function load_config(user_config)
  stub.reload()
  local Config = require("sshfs.config")
  Config.setup(user_config)
  return Config
end

describe("Config.setup", function()
  it("keeps defaults the user did not override", function()
    local Config = load_config({ mounts = { base_dir = "/custom/mnt" } })
    local opts = Config.get()

    expect.eq(opts.mounts.base_dir, "/custom/mnt")
    expect.eq(opts.connections.sshfs_options.reconnect, true)
    expect.eq(opts.connections.sshfs_options.ConnectTimeout, 5)
  end)

  it("merges nested tables instead of replacing them", function()
    local Config = load_config({ connections = { sshfs_options = { ConnectTimeout = 30 } } })
    local options = Config.get().connections.sshfs_options

    expect.eq(options.ConnectTimeout, 30, "the overridden value wins")
    expect.eq(options.compression, "yes", "sibling defaults survive the merge")
  end)

  it("accepts no user configuration at all", function()
    local Config = load_config(nil)
    expect.truthy(Config.get().mounts.base_dir)
  end)
end)

describe("Config accessors", function()
  it("returns the configured mount base directory", function()
    local Config = load_config({ mounts = { base_dir = "/custom/mnt" } })
    expect.eq(Config.get_base_dir(), "/custom/mnt")
  end)

  it("returns the configured socket directory", function()
    local Config = load_config({ connections = { socket_dir = "/custom/sockets" } })
    expect.eq(Config.get_socket_dir(), "/custom/sockets")
  end)

  it("builds ControlMaster options from the socket directory and persist window", function()
    local Config = load_config({ connections = { socket_dir = "/custom/sockets", control_persist = "5m" } })

    expect.eq(Config.get_control_master_options(), {
      "ControlMaster=auto",
      "ControlPath=/custom/sockets/%C",
      "ControlPersist=5m",
    })
  end)
end)

describe("Config deprecations", function()
  it("maps ui.file_picker onto ui.local_picker and warns", function()
    stub.reload()
    local notifications = stub.notifications()
    local Config = require("sshfs.config")
    Config.setup({ ui = { file_picker = { preferred_picker = "telescope" } } })
    stub.restore_all()

    expect.eq(Config.get().ui.local_picker.preferred_picker, "telescope")
    expect.eq(#notifications, 1)
    expect.contains(notifications[1].message, "ui.file_picker")
  end)

  it("maps mounts.unmount_on_exit onto hooks.on_exit.auto_unmount", function()
    stub.reload()
    stub.notifications()
    local Config = require("sshfs.config")
    Config.setup({ mounts = { unmount_on_exit = true } })
    stub.restore_all()

    expect.eq(Config.get().hooks.on_exit.auto_unmount, true)
  end)

  it("maps mounts.auto_change_dir_on_mount onto hooks.on_mount.auto_change_to_dir", function()
    stub.reload()
    stub.notifications()
    local Config = require("sshfs.config")
    Config.setup({ mounts = { auto_change_dir_on_mount = false } })
    stub.restore_all()

    expect.eq(Config.get().hooks.on_mount.auto_change_to_dir, false)
  end)

  it("stays quiet when no deprecated key is used", function()
    stub.reload()
    local notifications = stub.notifications()
    require("sshfs.config").setup({ mounts = { base_dir = "/custom/mnt" } })
    stub.restore_all()

    expect.eq(#notifications, 0)
  end)
end)
