-- tests/failed_mount_cleanup_spec.lua
-- Mount directory cleanup after a failed connection
--
-- A failed attempt must remove only a directory it created and left empty.
-- Anything else may belong to another Neovim process or hold real data.

local BASE_DIR = "/home/tester/mnt"
local MOUNT_DIR = BASE_DIR .. "/example_srv_app"

--- Drive Session.connect through a stubbed mount attempt
--- @param opts table {mount_created, mount_ready, is_active, is_empty, delete_fails, mount_succeeds}
--- @return table outcome {deleted, notifications, registered}
local function attempt_connection(opts)
  stub.reload()
  require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })

  package.loaded["sshfs.ui.ask"] = {
    for_mount_path = function(_, _, callback)
      callback("/srv/app")
    end,
  }

  package.loaded["sshfs.lib.mount_point"] = {
    is_active = function()
      return opts.is_active or false
    end,
    get_or_create = function()
      if opts.mount_ready == false then return false, false end
      return true, opts.mount_created ~= false
    end,
    cleanup = function() end,
  }

  package.loaded["sshfs.lib.directory"] = {
    is_empty = function()
      return opts.is_empty ~= false
    end,
  }

  local registered = {}
  package.loaded["sshfs.lib.lockfile"] = {
    register = function(dir)
      table.insert(registered, dir)
    end,
  }

  package.loaded["sshfs.ui.hooks"] = {
    on_mount = function() end,
  }

  package.loaded["sshfs.lib.sshfs"] = {
    authenticate_and_mount = function(_, _, remote_path_suffix, callback)
      if opts.mount_succeeds then
        callback({ success = true, resolved_path = remote_path_suffix })
      else
        callback({ success = false, message = "Mount failed (exit code: 1): permission denied" })
      end
    end,
  }

  local deleted = {}
  stub.set("fn.delete", function(path, flags)
    if opts.delete_fails then error("E739: could not delete " .. path) end
    table.insert(deleted, { path = path, flags = flags })
    return 0
  end)
  local notifications = stub.notifications()

  local ok, err = pcall(require("sshfs.session").connect, { name = "example" })
  stub.restore_all()

  return { deleted = deleted, notifications = notifications, registered = registered, ok = ok, err = err }
end

--- Whether the mount directory was removed
local function removed_mount_dir(outcome)
  for _, entry in ipairs(outcome.deleted) do
    if entry.path == MOUNT_DIR then return true end
  end
  return false
end

describe("failed connection cleanup", function()
  it("removes an empty directory the attempt created", function()
    local outcome = attempt_connection({ mount_created = true, is_empty = true })

    expect.truthy(removed_mount_dir(outcome))
    expect.eq(outcome.deleted[1].flags, "d", "only an empty directory is removed, never a tree")
  end)

  it("keeps a directory the attempt did not create", function()
    local outcome = attempt_connection({ mount_created = false, is_empty = true })

    expect.falsy(removed_mount_dir(outcome), "another process may own a directory that already existed")
  end)

  it("keeps a directory that is not empty", function()
    local outcome = attempt_connection({ mount_created = true, is_empty = false })

    expect.falsy(removed_mount_dir(outcome), "unexpected contents must not be deleted")
  end)

  it("keeps a directory that turns out to be an active mount", function()
    local outcome = attempt_connection({ mount_created = true, is_empty = true, is_active = true })

    expect.falsy(removed_mount_dir(outcome), "a live mount must never be removed by a failure path")
  end)

  it("reports the underlying failure to the user", function()
    local outcome = attempt_connection({ mount_created = true })

    expect.eq(#outcome.notifications, 1)
    expect.contains(outcome.notifications[1].message, "Connection failed")
    expect.contains(outcome.notifications[1].message, "permission denied")
    expect.eq(outcome.notifications[1].level, vim.log.levels.ERROR)
  end)

  it("does not let a cleanup error mask the connection error", function()
    local outcome = attempt_connection({ mount_created = true, is_empty = true, delete_fails = true })

    expect.truthy(outcome.ok, "cleanup is best-effort and must not raise out of the callback")
    expect.contains(outcome.notifications[1].message, "Connection failed")
  end)

  it("does not register a failed attempt in the lockfile", function()
    local outcome = attempt_connection({ mount_created = true })
    expect.eq(outcome.registered, {})
  end)

  it("reports a directory that could not be created without attempting a mount", function()
    local outcome = attempt_connection({ mount_ready = false })

    expect.eq(#outcome.notifications, 1)
    expect.contains(outcome.notifications[1].message, "Failed to create mount directory")
    expect.falsy(removed_mount_dir(outcome))
  end)
end)

describe("successful connection", function()
  it("keeps the mount directory and registers it", function()
    local outcome = attempt_connection({ mount_created = true, mount_succeeds = true })

    expect.falsy(removed_mount_dir(outcome))
    expect.eq(outcome.registered, { MOUNT_DIR })
  end)
end)
