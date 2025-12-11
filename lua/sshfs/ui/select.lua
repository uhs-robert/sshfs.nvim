-- lua/sshfs/ui/select.lua
-- User option selections: ssh_config, mount, unmount

local Select = {}

--- Get active mounts or display warning.
---@return table|nil Active mounts array or nil if none found
local function get_active_mounts_or_warn()
	local MountPoint = require("sshfs.lib.mount_point")
	local active_mounts = MountPoint.list_active()
	if not active_mounts or #active_mounts == 0 then
		vim.notify("No active SSH mounts found", vim.log.levels.WARN)
		return nil
	end
	return active_mounts
end

--- SSH config file picker using vim.ui.select.
---@param callback function Callback invoked with selected config file path
function Select.ssh_config(callback)
	local SSHConfig = require("sshfs.lib.ssh_config")
	local config_files = SSHConfig.get_default_files()

	-- Filter to only existing files
	local available_configs = {}
	for _, config in ipairs(config_files) do
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

--- Mount selection from active mounts.
---@param callback function Callback invoked with selected mount object
function Select.mount(callback)
	local active_mounts = get_active_mounts_or_warn()
	if not active_mounts then
		return
	end

	local mount_list = {}
	local mount_map = {}

	for _, mount in ipairs(active_mounts) do
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

--- Mount selection for unmounting an active mount.
---@param callback function Callback invoked with selected connection object
function Select.unmount(callback)
	local active_mounts = get_active_mounts_or_warn()
	if not active_mounts then
		return
	end

	local mount_list = {}
	local mount_map = {}

	for _, mount in ipairs(active_mounts) do
		local display = mount.alias .. " (" .. mount.path .. ")"
		table.insert(mount_list, display)
		-- Create connection object compatible with disconnect_from
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

--- Host selection for choosing an SSH Host to connect to.
---@param callback function Callback invoked with selected host object
function Select.host(callback)
	local SSHConfig = require("sshfs.lib.ssh_config")
	local hosts = SSHConfig.get_hosts()

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
	table.sort(host_list)

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

return Select
