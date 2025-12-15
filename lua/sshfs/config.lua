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
		on_mount = {
			auto_change_to_dir = false,       -- auto-change current directory to mount point
			-- Action to run after a successful mount
			-- "find" (default): open file picker
			-- "grep": open grep picker
			-- "live_find": run remote find over SSH and stream results
			-- "live_grep": run remote rg/grep over SSH and stream results
			-- "terminal": open SSH terminal to the mounted host
			-- "none" or nil: do nothing
			-- function(ctx): custom handler with { mount_path, host, remote_path }
			auto_run = "find",
		},
		on_exit = {
			auto_unmount = true,              -- auto-disconnect all mounts on :q or exit
			clean_mount_folders = true,       -- Unmounts all mounts on nvim exit
		},
	},
	ui = {
		-- Used for mounted file operations
		local_picker = {
			preferred_picker = "auto",      -- "auto", "telescope", "oil", "neo-tree", "nvim-tree", "snacks", "fzf-lua", "mini", "yazi", "lf", "nnn", "ranger", "netrw"
			fallback_to_netrw = true,       -- fallback to netrw if no picker is available
			netrw_command = "Explore",      -- "Explore", "Lexplore", "Sexplore", "Vexplore", "Texplore"
		},
		-- Used for remote streaming operations (live_grep, live_find)
		remote_picker = {
			preferred_picker = "auto",      -- "auto", "telescope", "fzf-lua", "snacks", "mini"
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

	-- TODO: Delete after January 15th from here...
	-- Backward compatibility shims for renamed config keys (remove after next release)
	local function apply_deprecations(cfg)
		cfg = cfg or {}

		-- ui.file_picker -> ui.local_picker
		if cfg.ui and cfg.ui.file_picker then
			cfg.ui.local_picker = vim.tbl_deep_extend("force", cfg.ui.local_picker or {}, cfg.ui.file_picker)
			vim.notify(
				"sshfs.nvim: `ui.file_picker` is deprecated; use `ui.local_picker` (will be removed in next release)",
				vim.log.levels.WARN
			)
		end

		-- mounts.unmount_on_exit -> hooks.on_exit.auto_unmount
		if cfg.mounts and cfg.mounts.unmount_on_exit ~= nil then
			cfg.hooks = cfg.hooks or {}
			cfg.hooks.on_exit = cfg.hooks.on_exit or {}
			cfg.hooks.on_exit.auto_unmount = cfg.mounts.unmount_on_exit
			vim.notify(
				"sshfs.nvim: `mounts.unmount_on_exit` is deprecated; use `hooks.on_exit.auto_unmount` (will be removed in next release)",
				vim.log.levels.WARN
			)
		end

		-- mounts.auto_change_dir_on_mount -> hooks.on_mount.auto_change_to_dir
		if cfg.mounts and cfg.mounts.auto_change_dir_on_mount ~= nil then
			cfg.hooks = cfg.hooks or {}
			cfg.hooks.on_mount = cfg.hooks.on_mount or {}
			cfg.hooks.on_mount.auto_change_to_dir = cfg.mounts.auto_change_dir_on_mount
			vim.notify(
				"sshfs.nvim: `mounts.auto_change_dir_on_mount` is deprecated; use `hooks.on_mount.auto_change_to_dir` (will be removed in next release)",
				vim.log.levels.WARN
			)
		end

		return cfg
	end

	user_config = apply_deprecations(user_config)
	-- TODO: To here...
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
