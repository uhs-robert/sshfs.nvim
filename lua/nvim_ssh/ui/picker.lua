-- Native pickers using vim.ui.select - no external dependencies
local ssh_config = require("ssh.core.config")

local M = {}

-- Host selection picker using vim.ui.select
function M.pick_host(callback)
	local connections = require("ssh.core.connections")
	local hosts = connections.get_hosts()

	if not hosts or vim.tbl_count(hosts) == 0 then
		vim.notify("No SSH hosts found in configuration", vim.log.levels.WARN)
		return
	end

	local host_list = {}
	local host_map = {}

	for name, host in pairs(hosts) do
		local display = name
		if host.User then
			display = host.User .. "@" .. name
		end
		if host.Port then
			display = display .. ":" .. host.Port
		end

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

-- Browse remote files by changing to mount directory
function M.browse_remote_files(opts)
	opts = opts or {}
	local connections = require("ssh.core.connections")

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

	-- Change to the mount directory and let user use their preferred explorer
	local target_dir = opts.dir or mount_point

	-- Check if directory exists and is accessible
	local stat = vim.uv.fs_stat(target_dir)
	if not stat or stat.type ~= "directory" then
		vim.notify("Mount point not accessible: " .. target_dir, vim.log.levels.ERROR)
		return
	end

	-- Change working directory to mount point
	vim.cmd("cd " .. vim.fn.fnameescape(target_dir))
	vim.notify("Changed to remote directory: " .. target_dir, vim.log.levels.INFO)
	vim.notify("Use your preferred file explorer (telescope, snacks, oil, etc.) to browse files", vim.log.levels.INFO)
end

-- Search remote files with user's preferred method
function M.grep_remote_files(pattern, opts)
	opts = opts or {}
	local connections = require("ssh.core.connections")

	if not connections.is_connected() then
		vim.notify("Not connected to any remote host", vim.log.levels.WARN)
		return
	end

	if not pattern or pattern == "" then
		pattern = vim.fn.input("Search pattern: ")
		if not pattern or pattern == "" then
			return
		end
	end

	local connection = connections.get_current_connection()
	local host = connection.host
	local mount_point = connection.mount_point

	if not host or not mount_point then
		vim.notify("Invalid connection state", vim.log.levels.ERROR)
		return
	end

	-- Change to mount directory
	local search_dir = opts.dir or mount_point
	local stat = vim.uv.fs_stat(search_dir)
	if not stat or stat.type ~= "directory" then
		vim.notify("Search directory not accessible: " .. search_dir, vim.log.levels.ERROR)
		return
	end

	vim.cmd("cd " .. vim.fn.fnameescape(search_dir))

	-- Set up search pattern in vim register for easy access
	vim.fn.setreg("/", pattern)

	vim.notify(
		"Changed to remote directory. Search pattern '" .. pattern .. "' set in search register.",
		vim.log.levels.INFO
	)
	vim.notify("Use :grep, :vimgrep, telescope live_grep, or your preferred search tool", vim.log.levels.INFO)
end

return M
