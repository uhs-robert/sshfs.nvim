# Tests

Unit tests for sshfs.nvim. They run inside headless Neovim, use no external dependencies, and never contact a real SSH server or mount table.

## Running

```sh
make test                      # everything
make test PATTERN=mount_point  # only spec files whose path contains the pattern
nvim -l tests/run.lua          # same as `make test`
```

The runner exits non-zero when any case fails, so it can gate CI. `.github/workflows/test.yml` runs the suite and `stylua --check` on every pull request.

## Layout

| File | Purpose |
| --- | --- |
| `harness.lua` | `describe`/`it` registry, assertions, result reporting |
| `stub.lua` | Replaces the system-facing calls and restores them afterwards |
| `run.lua` | Entry point: discovers `tests/*_spec.lua` and exits with the result |
| `*_spec.lua` | One spec file per module under test |

## Writing a test

Spec files are plain Lua. The runner exposes `describe`, `it`, `expect`, and `stub` as globals, so no requires are needed.

```lua
describe("MountPoint.list_active", function()
  it("ignores mounts outside the configured base directory", function()
    stub.reload()
    require("sshfs.config").setup({ mounts = { base_dir = "/home/tester/mnt" } })
    stub.executable({})
    stub.system(function()
      return "deploy@example.com:/srv/app on /somewhere/else type fuse.sshfs (rw)", 0
    end)

    expect.eq(require("sshfs.lib.mount_point").list_active(), {})
    stub.restore_all()
  end)
end)
```

### Assertions

`expect.eq` (deep equality), `expect.truthy`, `expect.falsy`, `expect.is_nil`, `expect.contains` (plain substring), `expect.errors`, `expect.no_error`. Each takes an optional trailing context string that is shown on failure.

### Stubs

`stub.system(handler)` replaces `vim.fn.system` and the `v:shell_error` it reports; the handler returns `output, code`. `stub.vim_system(handler)` replaces `vim.system`, supporting both the async-callback and `:wait()` call styles, and returns the list of commands it received. `stub.executable(names)` controls `vim.fn.executable`. `stub.notifications()` captures `vim.notify` calls instead of printing them. `stub.set(path, value)` replaces any other field under `vim`.

Two rules matter:

- Call `stub.restore_all()` at the end of a case that stubbed anything.
- Call `stub.reload()` before requiring a plugin module when the test depends on fresh module state. Several modules memoize (configuration, SSHFS version detection), so a stale load will leak state between cases.
