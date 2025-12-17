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
A fast <strong>SSHFS/SSH</strong> integration for <strong>NeoVim</strong> that <strong>works with your setup</strong>.
</p>

## 🕶️ What It Is & Why

sshfs.nvim mounts hosts from your SSH config and makes them feel local.

You can **browse**, **search**, **run commands**, or **open SSH terminals** across multiple mounts without changing your workflow.

It stays lightweight and modern: no forced dependencies.

Built for Neovim 0.10+ using the best of both `sshfs` and `ssh` in tandem with your existing tools.

<https://github.com/user-attachments/assets/d6453878-f93b-429a-9f36-8580cd9ed889>

<details>
<summary>✨ What's New / 🚨 Breaking Changes</summary>
<br/>
<!-- whats-new:start -->

  <details>
    <summary>🚨 v2.0 Breaking Changes </summary>
    <h3>Config restructure with hooks</h3>
    <ul>
      <li><code>mounts.unmount_on_exit</code> → <code>hooks.on_exit.auto_unmount</code></li>
      <li><code>mounts.auto_change_dir_on_mount</code> → <code>hooks.on_mount.auto_change_to_dir</code></li>
      <li><code>ui.file_picker</code> → <code>ui.local_picker</code></li>
      <li><code>ui.file_picker.auto_open_on_mount</code> → <code>hooks.on_mount.auto_run</code></li>
    </ul>
    <h3>SSH-first ControlMaster required</h3>
    <ul>
      <li>Mounting now tries a non-interactive socket first, then opens an auth terminal. This passes all login responsibility to ssh which enables native support for the ssh authentication flow.</li>
    </ul>
    <h3><code>sshfs_options</code> format change</h3>
    <ul>
      <li><code>connections.sshfs_options</code> must be a key/value table (e.g., <code>{ reconnect = true, ConnectTimeout = 5 }</code>); string arrays are ignored.</li>
      <ul>
        <li>Strings/numbers render as <code>key=value</code></li>
        <li>Boolean <code>true/false</code> enables/disables options, the value of <code>nil</code> also disables</li>
      </ul>
    </ul>
    <h3>Commands, API, and keymap renames (aliases will be removed after January 15, 2026)</h3>
    <ul>
      <li><strong>Commands:</strong> The following have beep deprecated:
        <ul>
          <li><code>:SSHEdit</code> → <code>:SSHConfig</code></li>
          <li><code>:SSHBrowse</code> → <code>:SSHFiles</code></li>
        </ul>
      </li>
      <li><strong>API:</strong> The following have beep deprecated:
        <ul>
          <li><code>edit</code> → <code>config</code></li>
          <li><code>browse</code> → <code>files</code></li>
          <li><code>change_to_mount_dir</code> → <code>change_dir</code></li>
        </ul>
      </li>
      <li><strong>Keymaps:</strong> The following have beep deprecated:
        <ul>
          <li><code>open_dir</code> → <code>change_dir</code></li>
          <li><code>open</code> → <code>files</code></li>
          <li><code>edit</code> → <code>config</code></li>
        </ul>
      </li>
    </ul>

  </details>

<!-- whats-new:end -->
</details>

## ✨ Features

- **Uses your toolkit** – Auto-detects **snacks**, **telescope**, **fzf-lua**, **mini**, **oil**, **yazi**, **nnn**, **ranger**, **lf**, **neo-tree**, **nvim-tree**, or **netrw**.
- **Auth that sticks** – ControlMaster sockets + floating auth handle keys/passwords/2FA once, then reuse for mounts, live search, terminals, git, or scp.
- **Real SSH config support** – Honors Include/Match/ProxyJump and all `ssh_config` options via `ssh -G`; optional per-host default paths.
- **On-mount hooks** – Auto-run find/grep/live find/live grep/terminal or your own function after connecting.
- **Live remote search** – Stream `rg`/`find` over SSH (snacks, fzf-lua, telescope, mini) while keeping mounts quiet.
- **Multi-mount aware** – Connect to several hosts, clean up on exit, and jump between mounts with keymaps or commands.
- **Command suite** – `:SSHFiles`, `:SSHGrep`, `:SSHLiveFind/Grep`, `:SSHTerminal`, `:SSHCommand`, `:SSHChangeDir`, `:SSHConfig`, `:SSHReload`.
- **Host-aware defaults** – Optional global and per-host default paths so you can skip path selection on common servers.
- **Modern Neovim** – Built for 0.10+ with `vim.uv` for reliable jobs, sockets, and cleanup.

## 📋 Requirements

| Software   | Minimum       | Notes                                                                                            |
| ---------- | ------------- | ------------------------------------------------------------------------------------------------ |
| Neovim     | `>=0.10`      | Requires `vim.uv` support                                                                        |
| sshfs      | any           | `sudo dnf/apt/pacman install sshfs` or `brew install sshfs`                                      |
| SSH client | any           | OpenSSH with ControlMaster support (default). Socket directory created automatically if missing. |
| SSH config | working hosts | Hosts come from `~/.ssh/config`                                                                  |

> [!NOTE]
> For Mac users, see the macOS setup steps below.

---

### 🍏 macOS Setup

