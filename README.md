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

Mount remote hosts from your SSH config and work with remote files/hosts as if they were local.

Browse, search, change directories, run commands, or open ssh terminal connections from NeoVim with zero forced dependencies.

Auto-detects your tools: **snacks**, **telescope**, **fzf-lua**, **mini**, **oil**, **yazi**, **nnn**, **ranger**, **lf**, **neo-tree**, **nvim-tree**, or **netrw**.

<https://github.com/user-attachments/assets/20419da8-37b9-4325-a942-90a85754ce11>

## ✨ Features

- **Zero dependencies** - Works with your existing file pickers and search tools, no forced plugins
- **Auto-detection** - Launches telescope, oil, snacks, fzf-lua, mini, yazi, neo-tree, nvim-tree, ranger, lf, nnn, or netrw
- **Live remote search** - Stream `rg`/`find` over SSH with snacks, fzf-lua, telescope, or mini (no local mount thrashing)
- **Flexible workflow** - Explore files, change directories (`tcd`), run custom commands, or open SSH terminals
- **Universal auth** - Handles SSH keys, 2FA, passwords, passphrases, host verification via floating terminal
- **ControlMaster** - Enter credentials once, reuse for all operations (mount, terminal, git, scp)
- **Full SSH config** - Supports Include, Match, ProxyJump, and all `ssh_config` features via `ssh -G`
- **Modern Neovim** - Built for 0.10+ with vim.uv, modular architecture, cross-platform

## 📋 Requirements

| Software   | Minimum       | Notes                                                                                                  |
| ---------- | ------------- | ------------------------------------------------------------------------------------------------------ |
| Neovim     | `>=0.10`      | Requires `vim.uv` support                                                                              |
| sshfs      | any           | `sudo dnf/apt/pacman install sshfs` or `brew install sshfs`                                            |
| SSH client | any           | OpenSSH with ControlMaster support (default). Create `~/.ssh/sockets` (chmod 700) for control sockets. |
| SSH config | working hosts | Hosts come from `~/.ssh/config`                                                                        |

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
    ssh_configs = {                 -- Table of ssh config file locations to use
      "~/.ssh/config",
      "/etc/ssh/ssh_config",
    },
    -- SSHFS mount options (table of key-value pairs converted to sshfs -o arguments)
    -- Boolean flags: set to true to include, false/nil to omit
    -- String/number values: converted to key=value format
    sshfs_options = {
      reconnect = true,             -- Auto-reconnect on connection loss
      ConnectTimeout = 5,           -- Connection timeout in seconds
      compression = "yes",          -- Enable compression
      ServerAliveInterval = 15,     -- Keep-alive interval (15s × 3 = 45s timeout)
      ServerAliveCountMax = 3,      -- Keep-alive message count
      dir_cache = "yes",            -- Enable directory caching
      dcache_timeout = 300,         -- Cache timeout in seconds
      dcache_max_size = 10000,      -- Max cache size
      -- allow_other = true,        -- Allow other users to access mount
      -- uid = "1000,gid=1000",     -- Set file ownership (use string for complex values)
      -- follow_symlinks = true,    -- Follow symbolic links
    },
    control_persist = "10m",        -- How long to keep ControlMaster connection alive after last use
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
      netrw_command = "Explore",  -- netrw command: "Explore", "Lexplore", "Sexplore", "Vexplore", "Texplore"
    },
    live_remote_picker = {
      preferred_picker = "auto",  -- one of: "auto", "snacks", "fzf-lua", "telescope", "mini"
    },
  },
  lead_prefix = "<leader>m",      -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>mm",         -- creates an ssh connection and mounts via sshfs
    unmount = "<leader>mu",       -- disconnects an ssh connection and unmounts via sshfs
    explore = "<leader>me",       -- explore an sshfs mount using your native editor
    change_dir = "<leader>md",    -- change dir to mount
    command = "<leader>mo",       -- run command on mount
    config = "<leader>mc",        -- edit ssh config
    reload = "<leader>mr",        -- manually reload ssh config
    files = "<leader>mf",         -- browse files using chosen picker
    grep = "<leader>mg",          -- grep files using chosen picker
    terminal = "<leader>mt",      -- open ssh terminal session
  },
})
```

> [!TIP]
> The `sshfs_args` table can accept any configuration option that applies to the `sshfs` command. You can learn more about [sshfs mount options here](https://man7.org/linux/man-pages/man1/sshfs.1.html).
>
> In addition, sshfs also supports a variety of options from [sftp](https://man7.org/linux/man-pages/man1/sftp.1.html) and [ssh_config](https://man7.org/linux/man-pages/man5/ssh_config.5.html).

> [!IMPORTANT]
> ControlMaster sockets are stored at `~/.ssh/sockets/%C`. If the directory doesn't exist, create it once:
>
> ```bash
> mkdir -p ~/.ssh/sockets && chmod 700 ~/.ssh/sockets
> ```

## 🔧 Commands

- `:checkhealth sshfs` - Verify dependencies and configuration
- `:SSHConnect [host]` - Mount a remote host
- `:SSHDisconnect` - Unmount current host
- `:SSHConfig` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHFiles` - Browse files with auto-detected picker
- `:SSHGrep [pattern]` - Search files with auto-detected tool
- `:SSHLiveFind [pattern]` - Stream remote `find`/`fd` results over SSH (snacks/fzf-lua/telescope/mini)
- `:SSHLiveGrep [pattern]` - Stream remote `rg`/`grep` results over SSH (snacks/fzf-lua/telescope/mini)
- `:SSHExplore` - Open file browser on mount
- `:SSHChangeDir` - Change directory to mount (`tcd`)
- `:SSHCommand [cmd]` - Run custom command (e.g. `Oil`, `Telescope`)
- `:SSHTerminal` - Open terminal session (reuses auth)

