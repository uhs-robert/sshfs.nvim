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
local function fake_server(root, files)
  local server = {
    files = files or {},
    stat_answers = {}, -- rel -> raw answer overriding the computed one
    ssh_failures = 0, -- the next N ssh/rsync calls fail as if the socket were gone
    version = "rsync  version 3.2.7  protocol version 31",
    pushed = {}, -- rels of every push, in order
    pull_skips = {}, -- skip list of every pull
    exclude_files = {}, -- every --exclude-from / --include-from path used
    on_push = nil, -- fun(rels) after the copy, as if the user saved again
    on_pull = nil, -- fun() after the copy
    deleted = {},
  }

  local function file_entry(rel)
    local file = server.files[rel]
    return file and entry(file.mtime, file.content)
  end

  local function lines_of(text)
    local lines = {}
    for line in (text or ""):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    return lines
  end

  local function unpattern(line)
    local rel = line:sub(2)
    if rel:find("[%*%?%[]") then rel = rel:gsub("\\(.)", "%1") end
    return rel
  end

  local function arg_value(cmd, prefix)
    for _, arg in ipairs(cmd) do
      if arg:sub(1, #prefix) == prefix then return arg:sub(#prefix + 1) end
    end
  end

  local function handle_ssh(remote, stdin)
    if remote == "command -v rsync" then return { stdout = "/usr/bin/rsync\n" } end
    if remote:find("SSHFS_STAT", 1, true) then
      local out = { "motd noise that is not an answer" }
      for index = 2, #stdin do
        local rel = stdin[index]
        local answer = server.stat_answers[rel] or (server.files[rel] and ("F " .. file_entry(rel))) or "A"
        table.insert(out, "SSHFS_STAT " .. answer)
      end
      return { stdout = table.concat(out, "\n") .. "\n" }
    end
    if remote:find("SSHFS_RM", 1, true) then
      local out = {}
      for index = 2, #stdin, 2 do
        local want, rel = stdin[index], stdin[index + 1]
        if not server.files[rel] then
          table.insert(out, "SSHFS_RM A")
        elseif file_entry(rel) == want then
          server.files[rel] = nil
          table.insert(server.deleted, rel)
          table.insert(out, "SSHFS_RM D")
        else
          table.insert(out, "SSHFS_RM C")
        end
      end
      return { stdout = table.concat(out, "\n") .. "\n" }
    end
    if remote:find("exec cat", 1, true) then
      local file = server.files[stdin[2]]
      return file and { stdout = file.content } or { code = 1, stderr = "No such file" }
    end
    return { code = 127, stderr = "unexpected remote command: " .. remote }
  end

  local function handle_push(include_from)
    table.insert(server.exclude_files, include_from)
    local rels = {}
    for _, line in ipairs(lines_of(read_file(include_from))) do
      if line:sub(-1) ~= "/" then table.insert(rels, unpattern(line)) end
    end
    for _, rel in ipairs(rels) do
      local path = root .. "/" .. rel
      server.files[rel] = { mtime = vim.uv.fs_stat(path).mtime.sec, content = read_file(path) }
    end
    table.insert(server.pushed, rels)
    if server.on_push then server.on_push(rels) end
    return {}
  end

  local function handle_pull(cmd)
    local skip_from = arg_value(cmd, "--exclude-from=")
    local skip = {}
    if skip_from then
      table.insert(server.exclude_files, skip_from)
      for _, line in ipairs(lines_of(read_file(skip_from))) do
        skip[unpattern(line)] = true
      end
    end
    table.insert(server.pull_skips, vim.tbl_keys(skip))
    local update = vim.tbl_contains(cmd, "--update")
    for rel, file in pairs(server.files) do
      local path = root .. "/" .. rel
      local stat = vim.uv.fs_stat(path)
      local newer_locally = update and stat and stat.mtime.sec > file.mtime
      local same = stat and stat.mtime.sec == file.mtime and stat.size == #file.content
      if not skip[rel] and not newer_locally and not same then write_file(path, file.content, file.mtime) end
    end
    if server.on_pull then server.on_pull() end
    return {}
  end

  server.calls = stub.vim_system(function(cmd, opts)
    if cmd[1] == "rsync" and cmd[2] == "--version" then return { stdout = server.version } end
    if server.ssh_failures > 0 then
      server.ssh_failures = server.ssh_failures - 1
      return { code = 255, stderr = "Control socket connect: No such file or directory" }
    end
    if cmd[1] == "ssh" then return handle_ssh(cmd[#cmd], lines_of(opts.stdin)) end
    if cmd[1] == "rsync" then
      local include_from = arg_value(cmd, "--include-from=")
      if include_from then return handle_push(include_from) end
      return handle_pull(cmd)
    end
    return { code = 127, stderr = "unexpected command" }
  end)
  return server
end

-- Prompts made under no_prompt(); settle() fails the case on any, since an error raised inside the prompt
-- itself would come from a scheduled callback and not fail it
local unexpected_prompts = {}

--- Wait until every queued mirror transfer is done
local function settle()
  vim.wait(2000, function()
    return not require("sshfs.lib.mirror").has_pending()
  end, 5)
  vim.wait(20)
  if #unexpected_prompts > 0 then error("unexpected prompt: " .. unexpected_prompts[1]) end
end

--- A connected mirror rooted in scratch whose local tree and manifest match the given server files
local function synced_mirror(scratch, files)
  local root = scratch .. "/mirrors/box_srv_app"
  vim.fn.mkdir(root, "p")
  local manifest = {}
  for rel, file in pairs(files) do
    write_file(root .. "/" .. rel, file.content, file.mtime)
    manifest[rel] = entry(file.mtime, file.content)
  end
  save_mirror(scratch, { manifest = manifest })
  require("sshfs.lib.lockfile").register(root)
  return root
end

local function load_state(root)
  return require("sshfs.lib.mirror_state").load(root)
end

local function prompt_with(choice_index)
  local prompts = {}
  stub.set("ui.select", function(items, opts, callback)
    table.insert(prompts, { items = items, prompt = opts.prompt })
    callback(items[choice_index])
  end)
  return prompts
end

local function no_prompt()
  unexpected_prompts = {}
  stub.set("ui.select", function(_, opts)
    table.insert(unexpected_prompts, opts.prompt)
  end)
end

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

describe("Mirror.reconcile", function()
  it("marks a crashed instance's mirror disconnected so it can be mirrored again", function()
    local scratch = with_scratch()
    local stale = save_mirror(scratch)
    local live = save_mirror(scratch, { local_path = scratch .. "/mirrors/box_other" })
    require("sshfs.lib.lockfile").register(live.local_path)

    require("sshfs.lib.mirror").reconcile()
    local stale_after = load_state(stale.local_path)
    local live_after = load_state(live.local_path)
    stub.restore_all()

    expect.eq(stale_after.connected, false)
    expect.eq(live_after.connected, true)
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

-- Remote scripts ---------------------------------------------------------------------------------------------

describe("Mirror remote commands", function()
  it("run ssh non-interactively with a timeout, paths on stdin", function()
    local scratch = with_scratch()
    local seen
    stub.vim_system(function(cmd, opts)
      seen = { cmd = cmd, opts = opts }
      return { stdout = "SSHFS_STAT A\n" }
    end)
    local state = save_mirror(scratch)
    require("sshfs.lib.mirror_remote").stat(state, { "-x 'y'.lua" }, {}, function() end)
    vim.wait(100, function()
      return seen ~= nil
    end)
    stub.restore_all()

    local command = table.concat(seen.cmd, " ")
    expect.contains(command, "-o BatchMode=yes")
    expect.contains(command, "-o RemoteCommand=none")
    expect.contains(command, "-o RequestTTY=no")
    expect.falsy(vim.tbl_contains(seen.cmd, "-t"))
    expect.truthy(seen.opts.timeout and seen.opts.timeout > 0)
    expect.eq(seen.opts.stdin, "/srv/app\n-x 'y'.lua\n")
    -- The script is one single-quoted word, so any login shell hands it to sh untouched
    local remote = seen.cmd[#seen.cmd]
    expect.eq(select(2, remote:gsub("'", "")), 2)
    finish(scratch)
  end)

  it("stat script answers file, absent and error per path when run by a real shell", function()
    local scratch = with_scratch()
    local captured
    stub.vim_system(function(cmd, opts)
      captured = { cmd = cmd, opts = opts }
      return {}
    end)
    local remote_root = scratch .. "/remote root"
    write_file(remote_root .. "/-n 'q' \"d\".txt", "hello", OLD)
    vim.fn.mkdir(remote_root .. "/dir", "p")
    vim.fn.mkdir(remote_root .. "/locked/inner", "p")
    local rels = { "-n 'q' \"d\".txt", "missing", "new/dir/file", "dir", "locked/inner/x" }
    local state = save_mirror(scratch, { remote_path = remote_root })
    require("sshfs.lib.mirror_remote").stat(state, rels, {}, function() end)
    vim.wait(100, function()
      return captured ~= nil
    end)
    stub.restore_all()

    vim.uv.fs_chmod(remote_root .. "/locked", 0)
    -- Run the remote command line the way the login shell on the server would
    local obj = real_system({ "sh", "-c", captured.cmd[#captured.cmd] }, { stdin = captured.opts.stdin, text = true }):wait()
    vim.uv.fs_chmod(remote_root .. "/locked", 448)
    local results = require("sshfs.lib.mirror_remote").parse_stat(obj.stdout, rels)

    expect.eq(results["-n 'q' \"d\".txt"], { kind = "file", entry = entry(OLD, "hello") })
    expect.eq(results["missing"], { kind = "absent" })
    expect.eq(results["new/dir/file"], { kind = "absent" })
    expect.eq(results["dir"], { kind = "error" }, "a directory is not a pushable file")
    if vim.uv.getuid() ~= 0 then
      expect.eq(results["locked/inner/x"], { kind = "error" }, "an unreadable parent is not proof of absence")
    end
    finish(scratch)
  end)

  it("delete script removes only files still matching, when run by a real shell", function()
    local scratch = with_scratch()
    local captured
    stub.vim_system(function(cmd, opts)
      captured = { cmd = cmd, opts = opts }
      return {}
    end)
    local remote_root = scratch .. "/remote"
    write_file(remote_root .. "/same file", "x", OLD)
    write_file(remote_root .. "/changed", "changed", OLD + 1)
    local state = save_mirror(scratch, { remote_path = remote_root })
    require("sshfs.lib.mirror_remote").delete(state, {
      { rel = "same file", expected = entry(OLD, "x") },
      { rel = "changed", expected = entry(OLD, "c") },
      { rel = "absent", expected = entry(OLD, "a") },
    }, {}, function() end)
    vim.wait(100, function()
      return captured ~= nil
    end)
    stub.restore_all()

    local obj = real_system({ "sh", "-c", captured.cmd[#captured.cmd] }, { stdin = captured.opts.stdin, text = true }):wait()

    expect.eq(obj.stdout, "SSHFS_RM D\nSSHFS_RM C\nSSHFS_RM A\n")
    expect.eq(vim.fn.filereadable(remote_root .. "/same file"), 0)
    expect.eq(vim.fn.filereadable(remote_root .. "/changed"), 1)
    finish(scratch)
  end)

  it("stat script terminates for a relative remote root whose top directory is missing", function()
    local scratch = with_scratch()
    local captured
    stub.vim_system(function(cmd, opts)
      captured = { cmd = cmd, opts = opts }
      return {}
    end)
    local state = save_mirror(scratch, { remote_path = "proj" })
    require("sshfs.lib.mirror_remote").stat(state, { "sub/x" }, {}, function() end)
    vim.wait(100, function()
      return captured ~= nil
    end)
    stub.restore_all()

    local obj = real_system(
      { "sh", "-c", captured.cmd[#captured.cmd] },
      { stdin = captured.opts.stdin, text = true, cwd = scratch, timeout = 5000 }
    ):wait()
    expect.eq(obj.code, 0)
    expect.eq(
      require("sshfs.lib.mirror_remote").parse_stat(obj.stdout, { "sub/x" }),
      { ["sub/x"] = { kind = "absent" } }
    )
    finish(scratch)
  end)

  it("fails closed when the stat output does not answer every path", function()
    local Remote = require("sshfs.lib.mirror_remote")
    local results, err = Remote.parse_stat("SSHFS_STAT F 1 2\n", { "a", "b" })
    expect.is_nil(results)
    expect.contains(err, "unexpected stat output")
    expect.eq(Remote.parse_stat("noise\nSSHFS_STAT weird\n", { "a" }), { a = { kind = "error" } })
  end)

  it("re-authenticates once when the socket has gone, then retries", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {})
    local server = fake_server(root)
    server.ssh_failures = 1
    local auths = 0
    package.loaded["sshfs.lib.sshfs"] = {
      authenticate = function(_, callback)
        auths = auths + 1
        callback({ success = true })
      end,
    }

    local answer
    require("sshfs.lib.mirror_remote").stat(load_state(root), { "a" }, {}, function(results)
      answer = results
    end)
    vim.wait(500, function()
      return answer ~= nil
    end)
    stub.restore_all()

    expect.eq(auths, 1)
    expect.eq(answer, { a = { kind = "absent" } })
    finish(scratch)
  end)

  it("does not re-authenticate while Neovim is exiting", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {})
    local server = fake_server(root)
    server.ssh_failures = 5
    package.loaded["sshfs.lib.sshfs"] = {
      authenticate = function()
        error("must not authenticate while exiting")
      end,
    }

    local finished, results, err
    require("sshfs.lib.mirror_remote").stat(load_state(root), { "a" }, { no_reauth = true }, function(r, e)
      finished, results, err = true, r, e
    end)
    vim.wait(500, function()
      return finished
    end)
    stub.restore_all()

    expect.is_nil(results)
    expect.contains(err, "exit 255")
    finish(scratch)
  end)
end)

-- Exclusion and manifest ---------------------------------------------------------------------------------------

describe("Mirror exclusion", function()
  it("follows rsync's rules for names, slashes, anchors and directory-only patterns", function()
    local Mirror = require("sshfs.lib.mirror")
    local ex = { "node_modules", "build/cache", "/dist", "*.log", "tmp/" }
    expect.truthy(Mirror.is_excluded("node_modules/x.js", ex))
    expect.truthy(Mirror.is_excluded("a/node_modules/x.js", ex))
    expect.truthy(Mirror.is_excluded("build/cache/x", ex))
    expect.truthy(Mirror.is_excluded("pkg/build/cache/x", ex))
    expect.falsy(Mirror.is_excluded("build/x", ex))
    expect.falsy(Mirror.is_excluded("xbuild/cache/x", ex), "a slashed pattern matches whole components")
    expect.truthy(Mirror.is_excluded("dist/a.js", ex))
    expect.falsy(Mirror.is_excluded("src/dist/a.js", ex), "an anchored pattern matches only at the root")
    expect.truthy(Mirror.is_excluded("logs/a.log", ex))
    expect.truthy(Mirror.is_excluded("tmp/a", ex))
    expect.falsy(Mirror.is_excluded("tmp", ex), "a directory-only pattern does not match a file")
    expect.truthy(Mirror.is_excluded("tmp", ex, true))
    expect.truthy(Mirror.is_excluded("sub/.git/config", {}))
  end)

  it("builds snapshots from whole-second mtime and size, skipping .git and excludes", function()
    with_scratch()
    local dir = vim.fn.tempname()
    for _, name in ipairs({ "x", "sub/y", "node_modules/z", ".git/HEAD", "build/cache/c" }) do
      write_file(dir .. "/" .. name, "")
    end
    stub.set("uv.fs_stat", function()
      return { mtime = { sec = 42, nsec = 7 }, size = 9, type = "file" }
    end)

    local snapshot = require("sshfs.lib.mirror").snapshot(dir, { "node_modules", "build/cache" })
    stub.restore_all()

    expect.eq(snapshot, { ["x"] = "42 9", ["sub/y"] = "42 9" })
    vim.fn.delete(dir, "rf")
  end)

  it("reports edited, new and unsaved files as dirty but not untouched ones", function()
    local dirty = require("sshfs.lib.mirror").dirty_files(
      { ["a"] = "1 1", ["b"] = "1 1", ["c"] = "1 1" },
      { ["a"] = "1 1", ["b"] = "2 1", ["new"] = "3 1", ["c"] = "1 1" },
      { "c" }
    )
    expect.eq(dirty, { "b", "c", "new" })
  end)
end)

describe("Mirror.classify", function()
  local function file(e)
    return { kind = "file", entry = e }
  end

  it("pushes when the server still holds what the last sync saw", function()
    local Mirror = require("sshfs.lib.mirror")
    expect.eq(Mirror.classify("100 5", "200 6", file("100 5")), "push")
    expect.eq(Mirror.classify(nil, "200 6", { kind = "absent" }), "push")
  end)

  it("treats a server that already holds the local file as synced", function()
    expect.eq(require("sshfs.lib.mirror").classify("100 5", "200 6", file("200 6")), "synced")
  end)

  it("flags server edits, server deletes and server-only files as conflicts", function()
    local Mirror = require("sshfs.lib.mirror")
    expect.eq(Mirror.classify("100 5", "200 6", file("150 5")), "conflict")
    expect.eq(Mirror.classify("100 5", "200 6", { kind = "absent" }), "conflict")
    expect.eq(Mirror.classify(nil, "200 6", file("150 5")), "conflict")
  end)

  it("treats an unreadable server copy as an error, never as absent", function()
    local Mirror = require("sshfs.lib.mirror")
    expect.eq(Mirror.classify("100 5", "200 6", { kind = "error" }), "error")
    expect.eq(Mirror.classify(nil, "200 6", nil), "error")
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

-- Push on save -------------------------------------------------------------------------------------------------

describe("Mirror push on save", function()
  it("pushes a saved file and records the version it sent", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD, content = "one" } })
    no_prompt()
    write_file(root .. "/a.txt", "two!", OLD + 10)

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(server.pushed, { { "a.txt" } })
    expect.eq(server.files["a.txt"].content, "two!")
    expect.eq(state.manifest["a.txt"], entry(OLD + 10, "two!"))
    finish(scratch)
  end)

  it("coalesces saves made while a push is in flight into one batch", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {})
    local server = fake_server(root)
    no_prompt()
    local Mirror = require("sshfs.lib.mirror")
    for _, rel in ipairs({ "a", "b", "c" }) do
      write_file(root .. "/" .. rel, rel, OLD)
    end
    server.on_push = function(rels)
      if rels[1] == "a" then
        Mirror.enqueue(root, "b")
        Mirror.enqueue(root, "c")
        Mirror.enqueue(root, "b")
      end
    end

    Mirror.enqueue(root, "a")
    settle()
    stub.restore_all()

    expect.eq(server.pushed, { { "a" }, { "b", "c" } })
    finish(scratch)
  end)

  it("keeps a file saved again during its push dirty and pushes it again", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD, content = "one" } })
    no_prompt()
    write_file(root .. "/a.txt", "save 1", OLD + 10)
    local manifest_during_second
    server.on_push = function()
      if #server.pushed == 1 then
        write_file(root .. "/a.txt", "save 2 longer", OLD + 20)
      else
        manifest_during_second = load_state(root).manifest["a.txt"]
      end
    end

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    -- After the first push the manifest held save 1, which is what the server had, so save 2 stayed dirty
    expect.eq(manifest_during_second, entry(OLD + 10, "save 1"))
    expect.eq(#server.pushed, 2)
    expect.eq(server.files["a.txt"].content, "save 2 longer")
    expect.eq(state.manifest["a.txt"], entry(OLD + 20, "save 2 longer"))
    finish(scratch)
  end)

  it("asks before overwriting a server change, and a cancel keeps the file dirty and recorded", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD + 5, content = "colleague" } })
    local prompts = prompt_with(3)
    write_file(root .. "/a.txt", "mine", OLD + 10)

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(#prompts, 1)
    expect.contains(prompts[1].prompt, "a.txt changed on box")
    expect.eq(server.pushed, {})
    expect.eq(server.files["a.txt"].content, "colleague")
    expect.eq(state.manifest["a.txt"], entry(OLD, "one"))
    expect.truthy(state.unsynced["a.txt"])
    finish(scratch)
  end)

  it("overwrites the server copy when the user chooses to", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD + 5, content = "colleague" } })
    prompt_with(1)
    write_file(root .. "/a.txt", "mine", OLD + 10)

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(server.files["a.txt"].content, "mine")
    expect.eq(state.manifest["a.txt"], entry(OLD + 10, "mine"))
    expect.is_nil(state.unsynced["a.txt"])
    finish(scratch)
  end)

  it("flags a file deleted on the server since the last sync instead of recreating it", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, {})
    local prompts = prompt_with(3)
    write_file(root .. "/a.txt", "mine", OLD + 10)

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    stub.restore_all()

    expect.eq(#prompts, 1)
    expect.is_nil(server.files["a.txt"])
    finish(scratch)
  end)

  it("does not push when the server copy cannot be read", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD, content = "one" } })
    server.stat_answers["a.txt"] = "E"
    local notes = stub.notifications()
    no_prompt()
    write_file(root .. "/a.txt", "mine", OLD + 10)

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(server.pushed, {})
    expect.eq(state.manifest["a.txt"], entry(OLD, "one"))
    expect.truthy(state.unsynced["a.txt"])
    expect.contains(notes[1].message, "could not check a.txt")
    finish(scratch)
  end)

  it("leaves the file dirty and notifies when the connection cannot be restored", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a.txt"] = { mtime = OLD, content = "one" } })
    local server = fake_server(root, { ["a.txt"] = { mtime = OLD, content = "one" } })
    package.loaded["sshfs.lib.sshfs"] = {
      authenticate = function(_, callback)
        callback({ success = false })
      end,
    }
    local notes = stub.notifications()
    no_prompt()
    write_file(root .. "/a.txt", "mine", OLD + 10)
    server.ssh_failures = 1

    require("sshfs.lib.mirror").enqueue(root, "a.txt")
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(server.pushed, {})
    expect.eq(state.manifest["a.txt"], entry(OLD, "one"))
    expect.truthy(state.unsynced["a.txt"])
    expect.eq(notes[1].level, vim.log.levels.ERROR)
    finish(scratch)
  end)

  it("uses a fresh include list per push and removes it afterwards", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {})
    local server = fake_server(root)
    no_prompt()
    write_file(root .. "/a", "a", OLD)
    write_file(root .. "/b", "b", OLD)
    local Mirror = require("sshfs.lib.mirror")
    Mirror.enqueue(root, "a")
    settle()
    Mirror.enqueue(root, "b")
    settle()
    stub.restore_all()

    expect.eq(#server.exclude_files, 2)
    expect.truthy(server.exclude_files[1] ~= server.exclude_files[2])
    expect.eq(vim.fn.filereadable(server.exclude_files[1]), 0)
    finish(scratch)
  end)
end)

