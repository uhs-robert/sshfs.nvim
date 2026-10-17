-- tests/mirror_spec.lua
-- Mirror mode: connection listing, rsync command builders, remote scripts, and the sync engine end to end
-- against a fake server that answers the plugin's ssh and rsync commands.

local MOUNT_BASE = "/home/tester/mnt"
local OLD = 1000000 -- an mtime long before any test runs
local real_system = vim.system

--- Load the plugin against a scratch state, cache and mirror directory, with a one-entry mount table
--- @param opts table|nil {mirror = config overrides, mount_output = string, mounts_base = string, socket_dir = string}
--- @return string scratch
local function with_scratch(opts)
  opts = opts or {}
  stub.reload()
  local scratch = vim.fn.tempname()
  vim.fn.mkdir(scratch, "p")

  local real_stdpath = vim.fn.stdpath
  stub.set("fn.stdpath", function(what)
    if what == "state" then return scratch .. "/state" end
    if what == "cache" then return scratch .. "/cache" end
    return real_stdpath(what)
  end)
  stub.executable({ findmnt = false, rsync = true })
  stub.system(function()
    return opts.mount_output or "", 0
  end)

  local mirror_opts = vim.tbl_extend("force", { base_dir = scratch .. "/mirrors" }, opts.mirror or {})
  require("sshfs.config").setup({
    mounts = { base_dir = opts.mounts_base or MOUNT_BASE },
    connections = { socket_dir = opts.socket_dir or "/s" },
    mirror = mirror_opts,
  })
  return scratch
end

--- Remove a scratch tree and the exit hook a queued push registers, so neither outlives the case
local function finish(scratch)
  pcall(vim.api.nvim_del_augroup_by_name, "sshfs_mirror_exit")
  vim.fn.delete(scratch, "rf")
end

local function save_mirror(scratch, fields)
  local state = vim.tbl_extend("force", {
    host = "box",
    user = "me",
    port = 2222,
    remote_path = "/srv/app",
    local_path = scratch .. "/mirrors/box_srv_app",
    manifest = {},
    unsynced = {},
    connected = true,
  }, fields or {})
  require("sshfs.lib.mirror_state").save(state)
  return state
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_file(path, content, mtime)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
  if mtime then vim.uv.fs_utime(path, mtime, mtime) end
end

