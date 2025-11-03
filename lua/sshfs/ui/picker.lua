-- lua/sshfs/ui/picker.lua
-- Smart file picker and search picker auto-detection (telescope, oil, snacks, etc.) with vim.ui.select and netrw fallbacks

local ssh_config = require("sshfs.core.config")

local M = {}

-- File picker detection and auto-launch functions
local function try_telescope_files(cwd)
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok and telescope.find_files then
		telescope.find_files({ cwd = cwd })
		return true
	end
	return false
end

local function try_oil(cwd)
	local ok, oil = pcall(require, "oil")
	if ok and oil.open then
		oil.open(cwd)
		return true
	end
	return false
end

local function try_neo_tree(cwd)
	local ok = pcall(function()
		vim.cmd("Neotree filesystem reveal dir=" .. vim.fn.fnameescape(cwd))
	end)
	return ok
end

local function try_nvim_tree(cwd)
	local ok = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(cwd))
		vim.cmd("NvimTreeOpen")
	end)
	return ok
end

local function try_snacks_files(cwd)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.files then
		snacks.picker.files({ cwd = cwd })
		return true
	end
	return false
end

local function try_fzf_lua_files(cwd)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.files then
		fzf.files({ cwd = cwd })
		return true
	end
	return false
end

local function try_mini_files(cwd)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.files then
		mini_pick.builtin.files({ source = { cwd = cwd } })
		return true
	end
	return false
end

-- Neovim plugin-based file managers
local function try_yazi(cwd)
	local ok, yazi = pcall(require, "yazi")
	if ok and yazi.yazi then
		yazi.yazi({ open_for_directories = true }, cwd)
		return true
	end
	return false
end

local function try_lf(cwd)
	local ok, lf = pcall(require, "lf")
	if ok and lf.start then
		lf.start(cwd)
		return true
	end
	return false
end

local function try_nnn(cwd)
	local ok, _ = pcall(require, "nnn")
	if ok then
		-- nnn.nvim uses a command interface
		local success = pcall(function()
			vim.cmd("NnnPicker " .. vim.fn.fnameescape(cwd))
		end)
		return success
	end
	return false
end

local function try_ranger(cwd)
	-- Try ranger.nvim first
	local ok, ranger = pcall(require, "ranger-nvim")
	if ok and ranger.open then
		ranger.open(true)
		return true
	end

	-- Try rnvimr as alternative
	local rnvimr_ok = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(cwd))
		vim.cmd("RnvimrToggle")
	end)
	return rnvimr_ok
end

local function try_netrw(cwd)
	local ok = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(cwd))
		vim.cmd("Explore")
	end)
	return ok
end

-- Main function to try opening file picker
function M.try_open_file_picker(cwd, config, is_manual)
	local file_picker_config = config.file_picker or {}
	local auto_open = file_picker_config.auto_open_on_mount ~= false -- default true
	local preferred = file_picker_config.preferred_picker or "auto"
	local fallback_to_netrw = file_picker_config.fallback_to_netrw ~= false -- default true

	-- Only check auto_open setting for automatic calls (not manual user commands)
	if not is_manual and not auto_open then
		return false, "Auto-open disabled"
	end

	-- Try preferred picker first if specified
	if preferred ~= "auto" then
		local pickers = {
			telescope = try_telescope_files,
			snacks = try_snacks_files,
			oil = try_oil,
			["neo-tree"] = try_neo_tree,
			["nvim-tree"] = try_nvim_tree,
			["fzf-lua"] = try_fzf_lua_files,
			mini = try_mini_files,
			yazi = try_yazi,
			lf = try_lf,
			nnn = try_nnn,
			ranger = try_ranger,
			netrw = try_netrw,
		}
		local picker_fn = pickers[preferred]
		if picker_fn and picker_fn(cwd) then
			return true, preferred
		end
	end

	-- Auto-detect available pickers in order of preference
	local pickers_order = {
		{ name = "telescope", fn = try_telescope_files },
		{ name = "oil", fn = try_oil },
		{ name = "neo-tree", fn = try_neo_tree },
		{ name = "nvim-tree", fn = try_nvim_tree },
		{ name = "snacks", fn = try_snacks_files },
		{ name = "fzf-lua", fn = try_fzf_lua_files },
		{ name = "mini", fn = try_mini_files },
		{ name = "yazi", fn = try_yazi },
		{ name = "lf", fn = try_lf },
		{ name = "nnn", fn = try_nnn },
		{ name = "ranger", fn = try_ranger },
	}

	for _, picker in ipairs(pickers_order) do
		if picker.fn(cwd) then
			return true, picker.name
		end
	end

	-- Fallback to netrw if enabled
	if fallback_to_netrw and try_netrw(cwd) then
		return true, "netrw"
	end

	return false, "No file picker available"
end

