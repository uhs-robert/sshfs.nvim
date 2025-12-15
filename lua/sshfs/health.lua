-- lua/sshfs/health.lua
-- Health check for sshfs.nvim plugin
-- Run with :checkhealth sshfs

local Health = {}

-- Compatibility layer for Neovim health API
local health = vim.health or require("health")

--- Check if a command exists in PATH
---@param cmd string Command name to check
---@return boolean exists True if command exists
local function command_exists(cmd)
	return vim.fn.executable(cmd) == 1
end

--- Check if a file or directory exists
---@param path string Path to check
---@return boolean exists True if path exists
local function path_exists(path)
	return vim.fn.filereadable(vim.fn.expand(path)) == 1 or vim.fn.isdirectory(vim.fn.expand(path)) == 1
end

--- Check if a directory is writable
---@param path string Directory path to check
---@return boolean writable True if directory is writable
local function is_writable(path)
	local expanded = vim.fn.expand(path)
	if vim.fn.isdirectory(expanded) == 0 then
		local ok = pcall(vim.fn.mkdir, expanded, "p")
		if not ok then
			return false
		end
	end
	return vim.fn.filewritable(expanded) == 2
end

--- Check if a Neovim plugin is loaded
---@param plugin string Plugin name to check
---@return boolean loaded True if plugin is loaded
local function plugin_loaded(plugin)
	local ok, _ = pcall(require, plugin)
	return ok
end

--- Check system dependencies (sshfs, ssh, mount)
local function check_system_dependencies()
	health.start("System Dependencies")

	-- Check sshfs
	if command_exists("sshfs") then
		local handle = io.popen("sshfs --version 2>&1")
		if handle then
			local version = handle:read("*l")
			handle:close()
			health.ok("sshfs is installed: " .. (version or "version unknown"))
		else
			health.ok("sshfs is installed")
		end
	else
		health.error(
			"sshfs is not installed",
			"Install sshfs: 'sudo apt install sshfs' (Debian/Ubuntu) or 'brew install sshfs' (macOS)"
		)
	end

	-- Check ssh
	if command_exists("ssh") then
		local handle = io.popen("ssh -V 2>&1")
		if handle then
			local version = handle:read("*l")
			handle:close()
			health.ok("ssh is installed: " .. (version or "version unknown"))
		else
			health.ok("ssh is installed")
		end
	else
		health.error(
			"ssh is not installed",
			"Install OpenSSH client: 'sudo apt install openssh-client' (Debian/Ubuntu)"
		)
	end

	-- Check mount detection commands
	if command_exists("mount") then
		health.ok("mount command is available")
	else
		health.warn(
			"mount command is not available",
			"Mount detection may not work properly. Install util-linux package."
		)
	end

	-- Check findmnt (optional, preferred on Linux for faster mount detection)
	if command_exists("findmnt") then
		health.ok("findmnt is available (preferred for mount detection on Linux)")
	else
		health.info("findmnt not found (optional, will use mount command instead)")
	end

	-- Check unmount methods (fusermount, fusermount3, umount)
	-- The plugin tries these in order: fusermount -> fusermount3 -> umount
	local unmount_methods = {
		{ cmd = "fusermount", desc = "fusermount (FUSE2)" },
		{ cmd = "fusermount3", desc = "fusermount3 (FUSE3)" },
		{ cmd = "umount", desc = "umount (fallback)" },
	}

	local available_unmount = {}
	for _, method in ipairs(unmount_methods) do
		if command_exists(method.cmd) then
			table.insert(available_unmount, method.desc)
		end
	end

	if #available_unmount > 0 then
		health.ok("Unmount methods available: " .. table.concat(available_unmount, ", "))
	else
		health.error(
			"No unmount methods found (fusermount, fusermount3, or umount)",
			"Install fuse package: 'sudo apt install fuse3' or 'brew install macfuse'"
		)
	end
end

