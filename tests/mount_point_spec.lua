-- tests/mount_point_spec.lua
-- Mount table parsing and mount directory handling

local BASE_DIR = "/home/tester/mnt"

--- Load MountPoint with a known base directory and a stubbed system mount table
--- @param opts table {mount_output, findmnt_output, findmnt_available}
local function with_mounts(opts)
  stub.reload()
  require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })

  stub.executable({ findmnt = opts.findmnt_available or false })
  stub.system(function(cmd)
    if type(cmd) == "table" and cmd[1] == "findmnt" then return opts.findmnt_output or "", opts.findmnt_code or 0 end
    return opts.mount_output or "", 0
  end)

  return require("sshfs.lib.mount_point")
end

describe("MountPoint.list_active", function()
  it("parses Linux fuse.sshfs mount output", function()
    local MountPoint = with_mounts({
      mount_output = table.concat({
        "proc on /proc type proc (rw,nosuid)",
        "deploy@example.com:/srv/app on " .. BASE_DIR .. "/example type fuse.sshfs (rw,nosuid,nodev)",
      }, "\n"),
    })

    expect.eq(MountPoint.list_active(), {
      {
        host = "example.com",
        mount_path = BASE_DIR .. "/example",
        remote_path = "/srv/app",
        remote_metadata_available = true,
      },
    })
    stub.restore_all()
  end)

  it("parses macFUSE mount output", function()
    local MountPoint = with_mounts({
      mount_output = "deploy@example.com:/srv/app on " .. BASE_DIR .. "/example (macfuse, nodev, nosuid)",
    })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 1)
    expect.eq(mounts[1].host, "example.com")
    expect.eq(mounts[1].remote_path, "/srv/app")
    stub.restore_all()
  end)

  it("parses a remote spec without a user", function()
    local MountPoint = with_mounts({
      mount_output = "example.com:/srv/app on " .. BASE_DIR .. "/example type fuse.sshfs (rw)",
    })

    local mounts = MountPoint.list_active()
    expect.eq(mounts[1].host, "example.com")
    expect.eq(mounts[1].remote_path, "/srv/app")
    stub.restore_all()
  end)

  it("prefers findmnt output when findmnt is available", function()
    local MountPoint = with_mounts({
      findmnt_available = true,
      findmnt_output = "deploy@example.com:/srv/app fuse.sshfs " .. BASE_DIR .. "/example\n",
      mount_output = "should-not-be-read on /elsewhere type fuse.sshfs (rw)",
    })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 1)
    expect.eq(mounts[1].mount_path, BASE_DIR .. "/example")
    stub.restore_all()
  end)

  it("ignores mounts outside the configured base directory", function()
    local MountPoint = with_mounts({
      mount_output = "deploy@example.com:/srv/app on /somewhere/else type fuse.sshfs (rw)",
    })

    expect.eq(MountPoint.list_active(), {})
    stub.restore_all()
  end)

  it("ignores non-sshfs mount lines", function()
    local MountPoint = with_mounts({
      mount_output = table.concat({
        "tmpfs on " .. BASE_DIR .. "/tmp type tmpfs (rw)",
        "/dev/sda1 on " .. BASE_DIR .. "/disk type ext4 (rw)",
      }, "\n"),
    })

    expect.eq(MountPoint.list_active(), {})
    stub.restore_all()
  end)

  it("returns no mounts when the mount command fails", function()
    stub.reload()
    require("sshfs.config").setup({ mounts = { base_dir = BASE_DIR } })
    stub.executable({})
    stub.system(function()
      return "", 1
    end)

    expect.eq(require("sshfs.lib.mount_point").list_active(), {})
    stub.restore_all()
  end)
end)

describe("MountPoint.format_label", function()
  it("includes the remote path when it is meaningful", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    expect.eq(MountPoint.format_label({ host = "example.com", remote_path = "/srv/app" }), "example.com: /srv/app")
  end)

  it("omits the remote path for root and empty paths", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    expect.eq(MountPoint.format_label({ host = "example.com", remote_path = "/" }), "example.com")
    expect.eq(MountPoint.format_label({ host = "example.com", remote_path = "" }), "example.com")
    expect.eq(MountPoint.format_label({ host = "example.com" }), "example.com")
  end)
end)

describe("MountPoint.get_or_create", function()
  it("reports success for a directory that already exists", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")

    expect.truthy(MountPoint.get_or_create(temp_dir))
    vim.fn.delete(temp_dir, "rf")
  end)

  it("creates a missing directory", function()
    stub.reload()
    local MountPoint = require("sshfs.lib.mount_point")
    local temp_dir = vim.fn.tempname() .. "/nested/mount"

    expect.truthy(MountPoint.get_or_create(temp_dir))
    expect.eq(vim.fn.isdirectory(temp_dir), 1)
    vim.fn.delete(vim.fn.fnamemodify(temp_dir, ":h:h"), "rf")
  end)
end)
