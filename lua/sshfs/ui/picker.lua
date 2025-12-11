-- lua/sshfs/ui/picker.lua
-- Smart file picker and search picker auto-detection (telescope, oil, snacks, etc.) with vim.ui.select and netrw fallbacks

local Picker = {}

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
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
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
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		vim.cmd("RnvimrToggle")
	end)
	return rnvimr_ok
end

local function try_netrw(cwd)
	local ok = pcall(function()
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
		vim.cmd("Explore")
	end)
	return ok
end

-- Main function to try opening file picker
function Picker.try_open_file_picker(cwd, config, is_manual)
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
		vim.cmd("tcd " .. vim.fn.fnameescape(cwd))
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
function Picker.try_open_search_picker(cwd, pattern, config, is_manual)
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

-- Common setup and validation for remote operations
-- Returns: config, active_connection, target_dir or nil on error
-- TODO: rename this function
local function setup_remote_operation(opts)
	opts = opts or {}
	local Session = require("sshfs.session")
	local Connections = require("sshfs.lib.connections")
	local base_dir = Session.get_base_dir()

	if not Connections.has_active(base_dir) then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return nil
	end

	-- Get active connection
	local active_connection = Connections.get_active(base_dir)
	local target_dir = opts.dir or (active_connection and active_connection.mount_point)
	if not target_dir then
		vim.notify("Invalid connection state", vim.log.levels.ERROR)
		return nil
	end

	-- Validate target directory
	local stat = vim.uv.fs_stat(target_dir)
	if not stat or stat.type ~= "directory" then
		vim.notify("Directory not accessible: " .. target_dir, vim.log.levels.ERROR)
		return nil
	end

	-- Get UI configuration from init
	local config = {}
	local config_ok, init_module = pcall(require, "sshfs")
	if config_ok and init_module._config then
		config = init_module._config.ui or {}
	end

	return config, active_connection, target_dir
end

-- Browse remote files using auto-detected file picker
function Picker.browse_remote_files(opts)
	local AutoCommands = require("sshfs.ui.autocommands")
	local config, active_connection, target_dir = setup_remote_operation(opts)

	if not config or not active_connection then
		return
	end

	-- Try to open file picker (manual user command)
	AutoCommands.chdir_on_next_open(active_connection.mount_point)
	local success, picker_name = Picker.try_open_file_picker(target_dir, config, true)

	if not success then
		vim.notify("Failed to open " .. picker_name .. ". Please open manually.", vim.log.levels.WARN)
	end
end

-- Search remote files using auto-detected search picker
function Picker.grep_remote_files(pattern, opts)
	local AutoCommands = require("sshfs.ui.autocommands")
	local config, active_connection, target_dir = setup_remote_operation(opts)

	if not config or not active_connection or not target_dir then
		return
	end

	-- Try to open search picker (manual user command)
	AutoCommands.chdir_on_next_open(active_connection.mount_point)
	local success, picker_name = Picker.try_open_search_picker(target_dir, pattern, config, true)

	if success then
		if pattern and pattern ~= "" then
			vim.notify(
				"Opened " .. picker_name .. " search for pattern '" .. pattern .. "' in: " .. target_dir,
				vim.log.levels.INFO
			)
		else
			vim.notify("Opened " .. picker_name .. " search interface in: " .. target_dir, vim.log.levels.INFO)
		end
	else
		-- Fallback to old behavior
		vim.cmd("tcd " .. vim.fn.fnameescape(target_dir))
		if pattern and pattern ~= "" then
			vim.fn.setreg("/", pattern)
			vim.notify(
				"Changed to remote directory. Search pattern '" .. pattern .. "' set in search register.",
				vim.log.levels.INFO
			)
		else
			vim.notify("Changed to remote directory: " .. target_dir, vim.log.levels.INFO)
		end
		vim.notify(
			"Reason: " .. picker_name .. ". Please use :grep, :vimgrep, or your preferred search tool manually.",
			vim.log.levels.WARN
		)
	end
end

return Picker