-- Search picker detection and auto-launch functions
local function try_telescope_live_grep(cwd, pattern)
	local ok, telescope = pcall(require, "telescope.builtin")
	if ok and telescope.live_grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.default_text = pattern
		end
		telescope.live_grep(opts)
		return true
	end
	return false
end

local function try_snacks_grep(cwd, pattern)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.search = pattern
		end
		snacks.picker.grep(opts)
		return true
	end
	return false
end

local function try_fzf_lua_live_grep(cwd, pattern)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.live_grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.query = pattern
		end
		fzf.live_grep(opts)
		return true
	end
	return false
end

local function try_mini_grep(cwd, pattern)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.grep_live then
		local opts = {}
		if pattern and pattern ~= "" then
			opts.default_text = pattern
		end
		mini_pick.builtin.grep_live({ source = { cwd = cwd } }, opts)
		return true
	end
	return false
end

local function try_builtin_grep(cwd, pattern)
	local ok = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(cwd))
		if pattern and pattern ~= "" then
			vim.fn.setreg("/", pattern)
			vim.cmd("grep -r " .. vim.fn.shellescape(pattern) .. " .")
		else
			-- Open empty quickfix window for manual search
			vim.cmd("copen")
			vim.notify("Ready to search in " .. cwd .. ". Use :grep <pattern> to search.", vim.log.levels.INFO)
		end
	end)
	return ok
end

-- Main function to try opening search picker
function M.try_open_search_picker(cwd, pattern, config, is_manual)
	local file_picker_config = config.file_picker or {}
	local auto_open = file_picker_config.auto_open_on_mount ~= false -- default true
	local preferred = file_picker_config.preferred_picker or "auto"

	-- Only check auto_open setting for automatic calls (not manual user commands)
	if not is_manual and not auto_open then
		return false, "Auto-open disabled"
	end

	-- Try preferred picker first if specified
	if preferred ~= "auto" then
		local pickers = {
			telescope = function()
				return try_telescope_live_grep(cwd, pattern)
			end,
			snacks = function()
				return try_snacks_grep(cwd, pattern)
			end,
			["fzf-lua"] = function()
				return try_fzf_lua_live_grep(cwd, pattern)
			end,
			mini = function()
				return try_mini_grep(cwd, pattern)
			end,
			builtin = function()
				return try_builtin_grep(cwd, pattern)
			end,
		}
		local picker_fn = pickers[preferred]
		if picker_fn and picker_fn() then
			return true, preferred
		end
	end

	-- Auto-detect available search pickers in order of preference
	local search_pickers = {
		{
			name = "telescope",
			fn = function()
				return try_telescope_live_grep(cwd, pattern)
			end,
		},
		{
			name = "snacks",
			fn = function()
				return try_snacks_grep(cwd, pattern)
			end,
		},
		{
			name = "fzf-lua",
			fn = function()
				return try_fzf_lua_live_grep(cwd, pattern)
			end,
		},
		{
			name = "mini",
			fn = function()
				return try_mini_grep(cwd, pattern)
			end,
		},
		{
			name = "builtin",
			fn = function()
				return try_builtin_grep(cwd, pattern)
			end,
		},
	}

	for _, picker in ipairs(search_pickers) do
		if picker.fn() then
			return true, picker.name
		end
	end

	return false, "No search picker available"
end

