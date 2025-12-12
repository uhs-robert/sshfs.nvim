<p align="center">
  <img
    src="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/1f4e1.svg"
    width="128" height="128" alt="SSH emoji" />
</p>
<h1 align="center">sshfs.nvim</h1>

<p align="center">
  <a href="https://github.com/uhs-robert/sshfs.nvim/stargazers"><img src="https://img.shields.io/github/stars/uhs-robert/sshfs.nvim?colorA=192330&colorB=khaki&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/s.nvim.nvim" target="_blank" rel="noopener noreferrer"><img alt=.nvim 0.25+" src="https://img.shields.io/badge/NeoVim-0.10+%2B-blue?style=for-the-badge&cacheSeconds=4300&labelColor=192330" /></a>
  <a href="https://github.com/uhs-robert/sshfs.nvim/issues"><img src="https://img.shields.io/github/issues/uhs-robert/sshfs.nvim?colorA=192330&colorB=skyblue&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/uhs-robert/sshfs.nvim/contributors"><img src="https://img.shields.io/github/contributors/uhs-robert/sshfs.nvim?colorA=192330&colorB=8FD1C7&style=for-the-badge&cacheSeconds=4300"></a>
  <a href="https://github.com/uhs-robert/sshfs.nvim/network/members"><img src="https://img.shields.io/github/forks/uhs-robert/sshfs.nvim?colorA=192330&colorB=CFA7FF&style=for-the-badge&cacheSeconds=4300"></a>
</p>

<p align="center">
A minimal, fast <strong>SSHFS</strong> integration for <strong>NeoVim</strong> that <strong>works with YOUR setup</strong>.
</p>

## 🕶️ What does it do?

Mount any host from your `~/.ssh/config` and browse remote files as if they were local. Jump between your local machine and remote mounts with a keystroke.

No forced dependencies. Use your preferred file picker, search tools, and workflow to edit remote files without leaving your editor.

**🎯 Smart Integration**: Automatically detects and launches **telescope**, **oil**, **neo-tree**, **nvim-tree**, **snacks**, **fzf-lua**, **mini**, **yazi**, **lf**, **nnn**, **ranger**, or **netrw**. Your workflow, your choice.

<https://github.com/user-attachments/assets/20419da8-37b9-4325-a942-90a85754ce11>

## ✨ Features

### 🎯 **Works With Your Existing Setup**

- **Smart picker auto-detection** - Automatically detects and launches YOUR preferred file pickers
- **Universal compatibility** - Supports **telescope**, **oil**, **neo-tree**, **nvim-tree**, **snacks**, **fzf-lua**, **mini**, **yazi**, **lf**, **nnn**, **ranger**, with **netrw** fallback
- **Search integration** - Auto-launches your preferred search tool (telescope live_grep, snacks grep, fzf-lua live_grep, mini grep_live, or built-in grep)
- **Zero forced dependencies** - No telescope, plenary, or other plugin dependencies required

### 🏗️ **Modern Architecture**

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
  "uhs-robert/sshfs.nvim",
  opts = {
    -- Refer to the configuration section below
    -- or leave empty for defaults
  },
}
```

### Packer.nvim

```lua
use {
  "uhs-robert/sshfs.nvim",
  config = function()
    require("sshfs").setup({
      -- Your configuration here
    })
  end
}
```

### vim-plug

```vim
Plug 'uhs-robert/sshfs.nvim'
```

Then in your `init.lua`:

```lua
require("sshfs").setup({
  -- Your configuration here
})
```

### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/uhs-robert/sshfs.nvim ~/.local/share/nvim/site/pack/plugins/start/sshfs.nvim
```

2. Add to your `init.lua`:

```lua
require("sshfs").setup({
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
require("sshfs").setup({
  connections = {
    sshfs_args = {                  -- these are the sshfs options that will be used
      "-o reconnect",               -- Automatically reconnect if the connection drops
      "-o ConnectTimeout=5",        -- Time (in seconds) to wait before failing a connection attempt
      "-o compression=yes",         -- Enable compression to reduce bandwidth usage
      "-o ServerAliveInterval=15",  -- Send a keepalive packet every 15 seconds to prevent timeouts
      "-o ServerAliveCountMax=3",   -- Number of missed keepalive packets before disconnecting
    },
  },
  mounts = {
    base_dir = vim.fn.expand("$HOME") .. "/mnt", -- where remote mounts are created
    unmount_on_exit = true,                      -- auto-disconnect all mounts on :q or exit
    auto_change_dir_on_mount = false,            -- auto-change current directory to mount point (default: false)
  },
  host_paths = {
    -- Optionally define default mount paths for specific hosts
    -- Single path (string):
    -- ["my-server"] = "/var/www/html"
    --
    -- Multiple paths (array):
    -- ["dev-server"] = { "/var/www", "~/projects", "/opt/app" }
  },
  handlers = {
    on_disconnect = {
      clean_mount_folders = true, -- optionally clean up mount folders after disconnect
    },
  },
  ui = {
    file_picker = {
      preferred_picker = "auto",  -- one of: "auto", "snacks", "fzf-lua", "mini", "telescope", "oil", "neo-tree", "nvim-tree", "yazi", "lf", "nnn", "ranger", "netrw"
      auto_open_on_mount = true,  -- auto-open picker after connecting
      fallback_to_netrw = true,   -- fallback to netrw if no picker is available
    },
  },
  lead_prefix = "<leader>m",      -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>mm",         -- change any keymap below
    unmount = "<leader>mu",
    change_dir = "<leader>md",
    edit = "<leader>me",
    reload = "<leader>mr",
    open = "<leader>mo",
    grep = "<leader>mg",
  },
})
```

