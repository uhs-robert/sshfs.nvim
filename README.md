# 🚀 nvim-ssh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/NeoVim-0.10+-57A143?logo=neovim)](https://neovim.io/)
[![GitHub stars](https://img.shields.io/github/stars/uhs-robert/nvim-ssh?style=social)](https://github.com/uhs-robert/nvim-ssh/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/uhs-robert/nvim-ssh)](https://github.com/uhs-robert/nvim-ssh/issues)

Use sshfs to mount remote servers in nvim for editing and viewing

<https://github.com/user-attachments/assets/20419da8-37b9-4325-a942-90a85754ce11>

## ✨ Features

- **Zero external dependencies** - No telescope, plenary, or other plugin dependencies required
- **Smart picker auto-detection** - Automatically detects and launches your preferred file pickers
- **Extensive picker support** - Supports telescope, oil, neo-tree, nvim-tree, snacks, fzf-lua, mini, yazi, lf, nnn, ranger, with netrw fallback
- **Modern Neovim APIs** - Built for Neovim 0.10+ with vim.uv
- **Robust authentication** - Key authentication with password fallback mechanisms
- **Modular architecture** - Clean separation of core functionality, UI components, and utilities
- **Cross-platform support** - Tested on Linux with Windows/MacOS compatibility

## 📋 Requirements

| Software   | Minimum       | Notes                                                       |
| ---------- | ------------- | ----------------------------------------------------------- |
| Neovim     | `>=0.10`      | Requires `vim.uv` support                                   |
| sshfs      | any           | `sudo dnf/apt/pacman install sshfs` or `brew install sshfs` |
| SSH client | any           | Usually pre-installed on most systems                       |
| SSH config | working hosts | Hosts come from `~/.ssh/config`                             |

## 📦 Installation

### Lazy.nvim (Recommended)

```lua
{
  "uhs-robert/nvim-ssh",
  opts = {
    -- Refer to the configuration section below
    -- or leave empty for defaults
  },
}
```

### Packer.nvim

```lua
use {
  "uhs-robert/nvim-ssh",
  config = function()
    require("nvim_ssh").setup({
      -- Your configuration here
    })
  end
}
```

### vim-plug

```vim
Plug 'uhs-robert/nvim-ssh'
```

Then in your `init.lua`:

```lua
require("nvim_ssh").setup({
  -- Your configuration here
})
```

### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/uhs-robert/nvim-ssh ~/.local/share/nvim/site/pack/plugins/start/nvim-ssh
```

2. Add to your `init.lua`:

```lua
require("nvim_ssh").setup({
  -- Your configuration here
})
```

## ⚙️ Configuration

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
      preferred_picker = "auto", -- one of: "auto", "telescope", "oil", "neo-tree", "nvim-tree", "snacks", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
      fallback_to_netrw = true,  -- fallback to netrw if no picker is available
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

## 🔧 Commands

- `:SSHConnect [host]` - Connect to SSH host (picker or direct)
- `:SSHDisconnect` - Disconnect from current host (picker shown if multiple mounts)
- `:SSHEdit` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHBrowse` - Browse remote files using auto-detected file picker
- `:SSHGrep [pattern]` - Search remote files using auto-detected search tool

## 🎹 Key Mapping

This plugin optionally provides default keybindings under `<leader>m`. These can be fully customized.

### 🎯 Default Keymaps

| Mapping      | Description               |
| ------------ | ------------------------- |
| `<leader>me` | Edit SSH config files     |
| `<leader>mg` | Grep remote files         |
| `<leader>mm` | Mount an SSH host         |
| `<leader>mo` | Browse remote mount       |
| `<leader>mr` | Reload SSH configuration  |
| `<leader>mu` | Unmount an active session |

If [which-key.nvim](https://github.com/folke/which-key.nvim) is installed, the `<leader>m` group will be labeled with a custom icon (`󰌘`).

### 🛠️ Custom Keymap Configuration

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

## 🚀 Usage

After connecting to a host with `:SSHConnect`, the plugin mounts the remote filesystem locally. You can then:

1. **Browse files**: Use `:SSHBrowse` to automatically launch your preferred file picker:

   - **Auto-detected pickers**: telescope, oil, neo-tree, nvim-tree, snacks, fzf-lua, mini, yazi, lf, nnn, ranger
   - **Fallback**: netrw if no other picker is available

2. **Search files**: Use `:SSHGrep [pattern]` to automatically launch your preferred search tool:
   - **Auto-detected search**: telescope live_grep, snacks grep, fzf-lua live_grep, mini grep_live
   - **Fallback**: built-in grep with quickfix list

The plugin intelligently detects what you have installed and launches it automatically, respecting your existing Neovim setup and preferences.

## 💡 Tips and Performance

- If key authentication fails, the plugin will prompt for a password up to 3 times before giving up.
- SSH keys vastly speed up repeated mounts (no password prompt), leverage your `ssh_config` rather than manually adding hosts to make this as easy as possible.

## 📜 License

This plugin is released under the MIT license. Please see the [LICENSE](https://github.com/uhs-robert/nvim-ssh?tab=MIT-1-ov-file) file for details.
