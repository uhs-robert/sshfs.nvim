# nvim-ssh

Use sshfs to mount remote servers in nvim for editing and viewing

## Disclaimer

> [!WARNING]
> This is an old repository. It is a minimal functional integration that could be improved.

I personally prefer using [yazi](https://github.com/sxyazi/yazi), a fast terminal file manager written in rust, for this functionality. You can check out my yazi plugin for sshfs here: [sshfs.yazi](https://github.com/uhs-robert/sshfs.yazi).

- This plugin, along with every yazi plugin, is compatible with NeoVim via the [yazi plugin for NeoVim](https://github.com/mikavilpas/yazi.nvim).

It is easier for me to maintain the yazi plugin as yazi is my preferred method of travel around local and remote file systems.

## Next Steps for Repo

> [!TIP]
> But not all hope is lost! Check back in **September 2025** for a major rehaul/update.

I am planning to revamp this in the next coming weeks with the following updates:

- **Zero External Dependencies:** Remove all external plugin dependencies like telescope (why? less maintenance, no risk of plugin abandonment, no user overhead, sshfs is simple so lets keep it simple)
- **Modern Neovim APIs** - Built for Neovim 0.10+ with vim.uv
- **Secure authentication** - Key-first authentication with password fallback
- **Flexible file browsing** - Works with any file explorer (telescope, snacks, oil, netrw, etc.)
- **Cross-platform** - Works on Linux, macOS, and Windows

So... stay tuned!
