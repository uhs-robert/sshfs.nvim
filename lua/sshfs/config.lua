-- lua/sshfs/config.lua

local Config = {}

-- stylua: ignore start
local DEFAULT_CONFIG = {
	connections = {
		ssh_configs = require("sshfs.lib.ssh_config").get_default_files(),
    sshfs_args = {                      -- These are the sshfs options that will be used
      "-o reconnect",                   -- Automatically reconnect if the connection drops
      "-o ConnectTimeout=5",            -- Time (in seconds) to wait before failing a connection attempt
      "-o compression=yes",             -- Enable compression to reduce bandwidth usage
      "-o ServerAliveInterval=15",      -- Send a keepalive packet every 15 seconds to prevent timeouts
      "-o ServerAliveCountMax=3",       -- Number of missed keepalive packets before disconnecting
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
			clean_mount_folders = true,     -- Unmounts all mounts on nvim exit
		},
	},
	ui = {
		file_picker = {
			auto_open_on_mount = true,      -- Auto-open file picker after mounting
			preferred_picker = "auto",      -- "auto", "telescope", "oil", "neo-tree", "nvim-tree", "snacks", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
			fallback_to_netrw = true,       -- fallback to netrw if no picker is available
		},
	},
	keymaps = nil,                      -- Override individual keymaps (e.g., {mount = "<leader>mm", unmount = "<leader>mu"})
	lead_prefix = "<leader>m",          -- Prefix for default keymaps
}
-- stylua: ignore end

-- Active configuration
Config.options = vim.deepcopy(DEFAULT_CONFIG)

--- Setup configuration
---@param user_config table|nil User configuration to merge with defaults
function Config.setup(user_config)
	user_config = user_config or {}
	Config.options = vim.tbl_deep_extend("force", DEFAULT_CONFIG, user_config)
end

--- Get current configuration
---@return table config The current configuration
function Config.get()
	return Config.options
end

-- Get the configured base directory for mounts
---@return string base_dir The base directory path for mounts
function Config.get_base_dir()
	local opts = Config.options
	return opts.mounts and opts.mounts.base_dir
end

return Config
