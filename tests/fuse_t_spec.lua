-- tests/fuse_t_spec.lua
-- Regression coverage for fuse-t compatibility on macOS
--
-- fuse-t exposes SSHFS mounts through NFS, so the mount table carries no
-- remote spec and the installed sshfs is a 2.x implementation with different
-- directory-cache option names.

local BASE_DIR = "/Users/tester/mnt"

local FUSE_T_MOUNT = "fuse-t:/sshfs_nvim_mount on " .. BASE_DIR .. "/host (nfs, nodev, nosuid, mounted by tester)"

--- Load MountPoint against a stubbed mount table
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

describe("fuse-t mount detection", function()
  it("parses a fuse-t NFS-backed mount line", function()
    local MountPoint = with_mounts({ mount_output = FUSE_T_MOUNT })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 1)
    expect.eq(mounts[1].mount_path, BASE_DIR .. "/host")
    stub.restore_all()
  end)

  it("reports fuse-t mounts as lacking remote metadata", function()
    local MountPoint = with_mounts({ mount_output = FUSE_T_MOUNT })

    local mount = MountPoint.list_active()[1]
    expect.eq(mount.remote_metadata_available, false)
    stub.restore_all()
  end)

  it("does not invent an authoritative remote path", function()
    local MountPoint = with_mounts({ mount_output = FUSE_T_MOUNT })

    local mount = MountPoint.list_active()[1]
    expect.is_nil(mount.remote_path, "an unknown remote path must stay unknown, not default to /")
    stub.restore_all()
  end)

  it("falls back to the mount directory name for display", function()
    local MountPoint = with_mounts({ mount_output = FUSE_T_MOUNT })

    local mount = MountPoint.list_active()[1]
    expect.eq(mount.host, "host")
    expect.eq(MountPoint.format_label(mount), "host", "no remote path means no path suffix in the label")
    stub.restore_all()
  end)

  it("does not error on a mount without a remote spec", function()
    local MountPoint = with_mounts({ mount_output = FUSE_T_MOUNT })

    expect.no_error(function()
      MountPoint.list_active()
    end)
    stub.restore_all()
  end)

  it("detects fuse-t mounts through findmnt as well as mount", function()
    local MountPoint = with_mounts({
      findmnt_available = true,
      findmnt_output = "fuse-t:/sshfs_nvim_mount nfs " .. BASE_DIR .. "/host\n",
    })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 1, "findmnt must not short-circuit past fuse-t mounts")
    expect.eq(mounts[1].mount_path, BASE_DIR .. "/host")
    expect.eq(mounts[1].remote_metadata_available, false)
    stub.restore_all()
  end)

  it("keeps unrelated NFS mounts out of the results", function()
    local MountPoint = with_mounts({
      findmnt_available = true,
      findmnt_output = table.concat({
        "nfsserver:/export nfs " .. BASE_DIR .. "/company-share",
        "fuse-t:/sshfs_nvim_mount nfs " .. BASE_DIR .. "/host",
      }, "\n"),
    })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 1, "a real NFS mount under the base directory is not an SSHFS mount")
    expect.eq(mounts[1].mount_path, BASE_DIR .. "/host")
    stub.restore_all()
  end)

  it("still reports remote metadata for a real sshfs mount alongside fuse-t", function()
    local MountPoint = with_mounts({
      mount_output = table.concat({
        FUSE_T_MOUNT,
        "deploy@example.com:/srv/app on " .. BASE_DIR .. "/example type fuse.sshfs (rw)",
      }, "\n"),
    })

    local mounts = MountPoint.list_active()
    expect.eq(#mounts, 2)
    expect.eq(mounts[1].remote_metadata_available, false)
    expect.eq(mounts[2].remote_metadata_available, true)
    expect.eq(mounts[2].remote_path, "/srv/app")
    stub.restore_all()
  end)
end)