-- Push all -----------------------------------------------------------------------------------------------------

describe("Mirror.push_all", function()
  local function run(root, opts)
    local result
    require("sshfs.lib.mirror").push_all(root, opts, function(r)
      result = r
    end)
    settle()
    return result
  end

  it("pushes only locally changed files and never reverts a server change", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["app.py"] = { mtime = OLD, content = "v1" },
      ["README.md"] = { mtime = OLD, content = "readme" },
    })
    local server = fake_server(root, {
      ["app.py"] = { mtime = OLD + 50, content = "colleague's v2" },
      ["README.md"] = { mtime = OLD, content = "readme" },
    })
    no_prompt()
    write_file(root .. "/README.md", "edited outside Neovim", OLD + 60)

    local result = run(root, {})
    stub.restore_all()

    expect.eq(result.ok, true)
    expect.eq(server.pushed, { { "README.md" } })
    expect.eq(server.files["app.py"].content, "colleague's v2")
    finish(scratch)
  end)

  it("asks about locally changed files the server changed too, and can keep the server copies", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["a"] = { mtime = OLD, content = "a" },
      ["b"] = { mtime = OLD, content = "b" },
    })
    local server = fake_server(root, {
      ["a"] = { mtime = OLD + 5, content = "server a" },
      ["b"] = { mtime = OLD, content = "b" },
    })
    local prompts = prompt_with(2)
    write_file(root .. "/a", "local a", OLD + 10)
    write_file(root .. "/b", "local b", OLD + 10)

    local result = run(root, {})
    local state = load_state(root)
    stub.restore_all()

    expect.contains(prompts[1].prompt, "1 file(s) changed on box")
    expect.eq(server.pushed, { { "b" } })
    expect.eq(server.files["a"].content, "server a")
    expect.eq(result.conflicts, { "a" })
    expect.truthy(state.unsynced["a"])
    finish(scratch)
  end)

  it("with delete, removes only manifest files deleted locally that the server still has unchanged", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["gone"] = { mtime = OLD, content = "x" },
      ["gone-but-edited-on-server"] = { mtime = OLD, content = "y" },
      ["kept"] = { mtime = OLD, content = "k" },
    })
    -- An excluded path the manifest still lists from an older configuration
    require("sshfs.lib.mirror_state").apply(root, { ["node_modules/m.js"] = entry(OLD, "m") }, {})
    os.remove(root .. "/gone")
    os.remove(root .. "/gone-but-edited-on-server")
    local server = fake_server(root, {
      ["gone"] = { mtime = OLD, content = "x" },
      ["gone-but-edited-on-server"] = { mtime = OLD + 9, content = "yy" },
      ["kept"] = { mtime = OLD, content = "k" },
      ["node_modules/m.js"] = { mtime = OLD, content = "m" },
      ["created-on-server"] = { mtime = OLD, content = "new" },
      [".git/HEAD"] = { mtime = OLD, content = "ref" },
    })
    local prompts = prompt_with(1)

    local result = run(root, { delete = true })
    local state = load_state(root)
    stub.restore_all()

    expect.eq(#prompts, 2, "one prompt for the server-changed file, one confirming the delete")
    expect.contains(prompts[2].prompt, "Delete 1 file(s)")
    expect.contains(prompts[2].prompt, "gone")
    expect.eq(server.deleted, { "gone" })
    expect.truthy(server.files["gone-but-edited-on-server"])
    expect.truthy(server.files["node_modules/m.js"])
    expect.truthy(server.files["created-on-server"])
    expect.truthy(server.files[".git/HEAD"])
    expect.is_nil(state.manifest["gone"])
    expect.eq(result.deleted, 1)
    finish(scratch)
  end)

  it("deletes nothing when the confirmation is cancelled", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["gone"] = { mtime = OLD, content = "x" } })
    os.remove(root .. "/gone")
    local server = fake_server(root, { ["gone"] = { mtime = OLD, content = "x" } })
    prompt_with(3)

    local result = run(root, { delete = true })
    stub.restore_all()

    expect.eq(result.message, "cancelled")
    expect.eq(server.deleted, {})
    finish(scratch)
  end)