-- Host selection picker using vim.ui.select
function M.pick_host(callback)
	local connections = require("sshfs.core.connections")
	local hosts = connections.get_hosts()

	if not hosts or vim.tbl_count(hosts) == 0 then
		vim.notify("No SSH hosts found in configuration", vim.log.levels.WARN)
		return
	end

	local host_list = {}
	local host_map = {}

	for name, host in pairs(hosts) do
		local display = name -- Just use the alias/hostname

		table.insert(host_list, display)
		host_map[display] = host
	end

	vim.ui.select(host_list, {
		prompt = "Select SSH host to connect:",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice and host_map[choice] then
			callback(host_map[choice])
		end
	end)
end

-- SSH config file picker using vim.ui.select
function M.pick_ssh_config(callback)
	local ssh_configs = ssh_config.get_default_ssh_configs()

	-- Filter to only existing files
	local available_configs = {}
	for _, config in ipairs(ssh_configs) do
		if vim.fn.filereadable(config) == 1 then
			table.insert(available_configs, config)
		end
	end

	if #available_configs == 0 then
		vim.notify("No readable SSH config files found", vim.log.levels.WARN)
		return
	end

	vim.ui.select(available_configs, {
		prompt = "Select SSH config to edit:",
		format_item = function(item)
			return vim.fn.fnamemodify(item, ":~")
		end,
	}, function(choice)
		if choice then
			callback(choice)
		end
	end)
end

-- Browse remote files using auto-detected file picker
function M.browse_remote_files(opts)
	opts = opts or {}
	local connections = require("sshfs.core.connections")

	if not connections.is_connected() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	local connection = connections.get_current_connection()
	local host = connection.host
	local mount_point = connection.mount_point

	if not host or not mount_point then
		vim.notify("Invalid connection state", vim.log.levels.ERROR)
		return
	end

	local target_dir = opts.dir or mount_point

	-- Check if directory exists and is accessible
	local stat = vim.uv.fs_stat(target_dir)
	if not stat or stat.type ~= "directory" then
		vim.notify("Mount point not accessible: " .. target_dir, vim.log.levels.ERROR)
		return
	end

	-- Get UI configuration from init
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config.ui or {}
	end

	-- Try to open file picker (manual user command)
	local success, picker_name = M.try_open_file_picker(target_dir, config, true)

	if not success then
		vim.notify("Failed to open " .. picker_name .. ". Please open manually.", vim.log.levels.WARN)
	end
end

-- Search remote files using auto-detected search picker
function M.grep_remote_files(pattern, opts)
	opts = opts or {}
	local connections = require("sshfs.core.connections")

	if not connections.is_connected() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	-- Allow empty pattern to open search interface without initial query

	local connection = connections.get_current_connection()
	local host = connection.host
	local mount_point = connection.mount_point

	if not host or not mount_point then
		vim.notify("Invalid connection state", vim.log.levels.ERROR)
		return
	end

	local search_dir = opts.dir or mount_point
	local stat = vim.uv.fs_stat(search_dir)
	if not stat or stat.type ~= "directory" then
		vim.notify("Search directory not accessible: " .. search_dir, vim.log.levels.ERROR)
		return
	end

	-- Get UI configuration from init
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config.ui or {}
	end

	-- Try to open search picker (manual user command)
	local success, picker_name = M.try_open_search_picker(search_dir, pattern, config, true)

	if success then
		if pattern and pattern ~= "" then
			vim.notify(
				"Opened " .. picker_name .. " search for pattern '" .. pattern .. "' in: " .. search_dir,
				vim.log.levels.INFO
			)
		else
			vim.notify("Opened " .. picker_name .. " search interface in: " .. search_dir, vim.log.levels.INFO)
		end
	else
		-- Fallback to old behavior
		vim.cmd("cd " .. vim.fn.fnameescape(search_dir))
		if pattern and pattern ~= "" then
			vim.fn.setreg("/", pattern)
			vim.notify(
				"Changed to remote directory. Search pattern '" .. pattern .. "' set in search register.",
				vim.log.levels.INFO
			)
		else
			vim.notify("Changed to remote directory: " .. search_dir, vim.log.levels.INFO)
		end
		vim.notify(
			"Reason: " .. picker_name .. ". Please use :grep, :vimgrep, or your preferred search tool manually.",
			vim.log.levels.WARN
		)
	end
end

-- Mount selection picker using vim.ui.select
function M.pick_mount(callback)
	local ssh_mount = require("sshfs.core.mount")

	-- Get configuration to determine mount base directory
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config
	end

	local base_dir = config.mounts and config.mounts.base_dir
	if not base_dir then
		vim.notify("Mount base directory not configured", vim.log.levels.ERROR)
		return
	end

	local mounts = ssh_mount.list_active_mounts(base_dir)

	if not mounts or #mounts == 0 then
		vim.notify("No active SSH mounts found", vim.log.levels.WARN)
		return
	end

	local mount_list = {}
	local mount_map = {}

	for _, mount in ipairs(mounts) do
		local display = mount.alias .. " (" .. mount.path .. ")"
		table.insert(mount_list, display)
		mount_map[display] = mount
	end

	vim.ui.select(mount_list, {
		prompt = "Select mount to navigate to:",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice and mount_map[choice] then
			callback(mount_map[choice])
		end
	end)
end

-- Mount selection picker for unmounting using vim.ui.select
function M.pick_mount_to_unmount(callback)
	local ssh_mount = require("sshfs.core.mount")

	-- Get configuration to determine mount base directory
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config
	end

	local base_dir = config.mounts and config.mounts.base_dir
	if not base_dir then
		vim.notify("Mount base directory not configured", vim.log.levels.ERROR)
		return
	end

	local mounts = ssh_mount.list_active_mounts(base_dir)

	if not mounts or #mounts == 0 then
		vim.notify("No active SSH mounts to disconnect", vim.log.levels.WARN)
		return
	end

	local mount_list = {}
	local mount_map = {}

	for _, mount in ipairs(mounts) do
		local display = mount.alias .. " (" .. mount.path .. ")"
		table.insert(mount_list, display)
		-- Create connection object compatible with disconnect_specific
		mount_map[display] = {
			host = { Name = mount.alias },
			mount_point = mount.path,
		}
	end

	vim.ui.select(mount_list, {
		prompt = "Select mount to disconnect:",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice and mount_map[choice] then
			callback(mount_map[choice])
		end
	end)
end

return M
