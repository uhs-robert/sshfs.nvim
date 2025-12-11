-- lua/sshfs/ui/select.lua
-- User option selections: ssh_config, mount, unmount

local Select = {}

-- SSH config file picker using vim.ui.select
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

-- Mount selection from active mounts
function Select.mount(callback)
	local MountPoint = require("sshfs.lib.mount_point")

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

	local mounts = MountPoint.list_active(base_dir)

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

-- Mount selection for unmounting an active mount
function Select.unmount(callback)
	local MountPoint = require("sshfs.lib.mount_point")

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

	local mounts = MountPoint.list_active(base_dir)

	if not mounts or #mounts == 0 then
		vim.notify("No active SSH mounts to disconnect", vim.log.levels.WARN)
		return
	end

	local mount_list = {}
	local mount_map = {}

	for _, mount in ipairs(mounts) do
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

-- Host selection for choosing an SSH Host to connect to
function Select.host(callback)
	local session = require("sshfs.session")
	local hosts = session.get_hosts()

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

return Select