local function entry(mtime, content)
  return string.format("%d %d", mtime, #content)
end

--- Fake server: files keyed by path relative to the remote root, each {mtime, content}
--- Answers rsync --version, the remote scripts, and rsync pulls and pushes against the local mirror root.
-- Connections -------------------------------------------------------------------------------------------------

describe("Connections.list_active", function()
  it("tags mounts and mirrors and keeps mount_path as the local root", function()
    local scratch = with_scratch({
      mount_output = "deploy@example.com:/srv/app on " .. MOUNT_BASE .. "/example type fuse.sshfs (rw)",
    })
    local state = save_mirror(scratch)
    require("sshfs.lib.lockfile").register(state.local_path)

    local connections = require("sshfs.lib.connections").list_active()
    stub.restore_all()

    expect.eq(#connections, 2)
    expect.eq(connections[1].kind, "mount")
    expect.eq(connections[1].host, "example.com")
    expect.eq(connections[2].kind, "mirror")
    expect.eq(connections[2].mount_path, state.local_path)
    expect.eq(connections[2].remote_path, "/srv/app")
    finish(scratch)
  end)

  it("lists only mirrors that are still connected", function()
    local scratch = with_scratch()
    local state = save_mirror(scratch, { connected = false })
    require("sshfs.lib.lockfile").register(state.local_path)

    local connections = require("sshfs.lib.connections").list_active()
    stub.restore_all()

    expect.eq(#connections, 0)
    finish(scratch)
  end)

  it("does not list a mirror left connected by a Neovim that is gone", function()
    local scratch = with_scratch()
    local state = save_mirror(scratch)
    -- A PID that cannot be running: the instance that owned the mirror crashed
    write_file(scratch .. "/cache/sshfs/" .. vim.fn.sha256(state.local_path):sub(1, 16) .. ".lock", "999999999\n")

    local connections = require("sshfs.lib.connections").list_active()
    stub.restore_all()

    expect.eq(#connections, 0)
    finish(scratch)
  end)

  it("marks mirrors in labels", function()
    local scratch = with_scratch()
    local state = save_mirror(scratch)
    require("sshfs.lib.lockfile").register(state.local_path)

    local Connections = require("sshfs.lib.connections")
    expect.eq(Connections.format_label(Connections.get_active()), "box: /srv/app [mirror]")
    stub.restore_all()
    finish(scratch)
  end)
end)

-- Builders -----------------------------------------------------------------------------------------------------

local SSH = "ssh -o RemoteCommand=none -o RequestTTY=no -o ControlMaster=auto -o ControlPath=/s/%C "
  .. "-o ControlPersist=10m -o BatchMode=yes -p 2222"

local CONN = { host = "box", user = "me", port = 2222, remote_path = "/srv/app", local_path = "/m/box_srv_app" }

--- Builder setup with a given `rsync --version` answer
local function with_rsync(version, opts)
  local scratch = with_scratch(opts)
  stub.vim_system(function(cmd)
    if cmd[2] == "--version" then return { stdout = version } end
    return {}
  end)
  return scratch
end

local function with_conn(fields)
  return vim.tbl_extend("force", CONN, fields)
end

describe("Rsync builders", function()
  it("builds a pull over the ControlMaster socket that never prompts", function()
    finish(with_rsync("rsync  version 3.2.7  protocol version 31"))
    local command = require("sshfs.lib.rsync").pull(CONN, { "node_modules", "dist" }, "/tmp/skip.txt")
    stub.restore_all()

    expect.eq(command, {
      "rsync",
      "-rlptz",
      "--update",
      "--exclude=node_modules",
      "--exclude=dist",
      "--exclude-from=/tmp/skip.txt",
      "-e",
      SSH,
      "me@box:/srv/app/",
      "/m/box_srv_app/",
    })
  end)

  it("pushes only the files in an include list, never .git", function()
    finish(with_rsync("rsync  version 3.2.7  protocol version 31"))
    local command = require("sshfs.lib.rsync").push_files(CONN, "/tmp/include.txt")
    stub.restore_all()

    expect.eq(command, {
      "rsync",
      "-rltz",
      "--omit-dir-times",
      "--exclude=.git",
      "--include-from=/tmp/include.txt",
      "--exclude=*",
      "-e",
      SSH,
      "/m/box_srv_app/",
      "me@box:/srv/app/",
    })
  end)

  it("leaves out --omit-dir-times for openrsync, which may not accept it", function()
    finish(with_rsync("openrsync: protocol version 29"))
    local command = require("sshfs.lib.rsync").push_files(CONN, "/tmp/include.txt")
    stub.restore_all()

    expect.eq(command[2], "-rltz")
    expect.falsy(vim.tbl_contains(command, "--omit-dir-times"))
  end)

  it("appends configured rsync_options after the core flags", function()
    finish(with_rsync("rsync  version 3.2.7  protocol version 31", { mirror = { rsync_options = { "--chmod=u+rw" } } }))
    local command = require("sshfs.lib.rsync").push_files(CONN, "/tmp/i")
    stub.restore_all()

    expect.eq(vim.list_slice(command, 1, 3), { "rsync", "-rltz", "--chmod=u+rw" })
  end)

  it("quotes a ControlPath with spaces inside -e", function()
    finish(with_rsync("rsync  version 3.2.7", { socket_dir = "/Users/me/Library/Application Support/s" }))
    local command = require("sshfs.lib.rsync").pull(CONN, {})
    stub.restore_all()

    expect.contains(command[#command - 2], " -o 'ControlPath=/Users/me/Library/Application Support/s/%C' -o ")
  end)

  it("leaves a spaced remote path to rsync 3.2.4+, which escapes it itself", function()
    finish(with_rsync("rsync  version 3.2.4  protocol version 31"))
    local command = require("sshfs.lib.rsync").pull(with_conn({ remote_path = "/srv/my app's" }), {})
    stub.restore_all()

    expect.eq(command[#command - 1], "me@box:/srv/my app's/")
    expect.falsy(vim.tbl_contains(command, "-s"))
  end)

  it("protects remote paths with -s on rsync 3.0 to 3.2.3", function()
    finish(with_rsync("rsync  version 3.2.3  protocol version 31"))
    local command = require("sshfs.lib.rsync").pull(with_conn({ remote_path = "/srv/my app" }), {})
    stub.restore_all()

    expect.eq(command[3], "-s")
    expect.eq(command[#command - 1], "me@box:/srv/my app/")
  end)

  it("escapes remote paths for the remote shell on openrsync, without -s", function()
    finish(with_rsync("openrsync: protocol version 29\nrsync version 2.6.9 compatible"))
    local command = require("sshfs.lib.rsync").pull(with_conn({ remote_path = "/srv/my app's $x" }), {})
    stub.restore_all()

    expect.falsy(vim.tbl_contains(command, "-s"))
    expect.eq(command[#command - 1], "me@box:/srv/my\\ app\\'s\\ \\$x/")
  end)

  it("refuses a remote path that needs escaping when the rsync is not recognised", function()
    finish(with_rsync("something else"))
    local Rsync = require("sshfs.lib.rsync")
    local ok_plain = Rsync.check_supported(CONN)
    local ok_spaced, err = Rsync.check_supported(with_conn({ remote_path = "/srv/a b" }))
    stub.restore_all()

    expect.truthy(ok_plain)
    expect.falsy(ok_spaced)
    expect.contains(err, "unrecognised rsync")
  end)

  it("keeps a relative remote path starting with a dash from reading as an option", function()
    finish(with_rsync("rsync  version 3.2.7  protocol version 31"))
    local command = require("sshfs.lib.rsync").pull(with_conn({ remote_path = "-rf" }), {})
    stub.restore_all()

    expect.eq(command[#command - 1], "me@box:./-rf/")
  end)

  it("writes literal, anchored filter patterns for awkward names", function()
    local Rsync = require("sshfs.lib.rsync")
    expect.eq(Rsync.literal_pattern("-rf"), "/-rf")
    expect.eq(Rsync.literal_pattern("a b'c\"d"), "/a b'c\"d")
    expect.eq(Rsync.literal_pattern("x*y"), "/x\\*y")
    -- No wildcard, so rsync matches the backslash literally and it must not be doubled
    expect.eq(Rsync.literal_pattern("a\\b"), "/a\\b")
    expect.eq(Rsync.literal_pattern("a\\b[1]"), "/a\\\\b\\[1]")
  end)

  it("includes every parent directory of a pushed file once", function()
    local list = require("sshfs.lib.rsync").include_list({ "src/a/x.lua", "src/a/y.lua", "top" })
    expect.eq(list, "/src/\n/src/a/\n/src/a/x.lua\n/src/a/y.lua\n/top\n")
  end)
end)

describe("MirrorState.apply", function()
  it("merges per entry with what another instance wrote meanwhile", function()
    local scratch = with_scratch()
    local MirrorState = require("sshfs.lib.mirror_state")
    local state = save_mirror(scratch, { manifest = { a = "1 1", b = "1 1" } })

    -- Another instance records b; this instance, which read the state before that, records a
    MirrorState.apply(state.local_path, { b = "2 2" }, {})
    MirrorState.apply(state.local_path, { a = "3 3" }, { a = "why" })
    local merged = MirrorState.load(state.local_path)
    MirrorState.apply(state.local_path, { b = false }, { a = false })
    local after = MirrorState.load(state.local_path)
    stub.restore_all()

    expect.eq(merged.manifest, { a = "3 3", b = "2 2" })
    expect.eq(merged.unsynced, { a = "why" })
    expect.eq(after.manifest, { a = "3 3" })
    expect.eq(after.unsynced, {})
    expect.eq(vim.fn.glob(scratch .. "/state/sshfs/mirrors/*.tmp"), "", "writes go through temp+rename")
    finish(scratch)
  end)
end)

describe("MountPoint.cleanup_stale with mirrors", function()
  it("never removes an empty mirror when mirrors share the mount base directory", function()
    local outer = vim.fn.tempname()
    local scratch = with_scratch({ mounts_base = outer .. "/shared", mirror = { base_dir = outer .. "/shared" } })
    vim.fn.mkdir(outer .. "/shared/leftover", "p")
    vim.fn.mkdir(outer .. "/shared/box_srv_empty", "p")
    require("sshfs.lib.mirror_state").save({
      host = "box",
      remote_path = "/srv/empty",
      local_path = outer .. "/shared/box_srv_empty",
      manifest = {},
    })

    local removed = require("sshfs.lib.mount_point").cleanup_stale()
    local mirror_survived = vim.fn.isdirectory(outer .. "/shared/box_srv_empty") == 1
    stub.restore_all()

    expect.eq(removed, 1)
    expect.truthy(mirror_survived, "an empty mirror directory is still a mirror")
    finish(scratch)
    vim.fn.delete(outer, "rf")
  end)
end)