--- Check SSH configuration
local function check_ssh_config()
	health.start("SSH Configuration")

	local Config = require("sshfs.config")
	local config = Config.get()

	-- Check SSH config files
	local ssh_configs = config.connections.ssh_configs
	local found_configs = {}
	local missing_configs = {}

	for _, config_file in ipairs(ssh_configs) do
		local expanded = vim.fn.expand(config_file)
		if path_exists(expanded) then
			table.insert(found_configs, config_file)
		else
			table.insert(missing_configs, config_file)
		end
	end

	if #found_configs > 0 then
		health.ok("Found SSH config files: " .. table.concat(found_configs, ", "))
	end

	if #missing_configs > 0 then
		health.info("Missing SSH config files (optional): " .. table.concat(missing_configs, ", "))
	end

	if #found_configs == 0 and #missing_configs > 0 then
		health.warn(
			"No SSH config files found",
			"Create ~/.ssh/config to define SSH hosts. You can still use SSHConnect with host arguments."
		)
	end

	-- Check SSH directory permissions
	local ssh_dir = vim.fn.expand("~/.ssh")
	if vim.fn.isdirectory(ssh_dir) == 1 then
		health.ok("SSH directory exists: " .. ssh_dir)

		-- Check socket directory
		local socket_dir = Config.get_socket_dir()
		if vim.fn.isdirectory(socket_dir) == 0 then
			local ok = pcall(vim.fn.mkdir, socket_dir, "p")
			if ok then
				health.ok("Created SSH socket directory: " .. socket_dir)
			else
				health.warn(
					"Could not create SSH socket directory: " .. socket_dir,
					"ControlMaster connections may not work. Create directory manually with: mkdir -p " .. socket_dir
				)
			end
		else
			health.ok("SSH socket directory exists: " .. socket_dir)
		end
	else
		health.warn(
			"SSH directory does not exist: " .. ssh_dir,
			"Create SSH directory with: mkdir -p ~/.ssh && chmod 700 ~/.ssh"
		)
	end
end

--- Check mount configuration
local function check_mount_config()
	health.start("Mount Configuration")

	local Config = require("sshfs.config")
	local config = Config.get()

	local base_dir = config.mounts.base_dir
	local expanded = vim.fn.expand(base_dir)

	-- Check if base directory exists or can be created
	if vim.fn.isdirectory(expanded) == 1 then
		health.ok("Mount base directory exists: " .. base_dir)
	else
		local ok = pcall(vim.fn.mkdir, expanded, "p")
		if ok then
			health.ok("Created mount base directory: " .. base_dir)
		else
			health.error(
				"Cannot create mount base directory: " .. base_dir,
				"Create directory manually with: mkdir -p " .. expanded
			)
			return -- Don't check writability if we can't create it
		end
	end

	-- Check if directory is writable
	if is_writable(base_dir) then
		health.ok("Mount base directory is writable")
	else
		health.error(
			"Mount base directory is not writable: " .. base_dir,
			"Fix permissions with: chmod u+w " .. expanded
		)
	end

	-- Info about auto_unmount setting
	local on_exit = config.hooks and config.hooks.on_exit or {}
	if on_exit.auto_unmount then
		health.info("Auto-unmount on exit is enabled")
	else
		health.info("Auto-unmount on exit is disabled (mounts will persist)")
	end
	if on_exit.clean_mount_folders then
		health.info("Mount folders will be cleaned after unmount")
	else
		health.info("Mount folders will be left on disk after unmount")
	end

	-- Info about auto_change_to_dir setting
	local hook_cfg = config.hooks and config.hooks.on_mount or {}
	if hook_cfg.auto_change_to_dir then
		health.info("Auto-change directory on mount is enabled")
	else
		health.info("Auto-change directory on mount is disabled")
	end
end

