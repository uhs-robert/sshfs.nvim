-- tests/sshfs_options_spec.lua
-- SSHFS directory-cache option translation for 2.x implementations (fuse-t)
--
-- The option table is private, so these tests drive the real mount path with a
-- faked SSH module and capture the sshfs command that gets executed.

--- Run a mount and return the options from the resulting sshfs command
--- @param opts table {version_stdout, version_code, version_error, sshfs_options}
--- @return table options Map of sshfs option name to value (true for bare flags)
--- @return table notifications Captured vim.notify calls
local function mount_and_capture_options(opts)
  stub.reload()
  require("sshfs.config").setup({
    connections = { sshfs_options = opts.sshfs_options, socket_dir = "/home/tester/.ssh/sockets" },
  })

  -- The real SSH module would open sockets; only the two entry points the mount
  -- path uses are needed here.
  package.loaded["sshfs.lib.ssh"] = {
    try_batch_connect = function(_, callback)
      callback(true, 0, nil)
    end,
    build_command_string = function()
      return "ssh"
    end,
  }

  local notifications = stub.notifications()
  -- Run scheduled callbacks inline so the test stays synchronous.
  stub.set("schedule", function(fn)
    fn()
  end)

  local sshfs_command = nil
  stub.set("system", function(cmd, _, callback)
    if cmd[1] == "sshfs" and cmd[2] == "--version" then
      if opts.version_error then error("sshfs is not executable") end
      return {
        wait = function()
          return { code = opts.version_code or 0, stdout = opts.version_stdout or "", stderr = "" }
        end,
      }
    end

    sshfs_command = cmd
    if callback then callback({ code = 0, stdout = "", stderr = "" }) end
    return {
      wait = function()
        return { code = 0, stdout = "", stderr = "" }
      end,
    }
  end)

  require("sshfs.lib.sshfs").authenticate_and_mount(
    { name = "example.com" },
    "/Users/tester/mnt/example",
    "/srv/app",
    function() end
  )
  stub.restore_all()

  local options = {}
  if sshfs_command then
    for index, argument in ipairs(sshfs_command) do
      if argument == "-o" then
        for _, option in ipairs(vim.split(sshfs_command[index + 1], ",", { plain = true })) do
          local key, value = option:match("^([^=]+)=(.*)$")
          if key then
            options[key] = value
          else
            options[option] = true
          end
        end
      end
    end
  end

  return options, notifications
end

describe("SSHFS 3.x option handling", function()
  it("leaves directory cache options untouched", function()
    local options = mount_and_capture_options({
      version_stdout = "SSHFS version 3.7.3",
      sshfs_options = { dir_cache = "yes", dcache_timeout = 300, dcache_max_size = 10000 },
    })

    expect.eq(options.dir_cache, "yes")
    expect.eq(options.dcache_timeout, "300")
    expect.eq(options.dcache_max_size, "10000")
    expect.is_nil(options.cache)
    expect.is_nil(options.cache_timeout)
    expect.is_nil(options.cache_max_size)
  end)
end)

describe("SSHFS 2.x option translation", function()
  it("translates the 3.x directory cache names", function()
    local options = mount_and_capture_options({
      version_stdout = "SSHFS version 2.10",
      sshfs_options = { dir_cache = "yes", dcache_timeout = 300, dcache_max_size = 10000 },
    })

    expect.eq(options.cache, "yes")
    expect.eq(options.cache_timeout, "300")
    expect.eq(options.cache_max_size, "10000")
  end)

  it("removes the untranslated 3.x names", function()
    local options = mount_and_capture_options({
      version_stdout = "SSHFS version 2.10",
      sshfs_options = { dir_cache = "yes", dcache_timeout = 300, dcache_max_size = 10000 },
    })

    expect.is_nil(options.dir_cache, "sshfs 2.x rejects unknown options")
    expect.is_nil(options.dcache_timeout)
    expect.is_nil(options.dcache_max_size)
  end)

  it("keeps unrelated options unchanged", function()
    local options = mount_and_capture_options({
      version_stdout = "SSHFS version 2.10",
      sshfs_options = { reconnect = true, ConnectTimeout = 5, dir_cache = "yes" },
    })

    expect.eq(options.reconnect, true)
    expect.eq(options.ConnectTimeout, "5")
  end)

  it("prefers an explicitly configured 2.x value over the translated one", function()
    local options = mount_and_capture_options({
      version_stdout = "SSHFS version 2.10",
      sshfs_options = { dir_cache = "yes", cache = "no", dcache_timeout = 300, cache_timeout = 60 },
    })

    expect.eq(options.cache, "no", "the explicit 2.x value wins")
    expect.eq(options.cache_timeout, "60")
    expect.is_nil(options.dir_cache, "the translated name is still dropped")
    expect.is_nil(options.dcache_timeout)
  end)
end)

describe("SSHFS version detection failures", function()
  it("retains configured options when the version cannot be parsed", function()
    local options, notifications = mount_and_capture_options({
      version_stdout = "some unrecognized banner",
      sshfs_options = { dir_cache = "yes", dcache_timeout = 300 },
    })

    expect.eq(options.dir_cache, "yes")
    expect.eq(options.dcache_timeout, "300")

    local warned = false
    for _, notification in ipairs(notifications) do
      if type(notification.message) == "string" and notification.message:find("SSHFS version", 1, true) then
        warned = true
      end
    end
    expect.truthy(warned, "an unparseable version must warn rather than silently assume 3.x names")
  end)

  it("does not raise when the version probe itself fails", function()
    expect.no_error(function()
      mount_and_capture_options({
        version_error = true,
        sshfs_options = { dir_cache = "yes" },
      })
    end)
  end)

  it("does not raise when the version probe exits non-zero", function()
    local options = expect.no_error(function()
      return mount_and_capture_options({
        version_code = 1,
        version_stdout = "SSHFS version 2.10",
        sshfs_options = { dir_cache = "yes" },
      })
    end)

    expect.eq(options.cache, "yes", "a version reported on a non-zero exit is still usable")
  end)
end)
