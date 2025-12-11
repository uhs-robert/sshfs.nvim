-- lua/sshfs/ui/picker.lua
-- Smart file picker and search picker auto-detection with fallbacks

local Picker = {}
local Config = require("sshfs.config")

-- Integration modules
local Telescope = require("sshfs.integrations.telescope")
local Oil = require("sshfs.integrations.oil")
local NeoTree = require("sshfs.integrations.neo_tree")
local NvimTree = require("sshfs.integrations.nvim_tree")
local Snacks = require("sshfs.integrations.snacks")
local FzfLua = require("sshfs.integrations.fzf_lua")
local Mini = require("sshfs.integrations.mini")
local Yazi = require("sshfs.integrations.yazi")
local Lf = require("sshfs.integrations.lf")
local Nnn = require("sshfs.integrations.nnn")
local Ranger = require("sshfs.integrations.ranger")
local Netrw = require("sshfs.integrations.netrw")
local Builtin = require("sshfs.integrations.builtin")

--- Attempts to open a file picker based on configuration and availability
--- Auto-detects available file pickers (telescope, oil, snacks, etc.) and falls back to netrw
---@param cwd string Current working directory to open picker in
---@param config table Plugin configuration table
---@param is_manual boolean True if called manually by user command, false if automatic
---@return boolean success True if a picker was successfully opened
---@return string picker_name Name of the picker that was opened, or error message
function Picker.try_open_file_picker(cwd, config, is_manual)
	local file_picker_config = config.ui and config.ui.file_picker or {}
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
			telescope = Telescope.try_files,
			snacks = Snacks.try_files,
			oil = Oil.try_files,
			["neo-tree"] = NeoTree.try_files,
			["nvim-tree"] = NvimTree.try_files,
			["fzf-lua"] = FzfLua.try_files,
			mini = Mini.try_files,
			yazi = Yazi.try_files,
			lf = Lf.try_files,
			nnn = Nnn.try_files,
			ranger = Ranger.try_files,
			netrw = Netrw.try_files,
		}
		local picker_fn = pickers[preferred]
		if picker_fn and picker_fn(cwd) then
			return true, preferred
		end
	end

	-- Auto-detect available pickers in order of preference
	local pickers_order = {
		{ name = "telescope", fn = Telescope.try_files },
		{ name = "oil", fn = Oil.try_files },
		{ name = "neo-tree", fn = NeoTree.try_files },
		{ name = "nvim-tree", fn = NvimTree.try_files },
		{ name = "snacks", fn = Snacks.try_files },
		{ name = "fzf-lua", fn = FzfLua.try_files },
		{ name = "mini", fn = Mini.try_files },
		{ name = "yazi", fn = Yazi.try_files },
		{ name = "lf", fn = Lf.try_files },
		{ name = "nnn", fn = Nnn.try_files },
		{ name = "ranger", fn = Ranger.try_files },
	}

	for _, picker in ipairs(pickers_order) do
		if picker.fn(cwd) then
			return true, picker.name
		end
	end

	-- Fallback to netrw if enabled
	if fallback_to_netrw and Netrw.try_files(cwd) then
		return true, "netrw"
	end

	return false, "No file picker available"
end

--- Attempts to open a search picker based on configuration and availability
--- Auto-detects available search pickers (telescope, snacks, fzf-lua, etc.) and falls back to built-in grep
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@param config table Plugin configuration table
---@param is_manual boolean True if called manually by user command, false if automatic
---@return boolean success True if a search picker was successfully opened
---@return string picker_name Name of the picker that was opened, or error message
function Picker.try_open_search_picker(cwd, pattern, config, is_manual)
	local file_picker_config = config.ui and config.ui.file_picker or {}
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
				return Telescope.try_grep(cwd, pattern)
			end,
			snacks = function()
				return Snacks.try_grep(cwd, pattern)
			end,
			["fzf-lua"] = function()
				return FzfLua.try_grep(cwd, pattern)
			end,
			mini = function()
				return Mini.try_grep(cwd, pattern)
			end,
			builtin = function()
				return Builtin.try_grep(cwd, pattern)
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
				return Telescope.try_grep(cwd, pattern)
			end,
		},
		{
			name = "snacks",
			fn = function()
				return Snacks.try_grep(cwd, pattern)
			end,
		},
		{
			name = "fzf-lua",
			fn = function()
				return FzfLua.try_grep(cwd, pattern)
			end,
		},
		{
			name = "mini",
			fn = function()
				return Mini.try_grep(cwd, pattern)
			end,
		},
		{
			name = "builtin",
			fn = function()
				return Builtin.try_grep(cwd, pattern)
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

--- Common setup and validation for remote operations
--- Validates connection state and directory accessibility
--- TODO: rename this function to better reflect its purpose
---@param opts? table Optional options table with 'dir' field
---@return table|nil config Plugin configuration, or nil on error
---@return table|nil active_connection Active connection table, or nil on error
---@return string|nil target_dir Target directory path, or nil on error
---@private
local function setup_remote_operation(opts)
	opts = opts or {}
	local Connections = require("sshfs.lib.connections")
	local base_dir = Config.get_base_dir()

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

	-- Get UI configuration
	local config = Config.get()

	return config, active_connection, target_dir
end

--- Opens file picker to browse files on the active remote connection
--- Auto-detects and launches preferred file picker (telescope, oil, snacks, etc.)
---@param opts? table Optional options table with 'dir' field to specify directory
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

--- Opens search picker to grep files on the active remote connection
--- Auto-detects and launches preferred search tool (telescope, snacks, fzf-lua, etc.)
---@param pattern? string Optional search pattern to pre-populate in the search interface
---@param opts? table Optional options table with 'dir' field to specify directory
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
