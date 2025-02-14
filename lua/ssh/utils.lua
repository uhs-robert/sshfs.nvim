local M = {}
local ssh_servers = {}
M.last_mount_point = nil

--- Check if a directory is empty
---@param path string
---@return boolean
function M.is_directory_empty(path)
	return vim.fn.glob(path .. "/*") == ""
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

--- Mount a server using SSHFS
---@param server string
---@param mount_point string
function M.mount_server(server, mount_point)
	local result = vim.fn.system("sshfs " .. server .. ":/ " .. mount_point)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to mount: " .. result, vim.log.levels.ERROR)
	else
		vim.notify("Mounted " .. server .. " at " .. mount_point, vim.log.levels.INFO)
	end
	M.last_mount_point = mount_point
end

--- Explore a directory using Snacks Explorer
---@param path string
function M.open_explorer(path)
	vim.cmd("cd " .. path)
	require("snacks").explorer.open()
end

--- Check directory and mount if empty, otherwise explore
---@param mount_point string
function M.check_and_mount(mount_point)
	if M.is_directory_empty(mount_point) then
		vim.notify(mount_point .. " is empty. Attempting to mount server...", vim.log.levels.WARN)
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

return M
