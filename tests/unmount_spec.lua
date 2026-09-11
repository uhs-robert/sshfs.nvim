-- tests/unmount_spec.lua
-- Unmount escalation and exit-hook registration
--
-- fuse-t cleanup has to finish before Neovim tears down, so unmounting runs
-- synchronously and the exit hook moved to VimLeavePre.

--- Run MountPoint.unmount against stubbed unmount tools
--- @param opts table {available, succeeds_on} available command names and the
---   first command string that should exit 0
--- @return boolean result, table attempts, boolean waited_synchronously
local function unmount_with(opts)
  stub.reload()
  require("sshfs.config").setup({})

  stub.executable(opts.available)
  stub.set("fn.delete", function()
    return 0
  end)

  local attempts = {}
  local waited_synchronously = false
  stub.set("system", function(cmd)
    table.insert(attempts, table.concat(cmd, " "))
    return {
      wait = function(_, timeout)
        waited_synchronously = timeout ~= nil
        local code = (table.concat(cmd, " ") == opts.succeeds_on) and 0 or 1
        return { code = code, stdout = "", stderr = "" }
      end,
    }
  end)

  local result = require("sshfs.lib.mount_point").unmount("/Users/tester/mnt/host")
  stub.restore_all()

  return result, attempts, waited_synchronously
end

describe("MountPoint.unmount", function()
  it("unmounts synchronously with a timeout rather than a background job", function()
    local result, _, waited_synchronously = unmount_with({
      available = { "umount" },
      succeeds_on = "umount /Users/tester/mnt/host",
    })

    expect.truthy(result)
    expect.truthy(waited_synchronously, "cleanup must complete before Neovim exits")
  end)

  it("prefers fusermount before falling back to umount", function()
    local result, attempts = unmount_with({
      available = { "fusermount", "umount" },
      succeeds_on = "fusermount -u /Users/tester/mnt/host",
    })

    expect.truthy(result)
    expect.eq(attempts, { "fusermount -u /Users/tester/mnt/host" })
  end)

  it("escalates clean, then lazy, then force", function()
    local _, attempts = unmount_with({
      available = { "umount", "diskutil" },
      succeeds_on = "umount -f /Users/tester/mnt/host",
    })

    expect.eq(attempts, {
      "umount /Users/tester/mnt/host",
      "diskutil unmount /Users/tester/mnt/host",
      "umount -l /Users/tester/mnt/host",
      "diskutil unmount force /Users/tester/mnt/host",
      "umount -f /Users/tester/mnt/host",
    }, "a clean unmount is attempted before lazy, and lazy before force")
  end)

  it("uses diskutil where it is the only available tool", function()
    local result, attempts = unmount_with({
      available = { "diskutil" },
      succeeds_on = "diskutil unmount /Users/tester/mnt/host",
    })

    expect.truthy(result)
    expect.eq(attempts, { "diskutil unmount /Users/tester/mnt/host" })
  end)

  it("skips tools that are not installed", function()
    local _, attempts = unmount_with({
      available = { "umount" },
      succeeds_on = "never-succeeds",
    })

    for _, attempt in ipairs(attempts) do
      expect.falsy(attempt:find("fusermount", 1, true), "fusermount is absent and must not be invoked")
      expect.falsy(attempt:find("diskutil", 1, true), "diskutil is absent and must not be invoked")
    end
  end)

  it("reports failure when every strategy fails", function()
    local result = unmount_with({ available = { "umount" }, succeeds_on = "never-succeeds" })
    expect.falsy(result)
  end)

  it("reports failure when no unmount tool is installed", function()
    local result, attempts = unmount_with({ available = {}, succeeds_on = "never-succeeds" })

    expect.falsy(result)
    expect.eq(attempts, {})
  end)
end)

describe("automatic unmount on exit", function()
  --- Capture the autocommand events sshfs.nvim registers during setup
  local function registered_events(hooks)
    stub.reload()
    local events = {}
    stub.set("api.nvim_create_autocmd", function(event, definition)
      table.insert(events, { event = event, group = definition.group, desc = definition.desc })
    end)
    stub.set("fn.executable", function()
      return 1
    end)
    stub.notifications()

    require("sshfs").setup({ hooks = hooks })
    stub.restore_all()

    return events
  end

  it("registers cleanup on VimLeavePre so the event loop is still running", function()
    local events = registered_events({ on_exit = { auto_unmount = true } })

    local found = false
    for _, entry in ipairs(events) do
      if entry.event == "VimLeavePre" then found = true end
      expect.falsy(entry.event == "VimLeave", "VimLeave runs too late for synchronous unmounting")
    end
    expect.truthy(found, "auto_unmount must register a VimLeavePre autocommand")
  end)

  it("registers no exit hook when auto_unmount is disabled", function()
    local events = registered_events({ on_exit = { auto_unmount = false } })

    for _, entry in ipairs(events) do
      expect.falsy(entry.event == "VimLeavePre", "no exit hook is expected when auto_unmount is off")
    end
  end)
end)