end)

-- Pull ---------------------------------------------------------------------------------------------------------

describe("Mirror.pull", function()
  local function run(root)
    local result
    require("sshfs.lib.mirror").pull(root, function(r)
      result = r
    end)
    settle()
    return result
  end

  it("keeps locally edited files and reports only those the server changed since the last sync", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["mine-only"] = { mtime = OLD, content = "1" },
      ["both"] = { mtime = OLD, content = "1" },
      ["server-only"] = { mtime = OLD, content = "1" },
    })
    write_file(root .. "/mine-only", "local edit", OLD + 10)
    write_file(root .. "/both", "local edit", OLD + 10)
    fake_server(root, {
      ["mine-only"] = { mtime = OLD, content = "1" },
      ["both"] = { mtime = OLD + 5, content = "server edit" },
      ["server-only"] = { mtime = OLD + 5, content = "server edit" },
    })

    local result = run(root)
    local state = load_state(root)
    stub.restore_all()

    expect.eq(result.kept, { "both", "mine-only" })
    expect.eq(result.conflicts, { "both" })
    expect.eq(read_file(root .. "/both"), "local edit")
    expect.eq(read_file(root .. "/server-only"), "server edit")
    expect.eq(state.manifest["server-only"], entry(OLD + 5, "server edit"))
    expect.eq(state.manifest["both"], entry(OLD, "1"), "a kept file keeps its old manifest entry")
    finish(scratch)
  end)

  it("does not record a file saved during the pull as synced", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["untouched"] = { mtime = OLD, content = "1" },
      ["changed"] = { mtime = OLD, content = "1" },
    })
    local fresh_mtime = os.time() + 5
    local server = fake_server(root, {
      ["untouched"] = { mtime = OLD, content = "1" },
      ["changed"] = { mtime = OLD + 5, content = "server" },
      ["fresh"] = { mtime = fresh_mtime, content = "just written on the server" },
    })
    server.on_pull = function()
      -- A save in this or another instance while rsync runs
      write_file(root .. "/untouched", "saved during the pull")
    end

    run(root)
    local Mirror = require("sshfs.lib.mirror")
    local state = load_state(root)
    local dirty = Mirror.dirty_files(state.manifest, Mirror.snapshot(root, {}), {})
    stub.restore_all()

    expect.eq(state.manifest["untouched"], entry(OLD, "1"))
    expect.eq(dirty, { "untouched" })
    expect.eq(state.manifest["changed"], entry(OLD + 5, "server"))
    expect.eq(state.manifest["fresh"], entry(fresh_mtime, "just written on the server"))
    finish(scratch)
  end)

  it("holds saves until the pull is done", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {})
    local server = fake_server(root, {})
    no_prompt()
    local Mirror = require("sshfs.lib.mirror")
    local pushed_during_pull
    server.on_pull = function()
      write_file(root .. "/a", "a")
      Mirror.enqueue(root, "a")
      pushed_during_pull = #server.pushed
    end

    Mirror.pull(root, function() end)
    settle()
    stub.restore_all()

    expect.eq(pushed_during_pull, 0)
    expect.eq(server.pushed, { { "a" } })
    finish(scratch)
  end)

  it("uses its own skip list file and removes it", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    write_file(root .. "/a", "local", OLD + 1)
    local server = fake_server(root, { ["a"] = { mtime = OLD, content = "1" } })

    run(root)
    run(root)
    stub.restore_all()

    expect.eq(#server.exclude_files, 2)
    expect.truthy(server.exclude_files[1] ~= server.exclude_files[2])
    expect.eq(vim.fn.filereadable(server.exclude_files[1]), 0)
    expect.eq(server.pull_skips[1], { "a" })
    finish(scratch)
  end)
end)

