-- lua/sshfs/config.lua

local Config = {}

-- stylua: ignore start
local DEFAULT_CONFIG = {
	connections = {
		ssh_configs = require("sshfs.lib.ssh_config").get_default_files(),
    -- SSHFS mount options (table of key-value pairs converted to sshfs -o arguments)
    -- Boolean flags: set to true to include, false/nil to omit
    -- String/number values: converted to key=value format
    sshfs_options = {
      reconnect = true,                 -- Auto-reconnect on connection loss
      ConnectTimeout = 5,               -- Connection timeout in seconds
      compression = "yes",              -- Enable compression
      ServerAliveInterval = 15,         -- Keep-alive interval (15s × 3 = 45s timeout)
      ServerAliveCountMax = 3,          -- Keep-alive message count
      dir_cache = "yes",                -- Enable directory caching
      dcache_timeout = 300,             -- Cache timeout in seconds
      dcache_max_size = 10000,          -- Max cache size
      -- allow_other = true,            -- Allow other users to access mount
      -- uid = "1000,gid=1000",         -- Set file ownership (use string for complex values)
      -- follow_symlinks = true,        -- Follow symbolic links
    },
    control_persist = "10m",            -- How long to keep ControlMaster connection alive after last use
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
			netrw_command = "Explore",      -- "Explore", "Lexplore", "Sexplore", "Vexplore", "Texplore"
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

--- Get the configured base directory for mounts
---@return string base_dir The base directory path for mounts
function Config.get_base_dir()
	local opts = Config.options
	return opts.mounts and opts.mounts.base_dir
end

--- Get ControlMaster options for SSH/SSHFS
---@return table Array of ControlMaster options
function Config.get_control_master_options()
	local opts = Config.options
	local socket_dir = vim.fn.expand("$HOME/.ssh/sockets")
	local control_path = socket_dir .. "/%C"
	local control_persist = (opts.connections and opts.connections.control_persist) or "10m"

	return {
		"ControlMaster=auto",
		"ControlPath=" .. control_path,
		"ControlPersist=" .. control_persist,
	}
end

--- Get SSH socket directory path
---@return string socket_dir The socket directory path
function Config.get_socket_dir()
	return vim.fn.expand("$HOME/.ssh/sockets")
end

return Config