To use **sshfs.nvim** on macOS, follow these steps:

1. **Install macFUSE**
   Download and install macFUSE from the official site:
   [https://macfuse.github.io/](https://macfuse.github.io/)

2. **Install SSHFS for macFUSE**
   Use the official SSHFS releases compatible with macFUSE:
   [https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS](https://github.com/macfuse/macfuse/wiki/File-Systems-%E2%80%90-SSHFS)

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
    socket_dir = vim.fn.expand("$HOME/.ssh/sockets"), -- Directory for ControlMaster sockets
  },
  mounts = {
    base_dir = vim.fn.expand("$HOME") .. "/mnt", -- where remote mounts are created
  },
  global_paths = {
    -- Optionally define default mount paths for ALL hosts
    -- These appear as options when connecting to any host
    -- Examples:
    -- "~/.config",
    -- "/var/www",
    -- "/srv",
    -- "/opt",
    -- "/var/log",
    -- "/etc",
    -- "/tmp",
    -- "/usr/local",
    -- "/data",
    -- "/var/lib",
  },
  host_paths = {
    -- Optionally define default mount paths for specific hosts
    -- These are shown in addition to global_paths
    -- Single path (string):
    -- ["my-server"] = "/var/www/html"
    --
    -- Multiple paths (array):
    -- ["dev-server"] = { "/var/www", "~/projects", "/opt/app" }
  },
  hooks = {
    on_exit = {
      auto_unmount = true,        -- auto-disconnect all mounts on :q or exit
      clean_mount_folders = true, -- optionally clean up mount folders after disconnect
    },
    on_mount = {
      auto_change_to_dir = false, -- auto-change current directory to mount point
      auto_run = "find",          -- "find" (default), "grep", "live_find", "live_grep", "terminal", "none", or a custom function(ctx)
    },
  },
  ui = {
    file_picker = {
      preferred_picker = "auto",  -- one of: "auto", "snacks", "fzf-lua", "mini", "telescope", "oil", "neo-tree", "nvim-tree", "yazi", "lf", "nnn", "ranger", "netrw"
      fallback_to_netrw = true,   -- fallback to netrw if no picker is available
      netrw_command = "Explore",  -- netrw command: "Explore", "Lexplore", "Sexplore", "Vexplore", "Texplore"
    },
    remote_picker = {
      preferred_picker = "auto",  -- one of: "auto", "snacks", "fzf-lua", "telescope", "mini"
    },
  },
  lead_prefix = "<leader>m",      -- change keymap prefix (default: <leader>m)
  keymaps = {
    mount = "<leader>mm",         -- creates an ssh connection and mounts via sshfs
    unmount = "<leader>mu",       -- disconnects an ssh connection and unmounts via sshfs
    unmount_all = "<leader>mU",   -- disconnects all ssh connections and unmounts via sshfs
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

> [!NOTE]
> ControlMaster sockets are stored at `~/.ssh/sockets/%C` (configurable via `connections.socket_dir`). The directory is created automatically with proper permissions (0700) during the first connection.

## 🔧 Commands

- `:checkhealth sshfs` - Verify dependencies and configuration
- `:SSHConnect [host]` - Mount a remote host
- `:SSHDisconnect` - Unmount current host
- `:SSHDisconnectAll` - Unmount all hosts
- `:SSHConfig` - Edit SSH config files
- `:SSHReload` - Reload SSH configuration
- `:SSHFiles` - Find files with auto-detected picker
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
| `<leader>mU` | Unmount all active sessions       |
| `<leader>me` | Explore SSH mount via native edit |
| `<leader>md` | Change dir to mount               |
| `<leader>mo` | Run command on mount              |
| `<leader>mc` | Edit SSH config                   |
| `<leader>mr` | Reload SSH configuration          |
| `<leader>mf` | Find files                        |
| `<leader>mg` | Grep files                        |
| `<leader>mF` | Live find (remote)                |
| `<leader>mG` | Live grep (remote)                |
| `<leader>mt` | Open SSH terminal session         |

If [which-key.nvim](https://github.com/folke/which-key.nvim) is installed, the `<leader>m` group will be labeled with a custom icon (`󰌘`).

## 🚀 Usage

1. `:SSHConnect` — pick a host and mount path (home/root/custom/global_paths/host_paths).
2. Work from the mount:
   - `:SSHFiles`, `:SSHGrep`, or `:SSHChangeDir`
   - Live remote search: `:SSHLiveFind` / `:SSHLiveGrep` (streams over SSH, still mounted)
   - Terminals/commands: `:SSHTerminal`, `:SSHCommand`
3. Disconnect with `:SSHDisconnect` (or let `hooks.on_exit.auto_unmount` handle it).

Auth flow: keys first, then floating terminal for passphrases/passwords/2FA; ControlMaster keeps the session alive across operations.

## 💡 Tips

- **Use SSH keys** for faster connections (no password prompts)
- **Configure `global_paths`** with common directories (`/var/www`, `/var/log`, `~/.config`) to have them available across all hosts
- **Configure `host_paths`** for frequently-used hosts to skip path selection
- **Set `preferred_picker` for local/remote pickers** to force specific file picker(s) instead of auto-detection
