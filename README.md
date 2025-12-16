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

sshfs.nvim mounts hosts from your SSH config and makes them feel local. You can bbrowse, search, change directories, run commands, or open SSH terminals across multiple mounts without changing your workflow.

It stays lightweight and modern: no forced dependencies, built for Neovim 0.10+ with `sshfs` and `ssh` toolkits using your existing tools.

<https://github.com/user-attachments/assets/20419da8-37b9-4325-a942-90a85754ce11>

<details>
<summary>✨ What's New / 🚨 Breaking Changes</summary>
<br/>
<!-- whats-new:start -->

  <details>
    <summary>🚨 v2.0 Breaking Changes </summary>
    <h3>Config reshuffle & hooks</h3>
    <ul>
      <li><code>mounts.unmount_on_exit</code> → <code>hooks.on_exit.auto_unmount</code>; <code>mounts.auto_change_dir_on_mount</code> → <code>hooks.on_mount.auto_change_to_dir</code>.</li>
      <li><code>ui.file_picker</code> → <code>ui.local_picker</code>; removed <code>ui.file_picker.auto_open_on_mount</code> in favor of <code>hooks.on_mount.auto_run</code>.</li>
    </ul>
    <h3>SSH-first ControlMaster required</h3>
    <ul>
      <li>Mounting now tries a non-interactive socket first, then opens an auth terminal. This passes all login responsibility to ssh to support 2FA etc.</li>
    </ul>
    <h3><code>sshfs_options</code> format change</h3>
    <ul>
      <li><code>connections.sshfs_options</code> must be a key/value table (e.g., <code>{ reconnect = true, ConnectTimeout = 5 }</code>); string arrays are ignored.</li>
      <li>Booleans <code>true</code> add flags, strings/numbers render as <code>key=value</code>, and <code>false</code>/nil drop the option.</li>
    </ul>
    <h3>Commands, API, and keymaps renamed (aliases removed after January 15, 2026)</h3>
    <ul>
      <li>API: use <code>config</code>/<code>files</code>/<code>explore</code>; old <code>edit</code>/<code>browse</code>/<code>change_to_mount_dir</code> are deprecated.</li>
      <li>Commands: use <code>:SSHConfig</code>, <code>:SSHFiles</code>, <code>:SSHExplore</code>; legacy <code>:SSHEdit</code> and <code>:SSHBrowse</code> only warn for now (the new <code>:SSHChangeDir</code> strictly changes the current directory).</li>
      <li>Keymap option names now <code>config</code>, <code>files</code>, <code>explore</code>; deprecated <code>edit</code>/<code>open</code>/<code>open_dir</code> will stop working after January 15, 2026.</li>
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
- **Host-aware defaults** – Optional per-host default paths so you can skip path prompts on common servers.
- **Modern Neovim** – Built for 0.10+ with `vim.uv` for reliable jobs, sockets, and cleanup.

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
  },
  host_paths = {
    -- Optionally define default mount paths for specific hosts
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

1. `:SSHConnect` — pick a host and mount path (home/root/custom/host_paths).
2. Work from the mount:
   - `:SSHFiles`, `:SSHGrep`, or `:SSHChangeDir`
   - Live remote search: `:SSHLiveFind` / `:SSHLiveGrep` (streams over SSH, still mounted)
   - Terminals/commands: `:SSHTerminal`, `:SSHCommand`
3. Disconnect with `:SSHDisconnect` (or let `hooks.on_exit.auto_unmount` handle it).

Auth flow: keys first, then floating terminal for passphrases/passwords/2FA; ControlMaster keeps the session alive across operations.

## 💡 Tips

- **Use SSH keys** for faster connections (no password prompts)
- **Configure `host_paths`** for frequently-used hosts to skip path selection
- **Set `preferred_picker` for local/remote pickers** to force specific file picker(s) instead of auto-detection