-- Exit ---------------------------------------------------------------------------------------------------------

describe("Mirror exit", function()
  it("never prompts while exiting, and keeps conflicts for the next session", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    local server = fake_server(root, { ["a"] = { mtime = OLD + 5, content = "server" } })
    -- Recorded rather than raised: the prompt would come from a scheduled callback, where an error is not a failure
    local prompts = prompt_with(1)
    local notes = stub.notifications()
    write_file(root .. "/a", "mine", OLD + 10)
    local Mirror = require("sshfs.lib.mirror")

    Mirror.enqueue(root, "a")
    Mirror.flush_on_exit(1000)
    vim.wait(50)
    local state = load_state(root)
    stub.restore_all()

    expect.eq(#prompts, 0)
    expect.eq(server.pushed, {})
    expect.truthy(state.unsynced["a"])
    expect.eq(state.manifest["a"], entry(OLD, "1"))
    local warned = vim.tbl_filter(function(note)
      return note.message:find("not on the server", 1, true) ~= nil
    end, notes)
    expect.eq(#warned, 1)
    finish(scratch)
  end)

  it("does not re-authenticate for a pull or push-all started before exit", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    local server = fake_server(root, { ["a"] = { mtime = OLD, content = "1" } })
    server.ssh_failures = 20
    package.loaded["sshfs.lib.sshfs"] = {
      authenticate = function()
        error("must not authenticate while exiting")
      end,
    }
    no_prompt()
    write_file(root .. "/a", "mine", OLD + 10)
    local Mirror = require("sshfs.lib.mirror")
    Mirror.begin_exit()

    local pulled, pushed
    Mirror.pull(root, function(result)
      pulled = result
    end)
    Mirror.push_all(root, { delete = true }, function(result)
      pushed = result
    end)
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(pulled.ok, false)
    expect.eq(pushed.ok, false)
    expect.contains(pushed.message, "could not check the server copies")
    expect.eq(state.manifest["a"], entry(OLD, "1"))
    finish(scratch)
  end)

  it("does not prompt in push-all while exiting: conflicts stay unsynced and deletes are kept", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["edited"] = { mtime = OLD, content = "1" },
      ["removed"] = { mtime = OLD, content = "2" },
    })
    local server = fake_server(root, {
      ["edited"] = { mtime = OLD + 5, content = "server" },
      ["removed"] = { mtime = OLD, content = "2" },
    })
    no_prompt()
    write_file(root .. "/edited", "mine", OLD + 10)
    os.remove(root .. "/removed")
    local Mirror = require("sshfs.lib.mirror")
    Mirror.begin_exit()

    local result
    Mirror.push_all(root, { delete = true }, function(r)
      result = r
    end)
    settle()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(result.ok, true)
    expect.eq(result.conflicts, { "edited" })
    expect.eq(server.deleted, {})
    expect.eq(server.pushed, {})
    expect.truthy(state.unsynced["edited"])
    expect.eq(state.manifest["removed"], entry(OLD, "2"))
    finish(scratch)
  end)

  it("records queued files as unsynced before waiting on them", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    -- Every call hangs: nothing ever answers, as with a dead network
    stub.vim_system(function()
      return nil
    end)
    stub.set("system", function() end)
    write_file(root .. "/a", "mine", OLD + 10)
    local Mirror = require("sshfs.lib.mirror")

    Mirror.enqueue(root, "a")
    Mirror.begin_exit()
    local state = load_state(root)
    stub.restore_all()

    expect.eq(state.unsynced["a"], "not pushed before Neovim exited")
    finish(scratch)
  end)

  it("reports files left unsynced by an earlier session and forgets those since resolved", function()
    local scratch = with_scratch()
    local root = synced_mirror(scratch, {
      ["still"] = { mtime = OLD, content = "1" },
      ["resolved"] = { mtime = OLD, content = "1" },
    })
    write_file(root .. "/still", "edited", OLD + 1)
    require("sshfs.lib.mirror_state").apply(root, {}, { still = "conflict", resolved = "conflict" })
    local notes = stub.notifications()

    require("sshfs.lib.mirror").report_unsynced(root)
    local state = load_state(root)
    stub.restore_all()

    expect.eq(#notes, 1)
    expect.contains(notes[1].message, "still (conflict)")
    expect.eq(vim.tbl_keys(state.unsynced), { "still" })
    finish(scratch)
  end)
end)

-- Disconnect ---------------------------------------------------------------------------------------------------

describe("Mirror disconnect with on_disconnect = delete", function()
  local function disconnect(root)
    require("sshfs.session").disconnect_mirror({ host = "box", local_path = root, mount_path = root }, true)
    return vim.fn.isdirectory(root) == 1
  end

  it("deletes a clean mirror", function()
    local scratch = with_scratch({ mirror = { on_disconnect = "delete" } })
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    stub.notifications()

    local kept = disconnect(root)
    stub.restore_all()

    expect.falsy(kept)
    finish(scratch)
  end)

  it("keeps a mirror with unpushed files", function()
    local scratch = with_scratch({ mirror = { on_disconnect = "delete" } })
    local root = synced_mirror(scratch, { ["a"] = { mtime = OLD, content = "1" } })
    write_file(root .. "/a", "edited", OLD + 1)
    local notes = stub.notifications()

    local kept = disconnect(root)
    stub.restore_all()

    expect.truthy(kept)
    expect.contains(notes[1].message, "not on the server")
    finish(scratch)
  end)

  it("keeps a mirror whose .git has local commits since the last pull", function()
    local scratch = with_scratch({ mirror = { on_disconnect = "delete" } })
    local root = synced_mirror(scratch, {})
    write_file(root .. "/.git/HEAD", "ref: refs/heads/main\n", OLD)
    write_file(root .. "/.git/refs/heads/main", "aaaa\n", OLD)
    local Mirror = require("sshfs.lib.mirror")
    require("sshfs.lib.mirror_state").update(root, function(state)
      state.git_fingerprint = Mirror.git_fingerprint(root)
    end)
    write_file(root .. "/.git/refs/heads/main", "bbbb\n", OLD + 1)
    local notes = stub.notifications()

    local kept = disconnect(root)
    stub.restore_all()

    expect.truthy(kept)
    expect.contains(notes[1].message, ".git has local commits")
    finish(scratch)
  end)
end)

-- Paths --------------------------------------------------------------------------------------------------------

describe("Mirror.open remote paths", function()
  --- Open a mirror for a requested path against a server whose accounts have the given home directories
  local function open(requested, homes)
    local scratch = with_scratch()
    local root = scratch .. "/mirrors/box_srv_app"
    fake_server(root, {})
    package.loaded["sshfs.lib.sshfs"] = {
      authenticate = function(_, callback)
        callback({ success = true })
      end,
    }
    local looked_up = {}
    require("sshfs.lib.ssh").get_remote_home = function(_, callback, user)
      table.insert(looked_up, user or "")
      local home = homes[user or ""]
      if home then return callback(home) end
      callback(nil, "no such user")
    end

    local result
    require("sshfs.lib.mirror").open({ name = "box", user = "me" }, requested, root, function(r)
      result = r
    end)
    vim.wait(1000, function()
      return result ~= nil
    end)
    stub.restore_all()
    return result, looked_up, scratch
  end

  local HOMES = { [""] = "/home/me", other = "/srv/other" }

  it("resolves ~ and ~/x against the login user's home", function()
    local result, looked_up, scratch = open("~", HOMES)
    expect.eq(result.resolved_path, "/home/me")
    finish(scratch)
    result, _, scratch = open("~/proj", HOMES)
    expect.eq(result.resolved_path, "/home/me/proj")
    expect.eq(looked_up, { "" })
    finish(scratch)
  end)

  it("resolves ~user/x against that account's home", function()
    local result, looked_up, scratch = open("~other/proj", HOMES)
    expect.eq(result.resolved_path, "/srv/other/proj")
    expect.eq(looked_up, { "other" })
    finish(scratch)
  end)

  it("refuses an account name that is not a plain name, before anything reaches a shell", function()
    local result, looked_up, scratch = open("~x;reboot/proj", HOMES)
    expect.eq(result.success, false)
    expect.contains(result.message, "x;reboot")
    expect.eq(looked_up, {})
    finish(scratch)
  end)

  it("keeps a path without a tilde as given", function()
    local result, looked_up, scratch = open("/srv/app", HOMES)
    expect.eq(result.resolved_path, "/srv/app")
    expect.eq(looked_up, {})
    finish(scratch)
  end)
end)

describe("Mirror.find_for_path", function()
  it("finds the mirror for a buffer named by the resolved path of a symlinked base directory", function()
    local outer = vim.fn.tempname()
    vim.fn.mkdir(outer .. "/real", "p")
    vim.uv.fs_symlink(outer .. "/real", outer .. "/link")
    local scratch = with_scratch({ mirror = { base_dir = outer .. "/link" } })
    require("sshfs.lib.mirror_state").save({
      host = "box",
      remote_path = "/srv",
      local_path = outer .. "/link/box_srv",
      manifest = {},
    })

    local Mirror = require("sshfs.lib.mirror")
    local via_link, rel_link = Mirror.find_for_path(outer .. "/link/box_srv/a/b.lua")
    local via_real, rel_real = Mirror.find_for_path(vim.uv.fs_realpath(outer .. "/real") .. "/box_srv/a/b.lua")
    stub.restore_all()

    expect.eq(via_link and via_link.local_path, outer .. "/link/box_srv")
    expect.eq(rel_link, "a/b.lua")
    expect.eq(via_real and via_real.local_path, outer .. "/link/box_srv")
    expect.eq(rel_real, "a/b.lua")
    finish(scratch)
    vim.fn.delete(outer, "rf")
  end)
end)

describe("Mirror host patterns", function()
  it("matches names and wildcards", function()
    local Mirror = require("sshfs.lib.mirror")
    expect.truthy(Mirror.matches_hosts("prod-1", { "prod-*" }))
    expect.truthy(Mirror.matches_hosts("box.example.com", { "box.example.com" }))
    expect.falsy(Mirror.matches_hosts("boxxexample.com", { "box.example.com" }))
    expect.falsy(Mirror.matches_hosts("dev", { "prod-*" }))
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
