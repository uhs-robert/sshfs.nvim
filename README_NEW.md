# nvim-ssh

Use sshfs to mount remote servers in nvim for editing and viewing

## Features

- **Zero external dependencies** - Uses only native Neovim UI components
- **Shared core architecture** - Reuses battle-tested logic from [sshfs.yazi](https://github.com/uhs-robert/sshfs.yazi)
- **Modern Neovim APIs** - Built for Neovim 0.10+ with vim.uv
- **Secure authentication** - Key-first authentication with password fallback
- **Flexible file browsing** - Works with any file explorer (telescope, snacks, oil, netrw, etc.)
- **Cross-platform** - Tested on Linux (if you have issues on MacOS or Windows then please raise an issue)

## Installation

Using [Lazy.nvim](https://github.com/folke/lazy.nvim), add this to your plugins:

```lua
  {
    "uhs-robert/nvim-ssh",
    opts = {
    -- Refer to the configuration section below
    -- or leave empty for defaults
    },
  }
```

## Configuration

You can optionally customize behavior by passing a config table to setup().

> [!NOTE]
> Only include what you want to edit.
>
> Here's the full set of defaults for you to configure:

```lua
require("nvim_ssh").setup({
  connections = {
    ssh_configs = require("nvim_ssh.core.config").get_default_ssh_configs(),
    sshfs_args = {
      "-o reconnect",
      "-o ConnectTimeout=5",
      "-o compression=yes",
      "-o ServerAliveInterval=15",
      "-o ServerAliveCountMax=3",
    },
  },
  mounts = {
    base_dir = vim.fn.expand("$HOME") .. "/mnt", -- where remote mounts are created
    unmount_on_exit = true, -- auto-disconnect all mounts on :q or exit
  },
  handlers = {
    on_disconnect = {
      clean_mount_folders = true, -- optionally clean up mount folders after disconnect
    },
  },
  ui = {
    file_picker = {
      auto_open_on_mount = true, -- auto-open picker after connecting
      preferred_picker = "auto", -- one of: "auto", "telescope", "snacks", "oil", "neo-tree", "nvim-tree", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
      fallback_to_netrw = true,  -- fallback to netrw if no custom picker is available
    },
  },
  lead_prefix = "<leader>s", -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>sm",
    unmount = "<leader>su",
    edit = "<leader>se",
    reload = "<leader>sr",
    open = "<leader>so",
    grep = "<leader>sg",
  },
  log = {
    enabled = false,
    truncate = false,
    types = {
      all = false,
      util = false,
      handler = false,
      sshfs = false,
    },
  },
})
```

## Commands

- `:SSHConnect [host]` - Connect to SSH host (picker or direct)
- `:SSHDisconnect` - Disconnect from current host (picker shown if multiple mounts)
- `:SSHEdit` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHBrowse` - Browse remote files using your preferred file explorer
- `:SSHGrep [pattern]` - Search remote files for a pattern using your preferred grep tool

## Keymaps

This plugin optionally provides default keybindings under `<leader>m`. These can be fully customized.

### Default Keymaps

| Mapping      | Description               |
| ------------ | ------------------------- |
| `<leader>me` | Edit SSH config files     |
| `<leader>mg` | Grep remote files         |
| `<leader>mm` | Mount an SSH host         |
| `<leader>mo` | Browse remote mount       |
| `<leader>mr` | Reload SSH configuration  |
| `<leader>mu` | Unmount an active session |

If [which-key.nvim](https://github.com/folke/which-key.nvim) is installed, the `<leader>m` group will be labeled with a custom icon (`󰌘`).

### Custom Keymap Configuration

You can override the keymaps or the prefix like this:

```lua
require("nvim_ssh").setup({
  lead_prefix = "<leader>s", -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>sm",
    unmount = "<leader>su",
    edit = "<leader>se",
    reload = "<leader>sr",
    open = "<leader>so",
    grep = "<leader>sg",
  },
})
```

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
