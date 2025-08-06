# nvim-ssh

Use sshfs to mount remote servers in nvim for editing and viewing

## Features

- **Zero external dependencies** - Uses only native Neovim UI components
- **Shared core architecture** - Reuses battle-tested logic from [sshfs.yazi](https://github.com/uhs-robert/sshfs.yazi)
- **Modern Neovim APIs** - Built for Neovim 0.10+ with vim.uv
- **Secure authentication** - Key-first authentication with password fallback
- **Flexible file browsing** - Works with any file explorer (telescope, snacks, oil, netrw, etc.)
- **Cross-platform** - Works on Linux, macOS, and Windows

## Installation

```lua
-- lazy.nvim
{
  "uhs-robert/nvim-ssh",
  config = function()
    require("ssh").setup({
      -- Optional configuration
    })
  end,
}
```

## Commands

- `:SSHConnect [host]` - Connect to SSH host (picker or direct)
- `:SSHDisconnect` - Disconnect from current host
- `:SSHEdit` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHLiveGrep [pattern]` - Change to remote directory and set search pattern for your preferred search tool
- `:SSHBrowse` - Browse remote files using your preferred file explorer
- `:SSHGrep [pattern]` - Alias for SSHLiveGrep

## Architecture

This plugin uses a clean, modular architecture organized by functional domains:

### Core Business Logic (`core/`)
- `config.lua` - SSH config parsing and host discovery
- `auth.lua` - Secure authentication flows and credential handling
- `mount.lua` - SSHFS mount operations and lifecycle management
- `cache.lua` - Host caching with file modification tracking
- `connections.lua` - Connection state management and orchestration

### User Interface (`ui/`)
- `picker.lua` - Native UI components for host/file selection
- `keymaps.lua` - Keyboard shortcut definitions

### Utilities (`utils/`)
- `log.lua` - Logging utilities and debugging support

### Root Level
- `api.lua` - Public API interface
- `init.lua` - Plugin initialization and command definitions

The architecture separates concerns clearly, making the codebase maintainable, testable, and easy to extend. All components are self-contained with zero external dependencies.

## Usage

After connecting to a host with `:SSHConnect`, the plugin mounts the remote filesystem locally. You can then:

1. **Browse files**: Use `:SSHBrowse` to browse remote files with your preferred file explorer:
   - Telescope: `:Telescope find_files`
   - Oil: `:Oil`
   - Snacks: `:lua Snacks.dashboard()`
   - Netrw: `:Ex`

2. **Search files**: Use `:SSHLiveGrep pattern` to change directory and set the search pattern, then use your preferred search tool:
   - Telescope: `:Telescope live_grep`
   - Built-in: `:grep pattern **/*`
   - Vimgrep: `:vimgrep /pattern/gj **/*`

This approach respects your existing Neovim setup and preferences.