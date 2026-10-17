-- tests/mirror_delete_spec.lua
-- Deleting local mirrors: the list, the guards that keep work and foreign paths safe, and the removal.

local OLD = 1000000 -- an mtime long before any test runs

--- Load the plugin against a scratch state dir and mirror base; returns the scratch dir
local function with_scratch()
  stub.reload()
  -- Resolved, because mirrors are listed by their canonical path (temp dirs sit under a symlink on macOS)
  local scratch = vim.fn.tempname()
  vim.fn.mkdir(scratch .. "/mirrors", "p")
  scratch = vim.uv.fs_realpath(scratch)

  local real_stdpath = vim.fn.stdpath
  stub.set("fn.stdpath", function(what)
    if what == "state" then return scratch .. "/state" end
    if what == "cache" then return scratch .. "/cache" end
    return real_stdpath(what)
  end)
  stub.executable({ findmnt = false, rsync = true })
  stub.system(function()
    return "", 0
  end)
  require("sshfs.config").setup({
    mounts = { base_dir = scratch .. "/mounts" },
    connections = { socket_dir = "/s" },
    mirror = { base_dir = scratch .. "/mirrors" },
  })
  return scratch
end

local function finish(scratch)
  stub.restore_all()
  vim.fn.delete(scratch, "rf")
end

local function write_file(path, content, mtime)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
  if mtime then vim.uv.fs_utime(path, mtime, mtime) end
end

--- A mirror folder in the base directory whose manifest matches its one synced file
local function make_mirror(scratch, name, fields)
  local path = scratch .. "/mirrors/" .. name
  write_file(path .. "/a.txt", "1", OLD)
  local state = vim.tbl_extend("force", {
    host = "box",
    user = "me",
    remote_path = "/srv/" .. name,
    local_path = path,
    manifest = { ["a.txt"] = string.format("%d %d", OLD, 1) },
    unsynced = {},
    connected = false,
  }, fields or {})
  require("sshfs.lib.mirror_state").save(state)
  return path
end

local function state_exists(path)
  return require("sshfs.lib.mirror_state").load(path) ~= nil
end

local function exists(path)
  return vim.uv.fs_lstat(path) ~= nil
end

--- Answer every vim.ui.select: a confirmation with the choice starting with `choice`, any other list with its
--- first item; records the prompts and item lists
local function answer(choice)
  local asked = {}
  stub.set("ui.select", function(items, opts, callback)
    table.insert(asked, { items = items, prompt = opts.prompt, format_item = opts.format_item })
    for index, item in ipairs(items) do
      if type(item) == "string" and vim.startswith(item, choice) then return callback(item, index) end
    end
    callback(items[1], 1)
  end)
  return asked
end

local function run(entry_path, opts)
  local MirrorDelete = require("sshfs.lib.mirror_delete")
  for _, entry in ipairs(MirrorDelete.entries()) do
    if entry.local_path == entry_path then return MirrorDelete.run(entry, opts or {}) end
  end
  error("no entry for " .. entry_path)
end

local function messages(notes)
  return table.concat(
    vim.tbl_map(function(note)
      return note.message
    end, notes),
    "\n"
  )
end

