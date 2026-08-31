# Debug logging

Debug logging is disabled by default. Enable it in setup:

```lua
require("sshfs").setup({
  debug = {
    enabled = true,
    log_file = vim.fn.stdpath("log") .. "/sshfs.nvim.log",
  },
})
```

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
