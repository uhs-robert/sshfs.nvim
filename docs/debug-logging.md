# Debug logging

Debug logging is disabled by default. Enable it in setup:

```lua
require("sshfs").setup({
  debug = {
    enabled = true,
    log_file = vim.fn.stdpath("log") .. "/sshfs.nvim.log",
    max_size = 1048576,
  },
})
```

Once the log passes `max_size` bytes it is moved to `<log_file>.1` and a fresh file is started, so only the last two generations are kept. Set `max_size = 0` to disable rotation and let the file grow.

You can also change debug logging for the current Neovim session without changing configuration:

```vim
:SSHDebug
:SSHDebug on
:SSHDebug off
```

With no argument, `:SSHDebug` toggles logging. The command reports the active log path.

When enabled, sshfs.nvim records timestamped diagnostics for SSH authentication, ControlMaster setup/cleanup, remote home resolution, and SSHFS mount subprocesses, including exit codes, stdout, and stderr. No log file writes are performed while debug logging is disabled.

> [!WARNING]
> Debug logs may contain hostnames, usernames, filesystem paths, SSH/SSHFS output, or authentication-related messages. Review logs before sharing them publicly.