--- Check file picker integrations
local function check_integrations()
	health.start("File Picker Integrations")

	local Config = require("sshfs.config")
	local config = Config.get()
	local preferred = config.ui.local_picker.preferred_picker

	health.info("Preferred picker: " .. preferred)

	-- List of known integrations
	local integrations = {
		{ name = "telescope", plugin = "telescope" },
		{ name = "oil", plugin = "oil" },
		{ name = "snacks", plugin = "snacks" },
		{ name = "neo-tree", plugin = "neo-tree" },
		{ name = "nvim-tree", plugin = "nvim-tree" },
		{ name = "fzf-lua", plugin = "fzf-lua" },
		{ name = "mini.files", plugin = "mini.files" },
	}

	-- Check external file managers
	local file_managers = {
		{ name = "yazi", cmd = "yazi" },
		{ name = "lf", cmd = "lf" },
		{ name = "nnn", cmd = "nnn" },
		{ name = "ranger", cmd = "ranger" },
	}

	local available_pickers = {}
	local available_managers = {}

	-- Check plugin-based pickers
	for _, integration in ipairs(integrations) do
		if plugin_loaded(integration.plugin) then
			table.insert(available_pickers, integration.name)
		end
	end

	-- Check external file managers
	for _, manager in ipairs(file_managers) do
		if command_exists(manager.cmd) then
			table.insert(available_managers, manager.name)
		end
	end

	-- Report available integrations
	if #available_pickers > 0 then
		health.ok("Available plugin pickers: " .. table.concat(available_pickers, ", "))
	else
		health.info("No plugin-based file pickers detected")
	end

	if #available_managers > 0 then
		health.ok("Available file managers: " .. table.concat(available_managers, ", "))
	else
		health.info("No external file managers detected")
	end

	-- Fallback to netrw
	if #available_pickers == 0 and #available_managers == 0 then
		if config.ui.local_picker.fallback_to_netrw then
			health.ok("Will fallback to netrw (built-in)")
		else
			health.warn(
				"No file pickers available and netrw fallback is disabled",
				"Enable netrw fallback or install a file picker plugin (telescope, oil, snacks, etc.)"
			)
		end
	end

	-- Check if preferred picker is available
	if preferred ~= "auto" then
		local is_available = vim.tbl_contains(available_pickers, preferred)
			or vim.tbl_contains(available_managers, preferred)

		if is_available then
			health.ok("Preferred picker '" .. preferred .. "' is available")
		else
			health.warn(
				"Preferred picker '" .. preferred .. "' is not available",
				"Install the picker or set preferred_picker to 'auto' in config"
			)
		end
	end
end

--- Check plugin configuration
local function check_configuration()
	health.start("Plugin Configuration")

	local ok, Config = pcall(require, "sshfs.config")
	if not ok then
		health.error("Could not load sshfs.config module", "Plugin may not be installed correctly")
		return
	end

	local config = Config.get()

	-- Validate SSHFS options
	if config.connections.sshfs_options then
		health.ok("SSHFS options are configured")

		-- Check for recommended options
		if config.connections.sshfs_options.reconnect then
			health.ok("Auto-reconnect is enabled (recommended)")
		else
			health.info("Auto-reconnect is disabled (connections may drop)")
		end

		if config.connections.sshfs_options.compression then
			health.ok("Compression is enabled (recommended for slow connections)")
		end

		if config.connections.sshfs_options.ServerAliveInterval then
			health.ok("Keep-alive is configured (prevents connection timeouts)")
		else
			health.info("Keep-alive not configured (connections may timeout)")
		end
	end

	-- Check ControlMaster configuration
	if config.connections.control_persist then
		health.ok("ControlMaster persist time: " .. config.connections.control_persist)
	else
		health.warn("ControlMaster persist time not configured", "SSH terminal sessions may require re-authentication")
	end

	-- Check host_paths configuration
	if config.host_paths and next(config.host_paths) then
		local count = 0
		for _ in pairs(config.host_paths) do
			count = count + 1
		end
		health.ok("Custom host paths configured for " .. count .. " host(s)")
	else
		health.info("No custom host paths configured (will prompt on connect)")
	end

	health.ok("Plugin configuration is valid")
end

--- Main health check function
function Health.check()
	check_system_dependencies()
	check_ssh_config()
	check_mount_config()
	check_integrations()
	check_configuration()

	health.start("Summary")
	health.info("Run :SSHConnect to test connection, :SSHFiles to test file browsing")
	health.info("See :help sshfs.nvim for documentation")
end

return Health
