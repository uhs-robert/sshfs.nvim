-- tests/git_route_spec.lua
-- Git routing over SSH: the real sh wrapper runs against fake `ssh` and `git` executables

local GitRoute = require("sshfs.lib.git_route")

local FAKE_SSH = [[#!/bin/sh
# Logs argv (one per line, then a delimiter) and stdin, then behaves as FAKE_SSH_* dictate.
# `-O check` probes are logged separately and answered by FAKE_CHECK_EXIT.
for a in "$@"; do
  if [ "$a" = "-O" ]; then
    echo probe >>"$FAKE_DIR/ssh_check.log"
    exit "${FAKE_CHECK_EXIT:-0}"
  fi
done
{ for a in "$@"; do printf '%s\n' "$a"; done; echo "--END--"; } >>"$FAKE_DIR/ssh.log"
if [ "$FAKE_SSH_READS_STDIN" = 1 ]; then cat >"$FAKE_DIR/ssh.stdin"; fi
[ -z "$FAKE_SSH_SLEEP" ] || sleep "$FAKE_SSH_SLEEP"
printf '%s' "$FAKE_SSH_STDOUT"
exit "${FAKE_SSH_EXIT:-0}"
]]

local FAKE_GIT = [[#!/bin/sh
echo "real git ran in $(pwd -P): $*" >>"$FAKE_DIR/git.log"
if [ -n "$FAKE_GIT_READS_STDIN" ]; then cat >"$FAKE_DIR/git.stdin"; fi
echo "local-git-output"
exit "${FAKE_GIT_EXIT:-0}"
]]

local function write_executable(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  vim.uv.fs_chmod(path, 493) -- 0755
end

--- Build a sandbox: a fake mount (plain directory), map file, fake ssh/git and the rendered wrapper.
local function sandbox(opts)
  opts = opts or {}
  local root = vim.uv.fs_realpath(vim.fn.tempname() .. "_x") or vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root)
  local env = {
    root = root,
    mount = root .. "/mnt/box",
    outside = root .. "/outside",
    maps = root .. "/maps",
    bin = root .. "/bin",
    remote = opts.remote or "/srv/app",
    real_remote = opts.real_remote or "/data/app",
  }
  vim.fn.mkdir(env.outside, "p")
  vim.fn.mkdir(env.maps, "p")
  env.tmp = root .. "/tmp"
  vim.fn.mkdir(env.tmp, "p")
  if opts.symlinked_mount then
    -- The mount is reached through a symlink, so `pwd -P` shows the physical directory.
    env.physical_mount = root .. "/physical/box"
    vim.fn.mkdir(env.physical_mount .. "/sub dir", "p")
    vim.fn.mkdir(root .. "/mnt", "p")
    vim.uv.fs_symlink(env.physical_mount, env.mount)
  else
    vim.fn.mkdir(env.mount .. "/sub dir", "p")
  end
  write_executable(env.bin .. "/ssh", FAKE_SSH)
  write_executable(env.bin .. "/real_git", FAKE_GIT)

  GitRoute.write_map_to(env.maps, {
    mount_path = env.mount,
    real_mount_path = env.physical_mount or env.mount,
    host = "box",
    user = opts.user,
    port = opts.port,
    remote_path = env.remote,
    real_remote_path = env.real_remote,
  })
  local script = GitRoute.render_wrapper({
    real_git = env.bin .. "/real_git",
    map_dir = env.maps,
    ssh_options = { "ControlPath=/tmp/s/%C", "BatchMode=yes" },
  })
  write_executable(env.bin .. "/git", script)
  env.wrapper = env.bin .. "/git"
  return env
end

