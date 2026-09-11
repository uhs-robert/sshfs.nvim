-- tests/cleanup_stale_spec.lua
-- Startup sweep of leftover mount directories
--
-- setup() runs this, so it must not shell out through the unmount escalation
-- for a directory that is merely empty.

--- Build a base dir holding one empty directory, and load MountPoint against it
--- @return table MountPoint, string base_dir, table unmount_attempts
local function sweep_with(opts)
  stub.reload()
  local base_dir = vim.fn.tempname()
  vim.fn.mkdir(base_dir .. "/leftover", "p")
  require("sshfs.config").setup({ mounts = { base_dir = base_dir } })

  stub.executable({ fusermount = true, umount = true })

  local attempts = {}
  stub.set("system", function(cmd)
    table.insert(attempts, table.concat(cmd, " "))
    return {
      wait = function()
        return { code = 0, stdout = "", stderr = "" }
      end,
    }
  end)
  -- An empty mount table means nothing is active.
  stub.set("fn.system", function()
    return ""
  end)

  if opts and opts.delete_fails then
    local real_delete = vim.fn.delete
    local calls = 0
    stub.set("fn.delete", function(path, flags)
      calls = calls + 1
      if calls == 1 then return -1 end
      return real_delete(path, flags)
    end)
  end

  return require("sshfs.lib.mount_point"), base_dir, attempts
end

describe("MountPoint.cleanup_stale", function()
  it("removes an empty leftover without spawning an unmount", function()
    local MountPoint, base_dir, attempts = sweep_with()

    local removed = MountPoint.cleanup_stale()
    stub.restore_all()

    expect.eq(removed, 1)
    expect.eq(#attempts, 0, "an empty directory was never mounted")
    expect.eq(vim.fn.isdirectory(base_dir .. "/leftover"), 0)
    vim.fn.delete(base_dir, "rf")
  end)

  it("falls back to unmounting when the directory will not go away", function()
    local MountPoint, base_dir, attempts = sweep_with({ delete_fails = true })

    local removed = MountPoint.cleanup_stale()
    stub.restore_all()

    expect.eq(removed, 1, "the retry after unmounting must count")
    expect.truthy(#attempts > 0, "a directory that resists rmdir may still be mounted")
    vim.fn.delete(base_dir, "rf")
  end)
end)
