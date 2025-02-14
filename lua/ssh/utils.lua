local M = {}
local ssh_servers = {}
M.mounted_servers = {}

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
function M.refresh_servers(notify)
	ssh_servers = M.parse_ssh_config()
	if notify then
		vim.notify("SSH servers refreshed", vim.log.levels.INFO)
	end
end

--- Prompt user to select from cached SSH servers
---@return string|nil
function M.select_server()
	if #ssh_servers == 0 then
		vim.notify("No SSH servers found. Refresh with <leader>mr", vim.log.levels.ERROR)
		return nil
	end

	local choices = {}
	for i, server in ipairs(ssh_servers) do
		table.insert(choices, i .. ". " .. server)
	end

	local choice = vim.fn.inputlist(choices)
	return ssh_servers[choice]
end

--- Check if a directory is empty
---@param path string
---@return boolean
function M.is_directory_empty(path)
	return vim.fn.glob(path .. "/*") == ""
end

--- Mount a server using SSHFS
---@param server string
---@param mount_point string
function M.mount_server(server, mount_point)
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
		local choices = {}
		for i, path in ipairs(M.mounted_servers) do
			table.insert(choices, i .. ". " .. path)
		end

		local choice = vim.fn.inputlist(choices)
		local selected_path = M.mounted_servers[choice]

		if selected_path then
			M.unmount_server(selected_path)
		else
			vim.notify("Unmount cancelled", vim.log.levels.WARN)
		end
	end
end

--- Check directory and mount if empty, otherwise explore
function M.user_pick_mount()
	local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
	-- Ensure directory exists
	if vim.fn.isdirectory(mount_point) == 0 then
		vim.fn.mkdir(mount_point, "p")
	end
	-- Handle mount or open explorer
	if M.is_directory_empty(mount_point) then
		vim.notify(mount_point .. ", Attempting to mount server...", vim.log.levels.WARN)
		local server = M.select_server()
		if server then
			M.mount_server(server, mount_point)
			M.open_explorer(mount_point)
		else
			vim.notify("Server selection cancelled", vim.log.levels.WARN)
		end
	else
		M.open_explorer(mount_point)
	end
end

--- Explore a directory using Snacks Explorer
--- If a path is provided, open it directly; otherwise, prompt the user to select from mounted servers.
---@param path string|nil Optional directory path
function M.open_explorer(path)
	-- Open path in the explorer
	local function open_path(selected_path)
		if path and vim.fn.isdirectory(path) == 1 then
			vim.cmd("cd " .. selected_path)
			require("snacks").explorer.open()
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

	-- Prompt user for selection if multiple servers
	local choices = {}
	for i, mount_point in ipairs(M.mounted_servers) do
		table.insert(choices, i .. ". " .. mount_point)
	end
	local choice = vim.fn.inputlist(choices)

	local selected = M.mounted_servers[choice]
	if selected then
		open_path(selected)
	else
		vim.notify("Selection cancelled.", vim.log.levels.WARN)
	end
end

return M
