-- tests/unresponsive_mount_spec.lua
-- Reconnecting to a mount that died with the network
--
-- After a network drop the mount table still lists the mount, but it no longer
-- answers. Connecting again must replace it instead of reporting it as mounted.

local BASE_DIR = "/home/tester/mnt"
local MOUNT_DIR = BASE_DIR .. "/example_srv_app"

--- Drive Session.connect against a mount that is already in the mount table
--- @param opts table {responsive, unmount_succeeds}
--- @return table outcome {unmounted, masters_closed, mount_attempts, notifications}
local function connect_over_existing_mount(opts)
  stub.reload()
  require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })

  package.loaded["sshfs.ui.ask"] = {
    for_mount_path = function(_, _, callback)
      callback("/srv/app")
    end,
  }

  local unmounted = {}
  package.loaded["sshfs.lib.mount_point"] = {
    is_active = function()
      return true
    end,
    is_responsive = function()
      return opts.responsive
    end,
    unmount = function(path)
      table.insert(unmounted, path)
      return opts.unmount_succeeds ~= false
    end,
    get_or_create = function()
      return true, true
    end,
  }

  local masters_closed = {}
  package.loaded["sshfs.lib.ssh"] = {
    cleanup_control_master = function(host)
      table.insert(masters_closed, host.name)
      return true
    end,
  }

  package.loaded["sshfs.lib.lockfile"] = { register = function() end }
  package.loaded["sshfs.lib.git_route"] = { register_mount = function() end }
  package.loaded["sshfs.ui.hooks"] = { on_mount = function() end }

  local mount_attempts = {}
  package.loaded["sshfs.lib.sshfs"] = {
    authenticate_and_mount = function(_, mount_dir, remote_path_suffix, callback)
      table.insert(mount_attempts, mount_dir)
      callback({ success = true, resolved_path = remote_path_suffix })
    end,
  }

  local notifications = stub.notifications()
  require("sshfs.session").connect({ name = "example" })
  stub.restore_all()

  return {
    unmounted = unmounted,
    masters_closed = masters_closed,
    mount_attempts = mount_attempts,
    notifications = notifications,
  }
end

describe("connecting to an existing mount", function()
  it("keeps a responsive mount and reports it as mounted", function()
    local outcome = connect_over_existing_mount({ responsive = true })

    expect.eq(outcome.unmounted, {})
    expect.eq(outcome.mount_attempts, {})
    expect.contains(outcome.notifications[1].message, "already mounted")
  end)

  it("replaces a mount that stopped responding", function()
    local outcome = connect_over_existing_mount({ responsive = false })

    expect.eq(outcome.unmounted, { MOUNT_DIR })
    expect.eq(outcome.masters_closed, { "example" }, "a hung master hangs the new mount")
    expect.eq(outcome.mount_attempts, { MOUNT_DIR })
    expect.contains(outcome.notifications[1].message, "not responding")
  end)

  it("stops when the dead mount cannot be unmounted", function()
    local outcome = connect_over_existing_mount({ responsive = false, unmount_succeeds = false })

    expect.eq(outcome.mount_attempts, {})
    expect.eq(outcome.notifications[#outcome.notifications].level, vim.log.levels.ERROR)
  end)
end)

describe("MountPoint.is_responsive", function()
  local function probe(result)
    stub.reload()
    require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })
    local calls = stub.vim_system(function()
      return result
    end)
    local responsive = require("sshfs.lib.mount_point").is_responsive(MOUNT_DIR)
    stub.restore_all()
    return responsive, calls
  end

  it("looks up a random name so the sshfs cache cannot answer", function()
    local _, calls = probe({ code = 1, stderr = "No such file or directory" })
    local _, second_calls = probe({ code = 1, stderr = "No such file or directory" })

    local probe_path = calls[1][#calls[1]]
    expect.eq(probe_path:sub(1, #MOUNT_DIR + 1), MOUNT_DIR .. "/")
    expect.truthy(probe_path ~= second_calls[1][#second_calls[1]], "each probe must use a new name")
  end)

  it("counts a missing file as an answer from the server", function()
    expect.truthy((probe({ code = 1, stderr = "stat: cannot statx 'x': No such file or directory" })))
  end)

  it("counts a denied permission as an answer from the server", function()
    expect.truthy((probe({ code = 1, stderr = "stat: cannot statx 'x': Permission denied" })))
  end)

  it("reports a disconnected mount as unresponsive", function()
    expect.falsy((probe({ code = 1, stderr = "stat: cannot statx 'x': Transport endpoint is not connected" })))
    expect.falsy((probe({ code = 1, stderr = "stat: cannot statx 'x': Input/output error" })))
  end)

  it("reports a timed-out lookup as unresponsive", function()
    expect.falsy((probe({ code = 124 })))
  end)

  it("reports a macFUSE dead mount as unresponsive", function()
    expect.falsy((probe({ code = 1, stderr = "stat: x: stat: Device not configured" })))
  end)

  it("reports a probe that survives the kill as unresponsive", function()
    stub.reload()
    require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })
    stub.set("system", function()
      return {
        wait = function()
          return nil
        end,
      }
    end)
    local responsive = require("sshfs.lib.mount_point").is_responsive(MOUNT_DIR)
    stub.restore_all()

    expect.falsy(responsive)
  end)

  it("keeps a mount whose probe failed for an unknown reason", function()
    expect.truthy((probe({ code = 1, stderr = "stat: something unexpected" })), "an unclear result must not unmount")
  end)
end)