## 🎹 Key Mapping

Default keybindings under `<leader>m` (fully customizable):

| Mapping      | Description                       |
| ------------ | --------------------------------- |
| `<leader>mm` | Mount an SSH host                 |
| `<leader>mu` | Unmount an active session         |
| `<leader>me` | Explore SSH mount via native edit |
| `<leader>md` | Change dir to mount               |
| `<leader>mo` | Run command on mount              |
| `<leader>mc` | Edit SSH config                   |
| `<leader>mr` | Reload SSH configuration          |
| `<leader>mf` | Browse files                      |
| `<leader>mg` | Grep files                        |
| `<leader>mF` | Live find (remote)                |
| `<leader>mG` | Live grep (remote)                |
| `<leader>mt` | Open SSH terminal session         |

If [which-key.nvim](https://github.com/folke/which-key.nvim) is installed, the `<leader>m` group will be labeled with a custom icon (`󰌘`).

## 🚀 Usage

Run `:SSHConnect` to select a host and mount location (home, root, custom path, or configured `host_paths`).

After mounting, use `:SSHFiles` to browse with your auto-detected picker, `:SSHGrep` to search, `:SSHChangeDir` to change directories, or `:SSHCommand` to run custom commands.

For large repos on slow links, you still mount first, but `:SSHLiveFind` / `:SSHLiveGrep` run `find`/`rg` over SSH and stream results instead of traversing the mounted filesystem; previews and opens are handled by snacks, fzf-lua, telescope, or mini.

**Auth**: Tries SSH keys first, then opens floating terminal for passwords/2FA/passphrases. ControlMaster reuses the connection for all operations.

> [!TIP]
> Define default paths per host:
> ```lua
> host_paths = {
>   ["prod"] = "/var/www/html",
>   ["dev"] = { "/var/www", "~/projects" },  -- multiple paths
> }
> ```

## 💡 Tips

- **Use SSH keys** for faster connections (no password prompts)
- **ControlMaster** enables connection reuse - enter credentials once, works for mount, terminal, git, scp
- **Configure `host_paths`** for frequently-used hosts to skip path selection
- **Set `preferred_picker`** to force a specific file picker instead of auto-detection
