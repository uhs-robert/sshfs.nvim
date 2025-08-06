# nvim-ssh

Use sshfs to mount remote servers in nvim for editing and viewing

## Disclaimer

> [!WARNING]
> This is an old repository that is functional but will be majorly overhauled in the coming weeks.

For now I would recommend using [Yazi](https://github.com/sxyazi/yazi), a fast terminal file manager written in rust, for this functionality.

You can check out my `yazi plugin` for sshfs here: [sshfs.yazi](https://github.com/uhs-robert/sshfs.yazi).

- The `sshfs.yazi` plugin, along with every other yazi plugin, is compatible with NeoVim via the [yazi plugin for NeoVim](https://github.com/mikavilpas/yazi.nvim).

## Next Steps for This Project

> [!IMPORTANT]
> But not all hope is lost! Check back in **September 2025** for a major rehaul/update.

I am planning to completely rehaul this plugin in the next coming weeks with the following changes:

- **Zero External Dependencies** - Remove all external plugin dependencies
- **Modern NeoVim APIs** - Built for NeoVim 0.10+ with vim.uv
- **Secure authentication** - Key-first authentication with password fallback
- **Flexible file browsing** - Compatibility with any file explorer (telescope, snacks, oil, netrw, etc.) or tool
- **Cross-platform** - Works on Linux, macOS, and Windows
- **SSHFS Configuration Options** - Configure mount point, compression, server_alive, dir_cache, reconnect, etc:
- **Just Mount It and Be Done With It** - Minimal, reliable, and fast with no fancy bells or whistles.

So... stay tuned!