--- Run the wrapper and report what the fake ssh and git saw.
local function run(env, args, opts)
  opts = opts or {}
  local cmd = { env.wrapper }
  vim.list_extend(cmd, args)
  local proc_env = {
    PATH = env.bin .. ":/usr/bin:/bin",
    FAKE_DIR = env.root,
    FAKE_SSH_STDOUT = opts.ssh_stdout or "",
    FAKE_SSH_EXIT = tostring(opts.ssh_exit or 0),
    FAKE_CHECK_EXIT = tostring(opts.check_exit or 0),
    TMPDIR = env.tmp,
    FAKE_SSH_READS_STDIN = opts.stdin and "1" or "0",
    FAKE_GIT_READS_STDIN = opts.stdin and "1" or nil,
    FAKE_GIT_EXIT = tostring(opts.git_exit or 0),
  }
  for key, value in pairs(opts.env or {}) do
    proc_env[key] = value
  end
  local result = vim
    .system(
      cmd,
      -- clear_env: a CI runner's own LC_ALL would otherwise be forwarded and change the remote command
      { cwd = opts.cwd or env.mount, env = proc_env, clear_env = true, stdin = opts.stdin, text = true }
    )
    :wait()

  local ssh_calls = {}
  local current = {}
  if vim.fn.filereadable(env.root .. "/ssh.log") == 1 then
    for _, line in ipairs(vim.fn.readfile(env.root .. "/ssh.log")) do
      if line == "--END--" then
        table.insert(ssh_calls, current)
        current = {}
      else
        table.insert(current, line)
      end
    end
  end
  local git_log = vim.fn.filereadable(env.root .. "/git.log") == 1 and vim.fn.readfile(env.root .. "/git.log") or {}
  return {
    code = result.code,
    stdout = result.stdout,
    stderr = result.stderr,
    ssh_calls = ssh_calls,
    remote_cmd = ssh_calls[1] and ssh_calls[1][#ssh_calls[1]],
    git_log = git_log,
    probes = vim.fn.filereadable(env.root .. "/ssh_check.log") == 1 and #vim.fn.readfile(env.root .. "/ssh_check.log")
      or 0,
  }
end

local function cleanup(env)
  vim.fn.delete(env.root, "rf")
end

local function expect_routed(result, context)
  expect.eq(#result.ssh_calls, 1, (context or "") .. " should call ssh once")
  expect.eq(#result.git_log, 0, (context or "") .. " should not run the local git")
end

local function expect_local(result, context)
  expect.eq(#result.ssh_calls, 0, (context or "") .. " should not call ssh")
  expect.eq(#result.git_log, 1, (context or "") .. " should run the local git once")
end

describe("git wrapper routing", function()
  it("routes an allowlisted command inside a mount and cds to the remote path", function()
    local env = sandbox()
    local result = run(env, { "status", "--porcelain" })
    expect_routed(result)
    expect.eq(result.remote_cmd, "cd '/srv/app' && exec env git 'status' '--porcelain'")
    cleanup(env)
  end)

  it("passes the ControlMaster options, host, user and port to ssh", function()
    local env = sandbox({ user = "deploy", port = 2222 })
    local result = run(env, { "status" })
    local argv = result.ssh_calls[1]
    expect.eq(vim.list_slice(argv, 1, #argv - 1), {
      "-o",
      "ControlPath=/tmp/s/%C",
      "-o",
      "BatchMode=yes",
      "-n",
      "-o",
      "LogLevel=QUIET",
      "-p",
      "2222",
      "-l",
      "deploy",
      "box",
    })
    cleanup(env)
  end)

  it("maps the work dir below the mount root onto the remote path", function()
    local env = sandbox()
    local result = run(env, { "diff" }, { cwd = env.mount .. "/sub dir" })
    expect.eq(result.remote_cmd, "cd '/srv/app/sub dir' && exec env git 'diff'")
    cleanup(env)
  end)

  it("falls back for -C paths that climb with ..", function()
    local env = sandbox()
    expect_local(run(env, { "-C", "sub dir", "-C", "..", "log" }))
    cleanup(env)
  end)

  it("resolves repeated -C options, each relative to the previous", function()
    local env = sandbox()
    local result = run(env, { "-C", env.mount, "-C", "sub dir", "log" }, { cwd = env.outside })
    expect.eq(result.remote_cmd, "cd '/srv/app/sub dir' && exec env git 'log'")
    result = run(env, { "-C", "sub dir", "-C", ".", "log" })
    expect.eq(result.remote_cmd, "cd '/srv/app/sub dir' && exec env git 'log'")
    cleanup(env)
  end)

  it("routes from a mount reached through a symlink and translates its output to the logical path", function()
    local env = sandbox({ symlinked_mount = true })
    local result = run(env, { "status" }, { cwd = env.mount .. "/sub dir" })
    expect.eq(result.remote_cmd, "cd '/srv/app/sub dir' && exec env git 'status'")

    result = run(
      env,
      { "-C", env.mount, "rev-parse", "--show-toplevel" },
      { cwd = env.outside, ssh_stdout = "/data/app\n" }
    )
    expect.eq(result.stdout, env.mount .. "\n")
    cleanup(env)
  end)

  it("streams stdin to commands that read it interactively", function()
    local env = sandbox()
    local result = run(env, { "cat-file", "--batch" }, { stdin = "HEAD\n" })
    expect_routed(result)
    expect.eq(vim.fn.readfile(env.root .. "/ssh.stdin"), { "HEAD" })
    cleanup(env)
  end)

  it("uses gitsigns' global option layout", function()
    local env = sandbox()
    local result = run(env, {
      "--no-pager",
      "--no-optional-locks",
      "--literal-pathspecs",
      "-c",
      "gc.auto=0",
      "-c",
      "color.ui=false",
      "--git-dir=" .. env.mount .. "/.git",
      "--work-tree",
      env.mount,
      "rev-parse",
      "--show-toplevel",
      "--absolute-git-dir",
    }, { ssh_stdout = "/data/app\n/data/app/.git\n" })
    expect.eq(
      result.remote_cmd,
      "cd '/srv/app' && exec env git --no-pager --no-optional-locks --literal-pathspecs -c 'gc.auto=0' -c 'color.ui=false' --git-dir '/srv/app/.git' --work-tree '/srv/app' 'rev-parse' '--show-toplevel' '--absolute-git-dir'"
    )
    expect.eq(result.stdout, env.mount .. "\n" .. env.mount .. "/.git\n")
    cleanup(env)
  end)

  it("translates absolute local paths under the mount to remote paths", function()
    local env = sandbox()
    local result = run(env, { "ls-files", "--error-unmatch", "--", env.mount .. "/sub dir/f.txt" })
    expect.eq(
      result.remote_cmd,
      "cd '/srv/app' && exec env git 'ls-files' '--error-unmatch' '--' '/srv/app/sub dir/f.txt'"
    )
    cleanup(env)
  end)

  it("translates --opt=/path values and global --git-dir/--work-tree", function()
    local env = sandbox()
    local result = run(env, {
      "--no-pager",
      "-c",
      "core.quotepath=off",
      "--git-dir",
      env.mount .. "/.git",
      "--work-tree=" .. env.mount,
      "show",
      "--output-indicator-new=" .. env.mount .. "/x",
    })
    expect.eq(
      result.remote_cmd,
      "cd '/srv/app' && exec env git --no-pager -c 'core.quotepath=off' --git-dir '/srv/app/.git' --work-tree '/srv/app' 'show' '--output-indicator-new=/srv/app/x'"
    )
    cleanup(env)
  end)

  it("shell-quotes arguments with spaces and quotes", function()
    local env = sandbox()
    local result = run(env, { "log", '--grep=it\'s a "test"', "a b", "$(rm -rf x)", "" })
    expect.eq(
      result.remote_cmd,
      "cd '/srv/app' && exec env git 'log' '--grep=it'\\''s a \"test\"' 'a b' '$(rm -rf x)' ''"
    )
    cleanup(env)
  end)

  it("forwards LC_ALL to the remote git", function()
    local env = sandbox()
    local result = run(env, { "status" }, { env = { LC_ALL = "C" } })
    expect.eq(result.remote_cmd, "cd '/srv/app' && exec env LC_ALL='C' git 'status'")
    cleanup(env)
  end)

  it("routes every allowlisted subcommand", function()
    local env = sandbox()
    local cases = {
      { "rev-parse", "HEAD" },
      { "ls-files", "-s" },
      { "ls-tree", "HEAD" },
      { "diff" },
      { "show", "HEAD" },
      { "cat-file", "-p", "HEAD" },
      { "log", "-1" },
      { "blame", "f" },
      { "status" },
      { "check-attr", "-a", "f" },
      { "hash-object", "f" },
      { "update-index", "--refresh" },
      { "for-each-ref" },
      { "symbolic-ref", "HEAD" },
      { "merge-base", "a", "b" },
      { "rev-list", "HEAD" },
      { "config", "--get", "user.name" },
      { "worktree", "list" },
    }
    for _, args in ipairs(cases) do
      os.remove(env.root .. "/ssh.log")
      expect_routed(run(env, args), args[1])
    end
    cleanup(env)
  end)

  it("keeps the exit code of the remote git", function()
    local env = sandbox()
    local result = run(env, { "status" }, { ssh_exit = 128 })
    expect.eq(result.code, 128)
    expect.eq(#result.git_log, 0, "a remote failure is a result, not a reason to retry locally")
    cleanup(env)
  end)

  it("passes remote stdout through untouched for non rev-parse commands", function()
    local env = sandbox()
    local result = run(env, { "show", "HEAD:f" }, { ssh_stdout = "/srv/app/not-translated\n" })
    expect.eq(result.stdout, "/srv/app/not-translated\n")
    cleanup(env)
  end)

  it("forwards stdin for apply --cached", function()
    local env = sandbox()
    local result = run(env, { "apply", "--cached", "--unidiff-zero", "-" }, { stdin = "diff --git a/f b/f\n" })
    expect_routed(result)
    expect.eq(vim.fn.readfile(env.root .. "/ssh.stdin"), { "diff --git a/f b/f" })
    cleanup(env)
  end)
end)

describe("git wrapper output translation", function()
  it("translates rev-parse output from the real remote path to the mount", function()
    local env = sandbox()
    local result = run(
      env,
      { "rev-parse", "--show-toplevel", "--absolute-git-dir" },
      { ssh_stdout = "/data/app\n/data/app/.git\n" }
    )
    expect.eq(result.stdout, env.mount .. "\n" .. env.mount .. "/.git\n")
    cleanup(env)
  end)

  it("translates the logical remote path as well", function()
    local env = sandbox()
    local result = run(env, { "rev-parse", "--show-toplevel" }, { ssh_stdout = "/srv/app/pkg\n" })
    expect.eq(result.stdout, env.mount .. "/pkg\n")
    cleanup(env)
  end)

  it("leaves hashes and relative paths alone", function()
    local env = sandbox()
    local out = "abc123\n.git\nsub/dir\n"
    local result = run(env, { "rev-parse", "HEAD" }, { ssh_stdout = out })
    expect.eq(result.stdout, out)
    cleanup(env)
  end)

  it("answers locally when an absolute path lies outside the mounted prefix", function()
    local env = sandbox()
    for _, out in ipairs({ "/data/application\n", "/other/data/app\n", "/data/app\n/home/u/proj/.git\n" }) do
      os.remove(env.root .. "/git.log")
      local result = run(env, { "rev-parse", "--show-toplevel" }, { ssh_stdout = out })
      expect.eq(#result.git_log, 1, out)
      expect.eq(result.stdout, "local-git-output\n", "remote paths must not leak to the caller")
    end
    cleanup(env)
  end)

  it("translates a remote root mount", function()
    local env = sandbox({ remote = "/", real_remote = "/" })
    local result = run(env, { "rev-parse", "--show-toplevel" }, { ssh_stdout = "/etc/repo\n" })
    expect.eq(result.stdout, env.mount .. "/etc/repo\n")
    cleanup(env)
  end)

  it("removes its temp file", function()
    local env = sandbox()
    run(env, { "rev-parse", "HEAD" }, { ssh_stdout = "abc\n" })
    expect.eq(vim.fn.glob(env.tmp .. "/*", false, true), {})
    cleanup(env)
  end)

  it("translates worktree list --porcelain and falls back for -z", function()
    local env = sandbox()
    local out = "worktree /data/app\nHEAD abc\nbranch refs/heads/main\n\nworktree /data/app/wt\nHEAD def\n"
    local result = run(env, { "worktree", "list", "--porcelain" }, { ssh_stdout = out })
    expect.eq(
      result.stdout,
      "worktree " .. env.mount .. "\nHEAD abc\nbranch refs/heads/main\n\nworktree " .. env.mount .. "/wt\nHEAD def\n"
    )
    os.remove(env.root .. "/git.log")
    os.remove(env.root .. "/ssh.log")
    expect_local(run(env, { "worktree", "list", "-z" }))
    cleanup(env)
  end)

  it("translates worktree list paths followed by a space", function()
    local env = sandbox()
    local result = run(env, { "worktree", "list" }, { ssh_stdout = "/data/app  abc123 [main]\n" })
    expect.eq(result.stdout, env.mount .. "  abc123 [main]\n")
    cleanup(env)
  end)

  it("preserves the exit code when translating", function()
    local env = sandbox()
    local result = run(env, { "rev-parse", "nope" }, { ssh_exit = 128 })
    expect.eq(result.code, 128)
    cleanup(env)
  end)
end)

describe("git wrapper fallback", function()
  it("runs the real git outside any mount", function()
    local env = sandbox()
    local result = run(env, { "status" }, { cwd = env.outside })
    expect_local(result)
    expect.eq(result.stdout, "local-git-output\n")
    cleanup(env)
  end)

  it("does not match a sibling whose name merely starts with the mount path", function()
    local env = sandbox()
    vim.fn.mkdir(env.mount .. "-other", "p")
    expect_local(run(env, { "status" }, { cwd = env.mount .. "-other" }))
    cleanup(env)
  end)

  it("runs the real git for a non-allowlisted command", function()
    local env = sandbox()
    for _, args in ipairs({
      { "commit", "-m", "x" },
      { "checkout", "." },
      { "fetch" },
      { "worktree", "add", "x" },
      { "-p", "status" },
    }) do
      os.remove(env.root .. "/git.log")
      expect_local(run(env, args), args[1])
    end
    cleanup(env)
  end)

  it("runs the real git when GIT_DIR, GIT_INDEX_FILE or GIT_WORK_TREE is set", function()
    local env = sandbox()
    for _, name in ipairs({ "GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE" }) do
      os.remove(env.root .. "/git.log")
      expect_local(run(env, { "status" }, { env = { [name] = "/anywhere" } }), name)
    end
    cleanup(env)
  end)

  it("runs the real git when an argument is a local path outside the mount", function()
    local env = sandbox()
    local cases = {
      { "diff", env.outside .. "/a.txt" },
      { "diff", "--no-index", "a", "b" },
      { "log", "-F", "msg" },
      { "log", "--file=x" },
      { "diff", "--output=" .. env.outside .. "/o" },
      { "ls-files", "--exclude-from=x" },
      { "blame", "--contents", "somefile", "f" },
      { "diff", "../escape" },
      { "diff", env.mount .. "/../escape" },
    }
    for _, args in ipairs(cases) do
      os.remove(env.root .. "/git.log")
      expect_local(run(env, args), table.concat(args, " "))
    end
    cleanup(env)
  end)

  it("runs the real git for config reads that are not repository-scoped", function()
    local env = sandbox()
    for _, args in ipairs({
      { "config", "user.name", "x" },
      { "config", "--global", "--get", "a" },
      { "config", "--get", "-f", "x", "a" },
    }) do
      os.remove(env.root .. "/git.log")
      expect_local(run(env, args), table.concat(args, " "))
    end
    cleanup(env)
  end)

  it("falls back to the real git without a routed call when the socket is missing", function()
    local env = sandbox()
    local result = run(env, { "status" }, { check_exit = 255 })
    expect.eq(result.probes, 1)
    expect.eq(#result.ssh_calls, 0, "no handshake is attempted")
    expect.eq(#result.git_log, 1)
    expect.eq(result.stdout, "local-git-output\n")

    result = run(env, { "rev-parse", "HEAD" }, { check_exit = 255 })
    expect.eq(#result.ssh_calls, 0)
    expect.eq(result.stdout, "local-git-output\n")
    cleanup(env)
  end)

  it("keeps stdin for the real git when the socket is missing", function()
    local env = sandbox()
    local result = run(env, { "apply", "--cached", "-" }, { check_exit = 255, stdin = "patch\n" })
    expect.eq(#result.git_log, 1)
    expect.eq(vim.fn.readfile(env.root .. "/git.stdin"), { "patch" })
    cleanup(env)
  end)

  it("treats ssh 255 after the probe as final and never repeats output with the local git", function()
    local env = sandbox()
    local result = run(env, { "log" }, { ssh_exit = 255, ssh_stdout = "partial\n" })
    expect.eq(result.code, 255)
    expect.eq(result.stdout, "partial\n")
    expect.eq(#result.git_log, 0)

    result = run(env, { "rev-parse", "HEAD" }, { ssh_exit = 255, ssh_stdout = "abc\n" })
    expect.eq(result.code, 255)
    expect.eq(#result.git_log, 0)
    cleanup(env)
  end)

  it("runs the real git when stdout is a terminal", function()
    local env = sandbox()
    local out = {}
    local job = vim.fn.jobstart({ env.wrapper, "status" }, {
      pty = true,
      cwd = env.mount,
      env = { PATH = env.bin .. ":/usr/bin:/bin", FAKE_DIR = env.root },
      on_stdout = function(_, data)
        vim.list_extend(out, data)
      end,
    })
    vim.fn.jobwait({ job }, 5000)
    expect.eq(#vim.fn.readfile(env.root .. "/git.log"), 1)
    expect.eq(vim.fn.filereadable(env.root .. "/ssh.log"), 0)
    cleanup(env)
  end)

  it("keeps the exit code of the real git", function()
    local env = sandbox()
    local result = run(env, { "status" }, { cwd = env.outside, git_exit = 3 })
    expect.eq(result.code, 3)
    cleanup(env)
  end)

  it("runs the real git when no mount is mapped", function()
    local env = sandbox()
    for _, file in ipairs(vim.fn.glob(env.maps .. "/*.map", false, true)) do
      os.remove(file)
    end
    expect_local(run(env, { "status" }))
    cleanup(env)
  end)

  it("never invokes itself: the baked-in git is the real one", function()
    local env = sandbox()
    local result = run(env, { "status" }, { cwd = env.outside })
    expect.contains(result.git_log[1], "real git ran")
    expect.eq(#result.git_log, 1)
    cleanup(env)
  end)
end)

describe("git wrapper generation", function()
  it("resolves the real git without finding the wrapper directory", function()
    local original = vim.env.PATH
    local root = vim.fn.tempname()
    local bin = root .. "/bin/4242"
    vim.fn.mkdir(bin, "p")
    write_executable(bin .. "/git", "#!/bin/sh\n")
    vim.env.PATH = bin .. ":" .. original

    local resolved = GitRoute.resolve_real_git(root)
    vim.env.PATH = original
    vim.fn.delete(root, "rf")

    expect.truthy(resolved)
    expect.falsy(resolved:find(root, 1, true), "must skip the excluded directory")
  end)

  it("probes and routes through the socket only, never starting a master", function()
    stub.reload()
    require("sshfs.config").setup({})
    local options = require("sshfs.lib.ssh").build_git_route_options()
    expect.truthy(vim.tbl_contains(options, "ControlMaster=no"))
    expect.truthy(vim.tbl_contains(options, "BatchMode=yes"))
    expect.truthy(vim.tbl_contains(options, "RemoteCommand=none"))
    expect.truthy(vim.tbl_contains(options, "RequestTTY=no"))
  end)

  it("asks the remote for git when resolving a mount", function()
    stub.reload()
    require("sshfs.config").setup({})
    local cmd = require("sshfs.lib.ssh").build_pwd_command({ name = "box" }, "app")
    expect.contains(cmd[#cmd], "command -v git")
  end)

  it("bakes quoted paths and ssh options into the script", function()
    local script = GitRoute.render_wrapper({
      real_git = "/opt/it's/git",
      map_dir = "/m d",
      ssh_options = { "ControlPath=/a b/%C" },
    })
    expect.contains(script, "REAL_GIT='/opt/it'\\''s/git'")
    expect.contains(script, "MAP_DIR='/m d'")
    expect.contains(script, "ssh -o 'ControlPath=/a b/%C' \"$@\"")
    expect.falsy(script:find("@REAL_GIT@", 1, true))
  end)

  it("installs an executable wrapper and prepends its directory to PATH once", function()
    stub.reload()
    local cache = vim.fn.tempname()
    local original_cache, original_path = vim.env.XDG_CACHE_HOME, vim.env.PATH
    vim.env.XDG_CACHE_HOME = cache
    require("sshfs.config").setup({})
    local Route = require("sshfs.lib.git_route")

    local ok = Route.install()
    Route.install()
    local paths = Route.paths()
    local entries = vim.split(vim.env.PATH, ":", { plain = true })
    local occurrences = 0
    for _, entry in ipairs(entries) do
      if entry == paths.bin_dir then occurrences = occurrences + 1 end
    end
    local first, executable = entries[1], vim.fn.executable(paths.wrapper)

    require("sshfs.config").setup({ git = { route_over_ssh = false } })
    Route.install()
    local after_disable = vim.env.PATH

    vim.env.XDG_CACHE_HOME, vim.env.PATH = original_cache, original_path
    vim.fn.delete(cache, "rf")

    expect.truthy(ok)
    expect.eq(first, paths.bin_dir)
    expect.eq(occurrences, 1)
    expect.eq(executable, 1)
    expect.falsy(after_disable:find(paths.bin_dir, 1, true), "disabling takes the wrapper off PATH")
  end)
end)

--- Run fn against a throwaway cache dir with the plugin set up, restoring env afterwards.
local function with_cache(fn, config)
  stub.reload()
  local cache = vim.fn.tempname()
  local original_cache, original_path = vim.env.XDG_CACHE_HOME, vim.env.PATH
  vim.env.XDG_CACHE_HOME = cache
  require("sshfs.config").setup(config or {})
  local ok, err = pcall(fn, require("sshfs.lib.git_route"), cache)
  vim.env.XDG_CACHE_HOME, vim.env.PATH = original_cache, original_path
  vim.fn.delete(cache, "rf")
  if not ok then error(err, 0) end
end

--- The namespace marker a dir of this process carries (written by install()).
local function own_namespace(route)
  route.install()
  return vim.fn.readfile(route.paths().bin_dir .. "/.namespace")[1]
end

--- A bin dir as another Neovim would have left it, with a fake wrapper git inside.
local function fake_instance_dir(route, pid, namespace)
  local dir = route.paths().root .. "/bin/" .. pid
  write_executable(dir .. "/git", "#!/bin/sh\necho fake wrapper\n")
  vim.fn.writefile({ namespace }, dir .. "/.namespace")
  return dir
end

describe("git wrapper per instance", function()
  it("gives each Neovim its own bin dir and sweeps those of dead processes", function()
    with_cache(function(Route)
      local dead = fake_instance_dir(Route, 999999999, own_namespace(Route))

      Route.install()
      local paths = Route.paths()

      expect.contains(paths.bin_dir, "/bin/" .. vim.uv.os_getpid())
      expect.eq(vim.fn.executable(paths.wrapper), 1)
      expect.eq(vim.fn.isdirectory(dead), 0, "a bin dir of a dead pid is swept")
      expect.eq(vim.fn.isdirectory(paths.bin_dir), 1, "a live instance keeps its own dir")
    end)
  end)

  it("ignores a parent instance's wrapper dir inherited on PATH and survives it being swept", function()
    with_cache(function(Route)
      local namespace = own_namespace(Route)
      local parent = fake_instance_dir(Route, 999999999, namespace)
      vim.env.PATH = parent .. ":" .. vim.env.PATH

      local ok = Route.install()
      local paths = Route.paths()
      local baked = table.concat(vim.fn.readfile(paths.wrapper), "\n"):match("REAL_GIT='([^']*)'")
      local result = vim.system({ paths.wrapper, "--version" }, { text = true }):wait()

      expect.truthy(ok)
      expect.eq(vim.fn.isdirectory(parent), 0, "the dead parent's dir is swept")
      expect.falsy(vim.startswith(baked, paths.root .. "/bin/"), "real git must not be a wrapper: " .. baked)
      expect.eq(result.code, 0, "fallback git still runs: " .. (result.stderr or ""))
      expect.falsy(vim.env.PATH:find(parent, 1, true))
    end)
  end)

  it("treats only real bin dir entries as wrapper dirs", function()
    with_cache(function(Route)
      local paths = Route.paths()
      local lookalike = paths.root .. "/bin2/1"
      write_executable(lookalike .. "/git", "#!/bin/sh\n")
      vim.env.PATH = lookalike .. ":" .. vim.env.PATH
      expect.eq(Route.resolve_real_git(paths.root), lookalike .. "/git")
    end)
  end)

  it("removes inherited wrapper dirs from PATH when routing is disabled", function()
    with_cache(function(Route)
      local parent = Route.paths().root .. "/bin/999999999"
      vim.env.PATH = parent .. ":" .. vim.env.PATH
      local ok = Route.install()
      expect.falsy(ok)
      expect.falsy(vim.env.PATH:find(parent, 1, true))
    end, { git = { route_over_ssh = false } })
  end)

  it("sweeps only dirs of its own pid namespace", function()
    with_cache(function(Route)
      local namespace = own_namespace(Route)
      local foreign = fake_instance_dir(Route, 999999998, "other-host other-boot pid:[1]")
      local unmarked = Route.paths().root .. "/bin/999999997"
      vim.fn.mkdir(unmarked, "p")
      local own_dead = fake_instance_dir(Route, 999999996, namespace)

      Route.install()

      expect.eq(vim.fn.isdirectory(foreign), 1, "another namespace's pids prove nothing")
      expect.eq(vim.fn.isdirectory(unmarked), 1, "an unmarked dir may be mid-startup")
      expect.eq(vim.fn.isdirectory(own_dead), 0)
    end)
  end)
end)

describe("git wrapper sweep across reboots", function()
  it("sweeps dirs marked with another boot_id of this host and pid namespace, even for a live pid", function()
    with_cache(function(Route)
      local host, _, ns = own_namespace(Route):match("^(%S*) (%S*) (%S*)$")
      -- pid 1 is alive now, but only in this boot: the marker's pids belong to a boot that ended
      local rebooted = fake_instance_dir(Route, 1, table.concat({ host, "previous-boot", ns }, " "))
      local other_host = fake_instance_dir(Route, 999999995, table.concat({ "other-host", "previous-boot", ns }, " "))
      local other_ns = fake_instance_dir(Route, 999999994, table.concat({ host, "previous-boot", "pid:[1]" }, " "))

      Route.install()

      expect.eq(vim.fn.isdirectory(rebooted), 0)
      expect.eq(vim.fn.isdirectory(other_host), 1, "another host shares the cache, its pids prove nothing")
      expect.eq(vim.fn.isdirectory(other_ns), 1, "a different pid namespace proves nothing either")
    end)
  end)
end)

describe("git wrapper signals", function()
  it("removes its temp file when terminated while ssh runs", function()
    local env = sandbox()
    local job = vim.system({ env.wrapper, "rev-parse", "--show-toplevel" }, {
      cwd = env.mount,
      env = {
        PATH = env.bin .. ":/usr/bin:/bin",
        FAKE_DIR = env.root,
        TMPDIR = env.tmp,
        FAKE_SSH_SLEEP = "1",
      },
      text = true,
    })
    vim.wait(3000, function()
      return vim.fn.filereadable(env.root .. "/ssh.log") == 1
    end)
    job:kill(15)
    local result = job:wait()
    local leftovers = vim.fn.glob(env.tmp .. "/*", false, true)
    cleanup(env)
    expect.eq(result.code, 143)
    expect.eq(#leftovers, 0, "no temp file left behind")
  end)
end)

local function without_first_entry(path_value)
  local entries = vim.split(path_value, ":", { plain = true })
  table.remove(entries, 1)
  return table.concat(entries, ":")
end

describe("git health checks", function()
  local function reports_for(setup_fn)
    local reports = {}
    with_cache(function(Route)
      local function record(level)
        return function(message)
          table.insert(reports, { level = level, message = message })
        end
      end
      stub.set("health", {
        start = function() end,
        ok = record("ok"),
        info = record("info"),
        warn = record("warn"),
        error = record("error"),
      })
      setup_fn(Route)
      require("sshfs.health").check()
      stub.restore_all()
    end)
    return reports
  end

  local function has_warning(reports, text)
    for _, report in ipairs(reports) do
      if report.level == "warn" and report.message:find(text, 1, true) then return true end
    end
    return false
  end

  it("warns about a mount without a git route", function()
    local reports = reports_for(function(Route)
      Route.install()
      local MountPoint = require("sshfs.lib.mount_point")
      MountPoint.list_active = function()
        return { { mount_path = "/tmp/unmapped-mount" } }
      end
    end)
    expect.truthy(has_warning(reports, "No git route for /tmp/unmapped-mount"))
  end)

  it("warns when git on PATH is not the wrapper", function()
    local reports = reports_for(function(Route)
      Route.install()
      vim.env.PATH = without_first_entry(vim.env.PATH)
    end)
    expect.truthy(has_warning(reports, "not the wrapper"))
  end)

  it("stays quiet about the wrapper when it is first on PATH", function()
    local reports = reports_for(function(Route)
      Route.install()
    end)
    expect.falsy(has_warning(reports, "not the wrapper"))
  end)
end)

describe("git route config", function()
  it("defaults to routing over SSH", function()
    stub.reload()
    require("sshfs.config").setup({})
    expect.eq(require("sshfs.config").get().git.route_over_ssh, true)
  end)

  it("can be turned off", function()
    stub.reload()
    require("sshfs.config").setup({ git = { route_over_ssh = false } })
    expect.eq(require("sshfs.config").get().git.route_over_ssh, false)
    expect.falsy(require("sshfs.lib.git_route").enabled())
  end)
end)

describe("git route map files", function()
  local function with_cache(fn)
    stub.reload()
    local cache = vim.fn.tempname()
    local original = vim.env.XDG_CACHE_HOME
    vim.env.XDG_CACHE_HOME = cache
    local base_dir = cache .. "/mnt"
    vim.fn.mkdir(base_dir, "p")
    require("sshfs.config").setup({ mounts = { base_dir = base_dir } })
    local ok, err = pcall(fn, cache, base_dir)
    vim.env.XDG_CACHE_HOME = original
    vim.fn.delete(cache, "rf")
    stub.restore_all()
    if not ok then error(err, 0) end
  end

  it("writes a map with the logical and real remote paths when a mount registers", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      local seen
      stub.set("system", function(cmd, _, on_exit)
        seen = cmd
        on_exit({ code = 0, stdout = "/srv/app\n/data/app\n", stderr = "" })
      end)
      local mount_path = base_dir .. "/box"
      vim.fn.mkdir(mount_path, "p")
      local finished
      Route.register_mount(
        { mount_path = mount_path, host = "box", user = "deploy", port = 22, remote_path = "app" },
        function(ok)
          finished = ok
        end
      )
      vim.wait(1000, function()
        return finished ~= nil
      end)

      expect.truthy(finished)
      expect.contains(table.concat(seen, " "), "pwd -P")
      expect.contains(table.concat(seen, " "), "BatchMode=yes")
      local map = table.concat(vim.fn.readfile(vim.fn.glob(Route.paths().map_dir .. "/*.map", false, true)[1]), "\n")
      expect.contains(map, "mount=" .. mount_path)
      expect.contains(map, "host=box")
      expect.contains(map, "user=deploy")
      expect.contains(map, "port=22")
      expect.contains(map, "remote=/srv/app")
      expect.contains(map, "real=/data/app")
    end)
  end)

  it("writes nothing when the remote path cannot be resolved", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      stub.set("system", function(_, _, on_exit)
        on_exit({ code = 255, stdout = "", stderr = "no route" })
      end)
      local finished
      Route.register_mount({ mount_path = base_dir .. "/box", host = "box", remote_path = "/x" }, function(ok)
        finished = ok
      end)
      vim.wait(1000, function()
        return finished ~= nil
      end)
      expect.eq(finished, false)
      expect.eq(#vim.fn.glob(Route.paths().map_dir .. "/*.map", false, true), 0)
    end)
  end)

  it("registers a mount created by another instance only when no map exists", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      local mount_path = base_dir .. "/box"
      vim.fn.mkdir(mount_path, "p")
      stub.executable({})
      stub.set("fn.system", function()
        return "deploy@box:/srv/app on " .. mount_path .. " type fuse.sshfs (rw)"
      end)
      local calls = 0
      stub.set("system", function(_, _, on_exit)
        calls = calls + 1
        on_exit({ code = 0, stdout = "/srv/app\n/srv/app\n", stderr = "" })
      end)

      Route.register_existing_mount(mount_path)
      vim.wait(1000, function()
        return Route.has_map(mount_path)
      end)
      expect.truthy(Route.has_map(mount_path))
      local map = table.concat(vim.fn.readfile(vim.fn.glob(Route.paths().map_dir .. "/*.map", false, true)[1]), "\n")
      expect.contains(map, "user=deploy")
      Route.register_existing_mount(mount_path)
      expect.eq(calls, 1, "an existing map is not rebuilt")
    end)
  end)

  it("ignores directories under another base dir, such as mirror connections", function()
    with_cache(function(cache)
      local Route = require("sshfs.lib.git_route")
      local mirror = cache .. "/mirrors/box"
      vim.fn.mkdir(mirror, "p")
      stub.executable({})
      stub.set("fn.system", function()
        return ""
      end)
      stub.set("system", function()
        error("must not resolve a non-mount")
      end)
      Route.register_existing_mount(mirror)
      expect.falsy(Route.has_map(mirror))
    end)
  end)

  it("removes the map on a real unmount only", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      local MountPoint = require("sshfs.lib.mount_point")
      local mount_path = base_dir .. "/box"
      vim.fn.mkdir(mount_path, "p")
      Route.write_map({ mount_path = mount_path, host = "box", remote_path = "/srv/app" })

      stub.executable({ fusermount = true })
      local exit_code = 1
      stub.set("system", function()
        return {
          wait = function()
            return { code = exit_code, stdout = "", stderr = "" }
          end,
        }
      end)

      expect.falsy(MountPoint.unmount(mount_path))
      expect.truthy(Route.has_map(mount_path), "a failed unmount keeps the map")
      exit_code = 0
      expect.truthy(MountPoint.unmount(mount_path))
      expect.falsy(Route.has_map(mount_path))
    end)
  end)

  it("sweeps maps whose mount is gone and keeps active ones", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      local live, dead = base_dir .. "/live", base_dir .. "/dead"
      vim.fn.mkdir(live, "p")
      vim.fn.mkdir(dead, "p")
      Route.write_map({ mount_path = live, host = "live", remote_path = "/a" })
      Route.write_map({ mount_path = dead, host = "dead", remote_path = "/b" })

      stub.executable({})
      stub.set("fn.system", function()
        return "u@live:/a on " .. live .. " type fuse.sshfs (rw)"
      end)
      expect.eq(Route.sweep_stale(), 1)
      expect.truthy(Route.has_map(live))
      expect.falsy(Route.has_map(dead))
    end)
  end)

  it("reads the mount table once however many maps exist", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      for _, name in ipairs({ "a", "b", "c" }) do
        vim.fn.mkdir(base_dir .. "/" .. name, "p")
        Route.write_map({ mount_path = base_dir .. "/" .. name, host = name, remote_path = "/x" })
      end
      stub.executable({})
      local reads = 0
      stub.set("fn.system", function()
        reads = reads + 1
        return ""
      end)
      expect.eq(Route.sweep_stale(), 3)
      expect.eq(reads, 1)
    end)
  end)

  it("writes no map when the remote has no git", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      stub.set("system", function(_, _, on_exit)
        -- `command -v git` failing ends the && chain with status 1 and no output
        on_exit({ code = 1, stdout = "", stderr = "" })
      end)
      local finished
      Route.register_mount({ mount_path = base_dir .. "/box", host = "box", remote_path = "/x" }, function(ok)
        finished = ok
      end)
      vim.wait(1000, function()
        return finished ~= nil
      end)
      expect.eq(finished, false)
      expect.falsy(Route.has_map(base_dir .. "/box"))
    end)
  end)

  it("sweeps from MountPoint.cleanup_stale", function()
    with_cache(function(_, base_dir)
      local Route = require("sshfs.lib.git_route")
      local dead = base_dir .. "/dead"
      Route.write_map({ mount_path = dead, host = "dead", remote_path = "/b" })
      stub.executable({})
      stub.set("fn.system", function()
        return ""
      end)
      require("sshfs.lib.mount_point").cleanup_stale()
      expect.falsy(Route.has_map(dead))
    end)
  end)
end)
