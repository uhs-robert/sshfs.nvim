local M = {}
local config = require("ssh.config")
local options = config.opts
local ssh_servers = {}
M.mounted_servers = {}

--- Prompt user to select from choices using `vim.ui.select`
---@param choices string[] List of choices (plain strings)
---@param prompt string Prompt message to display
---@param icon string|nil Optional icon to display for all items
---@param callback function Function to call with the selected item
function M.select_from_list(choices, prompt, icon, callback)
	vim.ui.select(choices, {
		prompt = prompt or "Select an Option:",
		format_item = function(item)
			if icon then
				return icon .. " " .. item
			else
				return item
			end
		end,
	}, function(choice)
		if choice then
			callback(choice)
		else
			vim.notify("Selection cancelled.", vim.log.levels.WARN)
		end
	end)
end

--- Store a mounted server path
---@param path string
function M.add_mounted_server(path)
	if not vim.tbl_contains(M.mounted_servers, path) then
		table.insert(M.mounted_servers, path)
	end
end

--- Remove a mounted server path
---@param path string
function M.remove_mounted_server(path)
	for i, server in ipairs(M.mounted_servers) do
		if server == path then
			table.remove(M.mounted_servers, i)
			break
		end
	end
end

--- Parse ~/.ssh/config for Host entries
---@return string[]
function M.parse_ssh_config()
	local servers = {}
	local config_files = { "~/.ssh/config" }
	for _, file in ipairs(config_files) do
		local path = vim.fn.expand(file)
		if vim.fn.filereadable(path) == 1 then
			local lines = vim.fn.readfile(path)
			for _, line in ipairs(lines) do
				local host = line:match("^%s*Host%s+([%w%-%._]+)")
				if host and host ~= "*" then
					table.insert(servers, host)
				end
			end
		end
	end
	table.sort(servers)
	return servers
end

--- Refresh cached SSH servers
function M.get_ssh_config(notify)
	ssh_servers = M.parse_ssh_config()
	if notify then
		vim.notify("SSH servers refreshed", vim.log.levels.INFO)
	end
end

--- Check if a directory is empty
---@param path string
---@return boolean
function M.is_directory_empty(path)
	return vim.fn.glob(path .. "/*") == ""
end

--- Get mount path for a server
---@param server string|nil
---@return string
function M.get_mount_path(server)
	return options.mount_directory .. "/" .. server
end

--- Mount a server using SSHFS
---@param server string
function M.mount_server(server)
	local mount_point = M.get_mount_path(server)
	if vim.fn.isdirectory(mount_point) == 0 then
		vim.fn.mkdir(mount_point, "p")
	end

	local result = vim.fn.system("sshfs " .. server .. ":/ " .. mount_point)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to mount: " .. result, vim.log.levels.ERROR)
	else
		vim.notify("Mounted " .. server .. " at " .. mount_point, vim.log.levels.INFO)
		M.add_mounted_server(mount_point)
	end
end

--- Unmount a server using fusermount
---@param mount_point string
function M.unmount_server(mount_point)
	local result = vim.fn.system("fusermount -zu " .. mount_point)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to unmount: " .. result, vim.log.levels.ERROR)
	else
		vim.notify("Unmounted: " .. mount_point, vim.log.levels.INFO)
		M.remove_mounted_server(mount_point)
	end
end

--- Prompt user to select from cached SSH servers (async, callback)
---@param callback function Function to call with selected server
function M.select_server(callback)
	if #ssh_servers == 0 then
		vim.notify("No SSH servers found. Refresh with <leader>mr", vim.log.levels.ERROR)
		return
	end

	M.select_from_list(ssh_servers, "Select an SSH server:", "🌐", function(choice)
		if choice then
			callback(choice)
		else
			vim.notify("Server selection cancelled.", vim.log.levels.WARN)
			callback(nil)
		end
	end)
end

--- Allow user to pick which mounted server to unmount
function M.user_pick_unmount()
	if #M.mounted_servers == 0 then
		vim.notify("No mounted servers to unmount.", vim.log.levels.INFO)
		return
	end

	-- Handle single or multiple mount points
	if #M.mounted_servers == 1 then
		M.unmount_server(M.mounted_servers[1])
	else
		M.select_from_list(
			M.mounted_servers,
			"Select a server to unmount:",
			"📤", -- Use a global icon for all items
			function(selected)
				M.unmount_server(selected)
			end
		)
	end
end

--- Check directory and mount if empty, otherwise explore
function M.user_pick_mount()
	-- Select server using callback
	M.select_server(function(server)
		if not server then
			vim.notify("Server selection cancelled", vim.log.levels.WARN)
			return
		end

		local mount_point = M.get_mount_path(server)

		-- Ensure directory exists
		if vim.fn.isdirectory(mount_point) == 0 then
			vim.fn.mkdir(mount_point, "p")
		end

		-- Mount server or open in explorer if already mounted
		if M.is_directory_empty(mount_point) then
			M.mount_server(server)
			M.open_directory(mount_point)
		else
			vim.notify(mount_point .. ", Already mounted. Opening explorer...", vim.log.levels.WARN)
			M.open_directory(mount_point)
		end
	end)
end

--- Open a directory (If Snacks Explorer exists then view directory too)
--- If a path is provided, open it directly; otherwise, prompt the user to select from mounted servers.
---@param path string|nil Optional directory path
function M.open_directory(path)
	-- Change directory to path
	local function open_path(selected_path)
		if selected_path and vim.fn.isdirectory(selected_path) == 1 then
			vim.cmd("cd " .. vim.fn.fnameescape(selected_path))
			local has_snacks, snacks = pcall(require, "snacks")
			if has_snacks and snacks.explorer and snacks.explorer.open then
				snacks.explorer.open()
			end
		else
			vim.notify("Invalid path: " .. selected_path, vim.log.levels.ERROR)
		end
	end

	-- Handle direct path
	if path then
		open_path(path)
		return
	end

	-- Check mounted servers
	if not M.mounted_servers or #M.mounted_servers == 0 then
		vim.notify("No mounted servers available to explore.", vim.log.levels.INFO)
		return
	end

	-- Handle single server case
	if #M.mounted_servers == 1 then
		open_path(M.mounted_servers[1])
		return
	end

	-- Prompt user for selection if multiple servers are mounted
	M.select_from_list(M.mounted_servers, "Select a mounted server to open:", "📂", function(selected)
		if selected then
			open_path(selected)
		else
			vim.notify("Selection cancelled.", vim.log.levels.WARN)
		end
	end)
end

return M