> [!TIP]
> The `sshfs_args` table can accept any configuration option that applies to the `sshfs` command. You can learn more about [sshfs mount options here](https://man7.org/linux/man-pages/man1/sshfs.1.html).
>
> In addition, sshfs also supports a variety of options from [sftp](https://man7.org/linux/man-pages/man1/sftp.1.html) and [ssh_config](https://man7.org/linux/man-pages/man5/ssh_config.5.html).

## 🔧 Commands

- `:SSHConnect [host]` - Connect to SSH host (picker or direct)
- `:SSHDisconnect` - Disconnect from current host (picker shown if multiple mounts)
- `:SSHEdit` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHBrowse` - Browse remote files using auto-detected file picker
- `:SSHGrep [pattern]` - Search remote files using auto-detected search tool
- `:SSHChangeDir` - Set current directory to SSH mount (picker shown if multiple mounts)
- `:SSHTerminal` - Open SSH terminal session to remote host (picker shown if multiple mounts)

## 🎹 Key Mapping

This plugin optionally provides default keybindings under `<leader>m`. These can be fully customized.

### 🎯 Default Keymaps

| Mapping      | Description                        |
| ------------ | ---------------------------------- |
| `<leader>mm` | Mount an SSH host                  |
| `<leader>mu` | Unmount an active session          |
| `<leader>md` | Set current directory to SSH mount |
| `<leader>me` | Edit SSH config files              |
| `<leader>mr` | Reload SSH configuration           |
| `<leader>mo` | Browse remote mount                |
| `<leader>mg` | Grep remote files                  |
| `<leader>mt` | Open SSH terminal session          |

If [which-key.nvim](https://github.com/folke/which-key.nvim) is installed, the `<leader>m` group will be labeled with a custom icon (`󰌘`).

### 🛠️ Custom Keymap Configuration

You can override the keymaps or the prefix like this:

```lua
require("sshfs").setup({
  lead_prefix = "<leader>m", -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>mm",
    unmount = "<leader>mu",
    change_dir = "<leader>md",
    edit = "<leader>me",
    reload = "<leader>mr",
    open = "<leader>mo",
    grep = "<leader>mg",
  },
})
```

## 🚀 Usage

### Connecting to a Host

When you run `:SSHConnect`, you'll be prompted to:

1. **Select a host** from your SSH config
2. **Choose a mount location** with the following options:
   - **Home directory (~)**: Mounts your remote home directory
   - **Root directory (/)**: Mounts the entire remote filesystem
   - **Custom path**: Enter any custom path (e.g., `/var/www`, `~/projects`, `/opt/app`)
   - **Configured paths**: Any paths you've defined in `host_paths` for this host

> [!TIP]
> Use `host_paths` to define one or more default paths for frequently-used hosts:
>
> ```lua
> host_paths = {
>   -- Single path
>   ["production-server"] = "/var/www/html",
>
>   -- Multiple paths for the same host
>   ["dev-server"] = {
>     "/var/www",
>     "~/projects",
>     "/opt/app",
>   },
> }
> ```

### Working with Remote Files

After connecting to a host, the plugin mounts the remote filesystem locally. You can then:

1. **Browse files**: Use `:SSHBrowse` to automatically launch your preferred file picker:
   - **Auto-detected pickers**: telescope, oil, neo-tree, nvim-tree, snacks, fzf-lua, mini, yazi, lf, nnn, ranger
   - **Fallback**: netrw if no other picker is available
   - **Your choice**: Configure `preferred_picker = "yazi"` to force a specific picker

2. **Search files**: Use `:SSHGrep [pattern]` to automatically launch your preferred search tool:
   - **Auto-detected search**: telescope live_grep, snacks grep, fzf-lua live_grep, mini grep_live
   - **Fallback**: built-in grep with quickfix list

**🎯 The Magic**: The plugin intelligently detects what you have installed and launches it automatically via lazyloading, respecting your existing Neovim setup and preferences. No configuration required, it just works with whatever you're already using.

## 💡 Tips and Performance

- If key authentication fails, the plugin will prompt for a password up to 3 times before giving up.
- SSH keys vastly speed up repeated mounts (no password prompt), leverage your `ssh_config` rather than manually adding hosts to make this as easy as possible.
