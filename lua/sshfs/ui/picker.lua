-- lua/sshfs/ui/picker.lua
-- File picker and search picker auto-detection with fallbacks

local Picker = {}
local Config = require("sshfs.config")

-- Integration registry, modules are lazy-loaded on first use
local FILE_PICKERS = {
	-- Notes about speed as well, nothing we can do about another plugin's design though.
	{ name = "snacks", module = "sshfs.integrations.snacks", method = "explore_files" }, -- FAST
	{ name = "yazi", module = "sshfs.integrations.yazi", method = "explore_files" }, -- FAST
	{ name = "telescope", module = "sshfs.integrations.telescope", method = "explore_files" }, -- FAST
	{ name = "oil", module = "sshfs.integrations.oil", method = "explore_files" }, -- FAST
	{ name = "lf", module = "sshfs.integrations.lf", method = "explore_files" }, -- FAST
	{ name = "ranger", module = "sshfs.integrations.ranger", method = "explore_files" }, -- FAST
	{ name = "nnn", module = "sshfs.integrations.nnn", method = "explore_files" }, -- FAST
	{ name = "neo-tree", module = "sshfs.integrations.neo_tree", method = "explore_files" }, -- MEDIUM
	{ name = "mini", module = "sshfs.integrations.mini", method = "explore_files" }, -- SLOW
	{ name = "nvim-tree", module = "sshfs.integrations.nvim_tree", method = "explore_files" }, -- SLOW
	{ name = "fzf-lua", module = "sshfs.integrations.fzf_lua", method = "explore_files" }, -- SLOW
	{ name = "netrw", module = "sshfs.integrations.netrw", method = "explore_files" }, -- FAST
}

local SEARCH_PICKERS = {
	{ name = "snacks", module = "sshfs.integrations.snacks", method = "grep" },
	{ name = "telescope", module = "sshfs.integrations.telescope", method = "grep" },
	{ name = "mini", module = "sshfs.integrations.mini", method = "grep" },
	{ name = "fzf-lua", module = "sshfs.integrations.fzf_lua", method = "grep" },
	{ name = "builtin", module = "sshfs.integrations.builtin", method = "grep" },
}

-- Cache for loaded integration modules
local INTEGRATION_CACHE = {}

--- Lazy-load and cache an integration module
---@param module_path string Module path to require
---@return table integration The loaded integration module
---@private
local function get_integration(module_path)
	if not INTEGRATION_CACHE[module_path] then
		INTEGRATION_CACHE[module_path] = require(module_path)
	end
	return INTEGRATION_CACHE[module_path]
end

--- Generic function to try opening a picker from a registry
---@param picker_registry table List of picker definitions with name, module, and method
---@param preferred string|nil Preferred picker name, or "auto" for auto-detection
---@param args table Arguments to pass to the picker method
---@return boolean success True if a picker was successfully opened
---@return string picker_name Name of the picker that was opened, or error message
---@private
local function try_picker(picker_registry, preferred, args)
	-- Try preferred picker first if specified
	if preferred and preferred ~= "auto" then
		for _, picker in ipairs(picker_registry) do
			if picker.name == preferred then
				local integration = get_integration(picker.module)
				if integration[picker.method](unpack(args)) then
					return true, picker.name
				end
				break
			end
		end
	end

	-- Auto-detect available pickers in order of preference
	for _, picker in ipairs(picker_registry) do
		local integration = get_integration(picker.module)
		if integration[picker.method](unpack(args)) then
			return true, picker.name
		end
	end

	return false, "No picker available"
end

--- Attempts to open a file picker based on configuration and availability
--- Auto-detects available file pickers (telescope, oil, snacks, etc.) and falls back to netrw
---@param cwd string Current working directory to open picker in
---@param config table Plugin configuration table
---@param is_manual boolean True if called manually by user command, false if automatic
---@return boolean success True if a picker was successfully opened
---@return string picker_name Name of the picker that was opened, or error message
function Picker.open_file_picker(cwd, config, is_manual)
	local file_picker_config = config.ui and config.ui.file_picker or {}
	local auto_open = file_picker_config.auto_open_on_mount ~= false -- default true
	local preferred = file_picker_config.preferred_picker or "auto"
	local fallback_to_netrw = file_picker_config.fallback_to_netrw ~= false -- default true

	-- Only check auto_open setting for automatic calls (not manual user commands)
	if not is_manual and not auto_open then
		return false, "Auto-open disabled"
	end

	-- Determine which pickers to try
	local pickers_to_try = FILE_PICKERS
	if not fallback_to_netrw then
		pickers_to_try = vim.tbl_filter(function(p)
			return p.name ~= "netrw"
		end, FILE_PICKERS)
	end

	return try_picker(pickers_to_try, preferred, { cwd })
end

--- Attempts to open a search picker based on configuration and availability
--- Auto-detects available search pickers (telescope, snacks, fzf-lua, etc.) and falls back to built-in grep
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@param config table Plugin configuration table
---@param is_manual boolean True if called manually by user command, false if automatic
---@return boolean success True if a search picker was successfully opened
---@return string picker_name Name of the picker that was opened, or error message
function Picker.open_search_picker(cwd, pattern, config, is_manual)
	local file_picker_config = config.ui and config.ui.file_picker or {}
	local auto_open = file_picker_config.auto_open_on_mount ~= false -- default true
	local preferred = file_picker_config.preferred_picker or "auto"

	-- Only check auto_open setting for automatic calls (not manual user commands)
	if not is_manual and not auto_open then
		return false, "Auto-open disabled"
	end

	return try_picker(SEARCH_PICKERS, preferred, { cwd, pattern })
end

--- Validates remote connection and returns necessary context
---@param opts? table Optional options table with 'dir' field
---@return table|nil config Plugin configuration, or nil on error
---@return table|nil active_connection Active connection table, or nil on error
---@return string|nil target_dir Target directory path, or nil on error
---@private
local function validate_remote_connection(opts)
	opts = opts or {}
	local Connections = require("sshfs.lib.connections")

	if not Connections.has_active() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return nil
	end

	-- Get active connection
	local active_connection = Connections.get_active()
	local target_dir = opts.dir or (active_connection and active_connection.mount_path)
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

	return Config.get(), active_connection, target_dir
end

--- Opens file picker to browse files on the active remote connection
--- Auto-detects and launches preferred file picker (telescope, oil, snacks, etc.)
---@param opts? table Optional options table with 'dir' field to specify directory
function Picker.browse_remote_files(opts)
	local AutoCommands = require("sshfs.ui.autocommands")
	local config, active_connection, target_dir = validate_remote_connection(opts)

	if not config or not active_connection or not target_dir then
		return
	end

	-- Try to open file picker (manual user command)
	AutoCommands.chdir_on_next_open(active_connection.mount_path)
	local success, picker_name = Picker.open_file_picker(target_dir, config, true)
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
	local config, active_connection, target_dir = validate_remote_connection(opts)

	if not config or not active_connection or not target_dir then
		return
	end

	-- Try to open search picker (manual user command)
	AutoCommands.chdir_on_next_open(active_connection.mount_path)
	local success, picker_name = Picker.open_search_picker(target_dir, pattern, config, true)
	if success then
		return
	end

	-- Fallback behaviour
	vim.cmd("tcd " .. vim.fn.fnameescape(target_dir))
	if pattern and pattern ~= "" then
		vim.fn.setreg("/", pattern)
	end
	vim.notify(
		"Grep failed for: " .. picker_name .. ". Please use :grep, :vimgrep, or your preferred search tool manually.",
		vim.log.levels.WARN
	)
end

return Picker