describe("Mirror delete", function()
  it("deletes the folder and the state file after one confirmation", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    local asked = answer("Delete")

    run(path)
    local gone = not exists(path) and not state_exists(path)
    finish(scratch)

    expect.eq(#asked, 1)
    expect.contains(asked[1].prompt, "Delete local mirror " .. path .. "?")
    expect.truthy(gone)
  end)

  it("keeps everything when the confirmation is cancelled", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    answer("Cancel")

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
  end)

  it("refuses a mirror with unpushed files and says what would be lost", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    write_file(path .. "/a.txt", "edited", OLD + 10)
    local asked = answer("Delete")
    local notes = stub.notifications()

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.eq(#asked, 0)
    expect.truthy(kept)
    expect.contains(messages(notes), "a.txt")
    expect.contains(messages(notes), "SSHMirrorDelete!")
  end)

  it("refuses a mirror with local git work unless forced", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app", { git_fingerprint = "old" })
    vim.fn.mkdir(path .. "/.git/refs/heads", "p")
    write_file(path .. "/.git/refs/heads/feature", "abc\n")
    answer("Delete")
    local notes = stub.notifications()

    run(path)
    local kept = exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), ".git")
  end)

  it("deletes work only with force, after a confirmation that lists it", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    write_file(path .. "/a.txt", "edited", OLD + 10)

    answer("Cancel")
    run(path, { force = true })
    local kept_when_cancelled = exists(path)

    local asked = answer("Delete")
    local notes = stub.notifications()
    run(path, { force = true })
    local gone = not exists(path) and not state_exists(path)
    finish(scratch)

    expect.truthy(kept_when_cancelled)
    expect.truthy(gone)
    expect.eq(asked[1].items[1], "Cancel")
    expect.contains(asked[1].items[2], "1 file(s)")
    expect.contains(messages(notes), "loses")
    expect.contains(messages(notes), "a.txt")
  end)

  it("refuses a mirror another Neovim instance holds", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app", { connected = true })
    require("sshfs.lib.lockfile").is_in_use_by_others = function()
      return true
    end
    local asked = answer("Delete")
    local notes = stub.notifications()

    run(path, { force = true })
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.eq(#asked, 0)
    expect.truthy(kept)
    expect.contains(messages(notes), "another Neovim instance")
  end)

  it("disconnects a mirror connected here first, then deletes it", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app", { connected = true })
    require("sshfs.lib.lockfile").register(path)
    answer("Delete")
    local disconnected_with_folder
    require("sshfs.session").disconnect_from = function(connection)
      disconnected_with_folder = exists(path) and state_exists(path) and connection.local_path == path
      require("sshfs.lib.lockfile").unregister(path)
      require("sshfs.lib.mirror_state").update(path, function(state)
        state.connected = false
      end)
      return true
    end

    run(path)
    local gone = not exists(path) and not state_exists(path)
    finish(scratch)

    expect.truthy(disconnected_with_folder)
    expect.truthy(gone)
  end)

  it("keeps the mirror when the disconnect fails", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app", { connected = true })
    require("sshfs.lib.lockfile").register(path)
    answer("Delete")
    require("sshfs.session").disconnect_from = function()
      return false
    end

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
  end)

  it("removes only the state file of a mirror whose folder is gone", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    vim.fn.delete(path, "rf")
    write_file(scratch .. "/mirrors/other/keep.txt", "x")
    local asked = answer("Remove")

    local entry = vim.tbl_filter(function(item)
      return item.local_path == path
    end, require("sshfs.lib.mirror_delete").entries())[1]
    require("sshfs.lib.mirror_delete").run(entry, {})
    local state_gone, other_kept = not state_exists(path), exists(scratch .. "/mirrors/other/keep.txt")
    finish(scratch)

    expect.eq(entry.status, "folder missing")
    expect.contains(asked[1].prompt, "missing mirror")
    expect.truthy(state_gone)
    expect.truthy(other_kept)
  end)

  it("lists a folder without a sync record and deletes it after a confirmation", function()
    local scratch = with_scratch()
    write_file(scratch .. "/mirrors/stray/file.txt", "x")
    local asked = answer("Delete")

    local entries = require("sshfs.lib.mirror_delete").entries()
    run(scratch .. "/mirrors/stray")
    local gone = not exists(scratch .. "/mirrors/stray")
    finish(scratch)

    expect.eq(#entries, 1)
    expect.eq(entries[1].status, "no sync record")
    expect.contains(asked[1].prompt, "no sync record")
    expect.truthy(gone)
  end)

  it("refuses a state whose folder is outside the base directory", function()
    local scratch = with_scratch()
    local outside = scratch .. "/outside"
    write_file(outside .. "/precious.txt", "x")
    require("sshfs.lib.mirror_state").save({
      host = "box",
      remote_path = "/srv",
      local_path = outside,
      manifest = {},
      unsynced = {},
      connected = false,
    })
    answer("Delete")
    local notes = stub.notifications()

    run(outside, { force = true })
    local kept = exists(outside .. "/precious.txt")
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "outside")
  end)

  it("refuses a mirror folder that is a symlink out of the base directory", function()
    local scratch = with_scratch()
    local outside = scratch .. "/outside"
    write_file(outside .. "/precious.txt", "x")
    vim.uv.fs_symlink(outside, scratch .. "/mirrors/link")
    answer("Delete")
    local notes = stub.notifications()

    run(scratch .. "/mirrors/link")
    local kept = exists(outside .. "/precious.txt")
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "not a plain directory")
  end)

  it("refuses a folder reached through a symlinked parent that leads out of the base directory", function()
    local scratch = with_scratch()
    write_file(scratch .. "/outside/inner/precious.txt", "x")
    vim.uv.fs_symlink(scratch .. "/outside", scratch .. "/mirrors/hop")
    local ok, reason = require("sshfs.lib.mirror_delete").check_path(scratch .. "/mirrors/hop/inner")
    finish(scratch)

    expect.falsy(ok)
    expect.contains(reason, "resolves outside")
  end)

  it("refuses the base directory itself and paths that are not normalized", function()
    local scratch = with_scratch()
    local function allowed(path)
      return (require("sshfs.lib.mirror_delete").check_path(path))
    end
    write_file(scratch .. "/outside/x", "x")

    local results = {
      allowed(scratch .. "/mirrors"),
      allowed(scratch .. "/mirrors/../outside"),
      allowed(scratch .. "/mirrors/box/../../outside"),
      allowed("mirrors/box"),
    }
    finish(scratch)

    for _, ok in ipairs(results) do
      expect.falsy(ok)
    end
  end)

  it("labels each entry with host, remote path, local path and status", function()
    local scratch = with_scratch()
    local held = make_mirror(scratch, "box_held", { connected = true })
    local other = make_mirror(scratch, "box_other", { connected = true })
    local worked = make_mirror(scratch, "box_worked")
    local missing = make_mirror(scratch, "box_missing")
    write_file(worked .. "/a.txt", "edited", OLD + 10)
    vim.fn.delete(missing, "rf")
    write_file(scratch .. "/mirrors/stray/x", "x")
    -- held: this instance; other: some other live process
    local Lockfile = require("sshfs.lib.lockfile")
    Lockfile.register(held)
    local real_held = Lockfile.is_held_by_this_instance
    Lockfile.is_held_by_this_instance = function(path)
      return path == held and real_held(path)
    end
    Lockfile.has_live_owner = function(path)
      return path == held or path == other
    end

    local labels = {}
    for _, entry in ipairs(require("sshfs.lib.mirror_delete").entries()) do
      labels[vim.fn.fnamemodify(entry.local_path, ":t")] = entry.label
    end
    local entries = require("sshfs.lib.mirror_delete").entries()
    finish(scratch)

    expect.eq(#entries, 5)
    expect.contains(labels.box_held, "box: /srv/box_held -> ")
    expect.contains(labels.box_held, "(connected here)")
    expect.contains(labels.box_other, "(connected in another instance)")
    expect.contains(labels.box_worked, "(disconnected, has unpushed work)")
    expect.contains(labels.box_missing, "(folder missing)")
    expect.contains(labels.stray, "(no sync record)")
  end)
end)

describe("Api.mirror_delete", function()
  it("with no host offers every mirror through vim.ui.select", function()
    local scratch = with_scratch()
    make_mirror(scratch, "box_a")
    make_mirror(scratch, "box_b", { host = "other" })
    local asked = answer("Delete")

    require("sshfs.api").mirror_delete()
    finish(scratch)

    expect.eq(#asked, 2)
    expect.eq(#asked[1].items, 2)
    expect.contains(asked[1].format_item(asked[1].items[1]), "box: /srv/box_a -> ")
    expect.contains(asked[2].prompt, "Delete local mirror")
  end)

  it("with a host acts on that host's mirror directly, and asks only when it has several", function()
    local scratch = with_scratch()
    make_mirror(scratch, "box_a")
    make_mirror(scratch, "other_a", { host = "other" })

    local asked = answer("Cancel")
    require("sshfs.api").mirror_delete("other")
    local direct = #asked

    make_mirror(scratch, "box_b")
    asked = answer("Cancel")
    require("sshfs.api").mirror_delete("box")
    finish(scratch)

    expect.eq(direct, 1)
    expect.contains(asked[1].prompt, "Select mirror to delete")
    expect.eq(#asked[1].items, 2)
  end)

  it("registers the :SSHMirrorDelete command with a bang and the keymap", function()
    local scratch = with_scratch()
    require("sshfs.api").setup()
    require("sshfs.ui.keymaps").setup({})
    local command = vim.api.nvim_get_commands({})["SSHMirrorDelete"]
    local map = vim.fn.maparg((vim.g.mapleader or "\\") .. "mD", "n", false, true)
    finish(scratch)

    expect.truthy(command)
    expect.truthy(command.bang)
    expect.eq(map.desc, "Delete a local mirror")
  end)
end)

describe("Mirror delete re-checks after the confirmation", function()
  it("refuses when another instance connects while the confirmation is open", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    local Lockfile = require("sshfs.lib.lockfile")
    local notes = stub.notifications()
    stub.set("ui.select", function(items, _, callback)
      Lockfile.is_in_use_by_others = function()
        return true
      end
      Lockfile.has_live_owner = function()
        return true
      end
      require("sshfs.lib.mirror_state").update(path, function(state)
        state.connected = true
      end)
      callback(items[2], 2)
    end)

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "another Neovim instance")
  end)

  it("refuses when the disconnect keeps the mirror connected for another instance", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app", { connected = true })
    local Lockfile = require("sshfs.lib.lockfile")
    Lockfile.register(path)
    answer("Delete")
    local notes = stub.notifications()
    require("sshfs.session").disconnect_from = function()
      -- What disconnect_mirror does when another instance still holds the mirror: unregister, report success
      Lockfile.unregister(path)
      Lockfile.is_in_use_by_others = function()
        return true
      end
      Lockfile.has_live_owner = function()
        return true
      end
      return true
    end

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "still in use by another Neovim instance")
  end)

  it("with force, refuses work that appeared during the confirmation and lists it", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    write_file(path .. "/a.txt", "edited", OLD + 10)
    local notes = stub.notifications()
    stub.set("ui.select", function(items, _, callback)
      write_file(path .. "/new.txt", "precious", OLD + 20)
      callback(items[2], 2)
    end)

    run(path, { force = true })
    local kept = exists(path .. "/new.txt") and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "now has work that was not confirmed")
    expect.contains(messages(notes), "new.txt")
  end)

  it("keeps the record of a missing mirror whose folder came back during the confirmation", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    vim.fn.delete(path, "rf")
    local notes = stub.notifications()
    stub.set("ui.select", function(items, _, callback)
      write_file(path .. "/a.txt", "back", OLD + 10)
      callback(items[2], 2)
    end)

    run(path)
    local kept = exists(path .. "/a.txt") and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "exists again")
  end)

  it("offers Cancel first, so accepting the preselected choice keeps the mirror", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    local asked = {}
    stub.set("ui.select", function(items, opts, callback)
      table.insert(asked, { items = items, prompt = opts.prompt })
      callback(items[1], 1)
    end)

    run(path)
    local kept = exists(path) and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.eq(asked[1].items[1], "Cancel")
    expect.falsy(asked[1].prompt:find("\n"), "the prompt is one line")
  end)

  it("closes buffers on the deleted mirror's files", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    vim.cmd("edit " .. vim.fn.fnameescape(path .. "/a.txt"))
    local buf = vim.api.nvim_get_current_buf()
    answer("Delete")

    run(path)
    local buffer_left = vim.api.nvim_buf_is_valid(buf)
    local gone = not exists(path)
    finish(scratch)

    expect.truthy(gone)
    expect.falsy(buffer_left)
  end)
end)

