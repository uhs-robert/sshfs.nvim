-- tests/metadata_fallback_spec.lua
-- Behavior when a mount exposes no remote host/path metadata (fuse-t)
--
-- Operations with a mounted-filesystem equivalent fall back to the mount path.
-- Operations that genuinely need a remote host refuse instead of guessing.

local MOUNT_PATH = "/Users/tester/mnt/host"

--- Record which picker entry points get called
--- @return table calls
local function fake_picker()
  local calls = {}
  package.loaded["sshfs.ui.picker"] = {
    open_live_remote_grep = function()
      table.insert(calls, "live_grep")
      return true, "telescope"
    end,
    open_live_remote_find = function()
      table.insert(calls, "live_find")
      return true, "telescope"
    end,
    grep_remote_files = function()
      table.insert(calls, "local_grep")
    end,
    open_file_picker = function()
      table.insert(calls, "local_find")
      return true, "telescope"
    end,
  }
  return calls
end

--- Present a single active mount to the modules under test
--- @param mount table Mount object returned by MountPoint.list_active
local function fake_single_mount(mount)
  package.loaded["sshfs.lib.mount_point"] = {
    list_active = function()
      return { mount }
    end,
    get_active = function()
      return mount
    end,
    has_active = function()
      return true
    end,
  }
end

local FUSE_T_MOUNT = {
  host = "host",
  mount_path = MOUNT_PATH,
  remote_path = nil,
  remote_metadata_available = false,
}

local SSHFS_MOUNT = {
  host = "example.com",
  mount_path = MOUNT_PATH,
  remote_path = "/srv/app",
  remote_metadata_available = true,
}

local function setup(mount)
  stub.reload()
  require("sshfs.config").setup({})
  fake_single_mount(mount)
  local calls = fake_picker()
  local notifications = stub.notifications()
  return calls, notifications
end

describe("live grep without remote metadata", function()
  it("falls back to grepping the mounted path", function()
    local calls, notifications = setup(FUSE_T_MOUNT)

    require("sshfs.api").live_grep()
    stub.restore_all()

    expect.eq(calls, { "local_grep" }, "remote grep needs a real host and must not be attempted")
    expect.contains(notifications[1].message, "metadata is unavailable")
  end)

  it("still greps remotely when metadata is available", function()
    local calls = setup(SSHFS_MOUNT)

    require("sshfs.api").live_grep()
    stub.restore_all()

    expect.eq(calls, { "live_grep" })
  end)
end)

describe("live find without remote metadata", function()
  it("falls back to the mounted path", function()
    local calls, notifications = setup(FUSE_T_MOUNT)

    require("sshfs.api").live_find()
    stub.restore_all()

    expect.eq(calls, { "local_find" })
    expect.contains(notifications[1].message, "metadata is unavailable")
  end)

  it("still finds remotely when metadata is available", function()
    local calls = setup(SSHFS_MOUNT)

    require("sshfs.api").live_find()
    stub.restore_all()

    expect.eq(calls, { "live_find" })
  end)
end)

describe("on_mount auto_run without remote metadata", function()
  --- Run the post-mount hook for a preset against a given mount
  local function run_auto_run(mount, auto_run)
    local calls, notifications = setup(mount)
    stub.set("cmd", function() end)

    require("sshfs.ui.hooks").on_mount(mount.mount_path, mount.host, mount.remote_path, {
      hooks = { on_mount = { auto_run = auto_run, auto_change_to_dir = false } },
    })
    stub.restore_all()

    return calls, notifications
  end

  it("falls back to local grep for live_grep", function()
    local calls, notifications = run_auto_run(FUSE_T_MOUNT, "live_grep")

    expect.eq(calls, { "local_grep" })
    expect.contains(notifications[1].message, "metadata is unavailable")
  end)

  it("falls back to local find for live_find", function()
    local calls, notifications = run_auto_run(FUSE_T_MOUNT, "live_find")

    expect.eq(calls, { "local_find" })
    expect.contains(notifications[1].message, "metadata is unavailable")
  end)

  it("runs the remote action when metadata is available", function()
    local calls = run_auto_run(SSHFS_MOUNT, "live_grep")
    expect.eq(calls, { "live_grep" })
  end)
end)

describe("SSH terminal without remote metadata", function()
  --- @return table opened Hosts an SSH terminal was opened for
  --- @return table notifications Captured vim.notify calls
  local function open_terminal_for(mount)
    stub.reload()
    require("sshfs.config").setup({})
    fake_single_mount(mount)

    local opened = {}
    package.loaded["sshfs.lib.ssh"] = {
      open_terminal = function(host, remote_path)
        table.insert(opened, { host = host, remote_path = remote_path })
      end,
    }
    local notifications = stub.notifications()

    require("sshfs.ui.terminal").open_ssh()
    stub.restore_all()

    return opened, notifications
  end

  it("refuses cleanly instead of using the display-only fallback host", function()
    local opened, notifications = open_terminal_for(FUSE_T_MOUNT)

    expect.eq(opened, {}, "the mount directory name is not a routable SSH host")
    expect.eq(#notifications, 1)
    expect.contains(notifications[1].message, "metadata is unavailable")
  end)

  it("opens a terminal when the remote host is known", function()
    local opened = open_terminal_for(SSHFS_MOUNT)

    expect.eq(#opened, 1)
    expect.eq(opened[1].host, "example.com")
    expect.eq(opened[1].remote_path, "/srv/app")
  end)
end)