describe("Mirror delete path spellings", function()
  it("matches a mirror recorded with a trailing-slash base to its folder", function()
    local scratch = with_scratch()
    require("sshfs.config").setup({
      mounts = { base_dir = scratch .. "/mounts" },
      connections = { socket_dir = "/s" },
      mirror = { base_dir = scratch .. "/mirrors/" },
    })
    -- How a mirror connected under this config was recorded before paths were canonical
    local recorded = scratch .. "/mirrors//box_app"
    write_file(recorded .. "/a.txt", "edited", OLD + 10)
    require("sshfs.lib.mirror_state").save({
      host = "box",
      remote_path = "/srv",
      local_path = recorded,
      manifest = { ["a.txt"] = "1 1" },
      unsynced = {},
      connected = false,
    })
    answer("Delete")
    local notes = stub.notifications()

    local entries = require("sshfs.lib.mirror_delete").entries()
    for _, entry in ipairs(entries) do
      require("sshfs.lib.mirror_delete").run(entry, {})
    end
    local kept = exists(scratch .. "/mirrors/box_app/a.txt")
    finish(scratch)

    expect.eq(#entries, 1)
    expect.eq(entries[1].kind, "mirror")
    expect.eq(entries[1].local_path, scratch .. "/mirrors/box_app")
    expect.truthy(kept)
    expect.contains(messages(notes), "has work that is not on the server")
  end)

  it("matches a mirror recorded through a symlinked base to its folder under the real one", function()
    local scratch = with_scratch()
    vim.uv.fs_symlink(scratch .. "/mirrors", scratch .. "/link")
    local path = make_mirror(scratch, "box_app", { local_path = scratch .. "/link/box_app" })
    write_file(path .. "/a.txt", "edited", OLD + 10)
    answer("Delete")

    local notes = stub.notifications()

    local entries = require("sshfs.lib.mirror_delete").entries()
    for _, entry in ipairs(entries) do
      require("sshfs.lib.mirror_delete").run(entry, {})
    end
    local kept = exists(path .. "/a.txt")
    finish(scratch)

    expect.eq(#entries, 1)
    expect.eq(entries[1].kind, "mirror")
    expect.truthy(kept)
    expect.contains(messages(notes), "has work that is not on the server")
  end)

  it("records new mirrors under the canonical base whatever its spelling", function()
    local scratch = with_scratch()
    vim.uv.fs_symlink(scratch .. "/mirrors", scratch .. "/link")
    require("sshfs.config").setup({
      mounts = { base_dir = scratch .. "/mounts" },
      connections = { socket_dir = "/s" },
      mirror = { base_dir = scratch .. "/link/" },
    })
    local base = require("sshfs.lib.mirror_state").base_dir()
    local real = vim.uv.fs_realpath(scratch .. "/mirrors")
    finish(scratch)

    expect.eq(base, real)
  end)
end)

describe("Mirror delete never reaches a mount", function()
  local function mount_table(lines)
    stub.system(function(cmd)
      if cmd == "mount" then return table.concat(lines, "\n"), 0 end
      return "", 0
    end)
  end

  it("refuses a folder in the base directory that is an active sshfs mount", function()
    local scratch = with_scratch()
    local path = scratch .. "/mirrors/box_srv"
    write_file(path .. "/remote.txt", "on the server")
    mount_table({ "me@box:/srv on " .. vim.uv.fs_realpath(path) .. " type fuse.sshfs (rw)" })
    answer("Delete")
    local notes = stub.notifications()

    run(path)
    local kept = exists(path .. "/remote.txt")
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "active mount")
  end)

  it("refuses a mirror with an sshfs mount inside it", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    write_file(path .. "/nested/remote.txt", "on the server")
    mount_table({ "me@box:/srv on " .. vim.uv.fs_realpath(path) .. "/nested type fuse.sshfs (rw)" })
    answer("Delete")
    local notes = stub.notifications()

    run(path, { force = true })
    local kept = exists(path .. "/nested/remote.txt")
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "contains the active mount")
  end)

  it("refuses a folder on another device than the base directory", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    local real_lstat = vim.uv.fs_lstat
    stub.set("uv.fs_lstat", function(target)
      local stat = real_lstat(target)
      if stat and target == path then stat.dev = stat.dev + 1 end
      return stat
    end)
    answer("Delete")
    local notes = stub.notifications()

    run(path)
    local kept = exists(path .. "/a.txt")
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "another file system")
  end)

  it("removes nothing when a directory inside the mirror is on another device", function()
    local scratch = with_scratch()
    local path = make_mirror(scratch, "box_app")
    write_file(path .. "/deep/inner/remote.txt", "elsewhere")
    local real_lstat = vim.uv.fs_lstat
    stub.set("uv.fs_lstat", function(target)
      local stat = real_lstat(target)
      if stat and target == path .. "/deep/inner" then stat.dev = stat.dev + 1 end
      return stat
    end)
    answer("Delete")
    local notes = stub.notifications()

    run(path, { force = true })
    local kept = exists(path .. "/a.txt") and exists(path .. "/deep/inner/remote.txt") and state_exists(path)
    finish(scratch)

    expect.truthy(kept)
    expect.contains(messages(notes), "deep/inner is on another file system")
  end)

  it("refuses every mirror command when the mount and mirror base directories overlap", function()
    local scratch = with_scratch()
    local notes = stub.notifications()
    require("sshfs.config").setup({
      mounts = { base_dir = scratch .. "/mirrors/mnt" },
      connections = { socket_dir = "/s" },
      mirror = { base_dir = scratch .. "/mirrors" },
    })
    write_file(scratch .. "/mirrors/stray/x", "x")
    local asked = answer("Delete")

    require("sshfs.api").mirror_delete()
    local kept = exists(scratch .. "/mirrors/stray/x")
    finish(scratch)

    expect.truthy(kept)
    expect.eq(#asked, 0)
    expect.contains(messages(notes), "overlap")
  end)
end)
