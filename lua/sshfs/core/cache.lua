local M = {}

local host_cache = {
	hosts = nil,
	ssh_config_mtime = 0,
	save_file_mtime = 0,
}

local function get_file_mtime(path)
	local stat = vim.uv.fs_stat(path)
	return stat and stat.mtime.sec or 0
end

function M.is_cache_valid(ssh_configs, save_file_path)
	if not host_cache.hosts then
		return false
	end

	local ssh_config_mtime = 0
	for _, config in ipairs(ssh_configs) do
		local mtime = get_file_mtime(vim.fn.expand(config))
		if mtime > ssh_config_mtime then
			ssh_config_mtime = mtime
		end
	end

	local save_file_mtime = save_file_path and get_file_mtime(save_file_path) or 0

	return (host_cache.ssh_config_mtime == ssh_config_mtime and host_cache.save_file_mtime == save_file_mtime)
end

function M.update_cache(hosts, ssh_configs, save_file_path)
	local ssh_config_mtime = 0
	for _, config in ipairs(ssh_configs) do
		local mtime = get_file_mtime(vim.fn.expand(config))
		if mtime > ssh_config_mtime then
			ssh_config_mtime = mtime
		end
	end

	local save_file_mtime = save_file_path and get_file_mtime(save_file_path) or 0

	host_cache.hosts = hosts
	host_cache.ssh_config_mtime = ssh_config_mtime
	host_cache.save_file_mtime = save_file_mtime
end

function M.get_cached_hosts()
	return host_cache.hosts
end

function M.invalidate_cache()
	host_cache.hosts = nil
	host_cache.ssh_config_mtime = 0
	host_cache.save_file_mtime = 0
end

function M.read_custom_hosts(file_path)
	if not file_path or vim.fn.filereadable(file_path) ~= 1 then
		return {}
	end

	local hosts = {}
	for line in io.lines(file_path) do
		line = line:match("^%s*(.-)%s*$")
		if line and line ~= "" and not line:match("^#") then
			table.insert(hosts, line)
		end
	end
	return hosts
end

function M.write_custom_hosts(file_path, hosts)
	local file = io.open(file_path, "w")
	if not file then
		return false
	end

	for _, host in ipairs(hosts) do
		file:write(host .. "\n")
	end
	file:close()
	return true
end

function M.add_custom_host(file_path, host)
	local file = io.open(file_path, "a")
	if not file then
		return false
	end

	file:write(host .. "\n")
	file:close()

	if host_cache.hosts then
		local found = false
		for _, existing_host in ipairs(host_cache.hosts) do
			if existing_host == host then
				found = true
				break
			end
		end
		if not found then
			table.insert(host_cache.hosts, host)
		end
		host_cache.save_file_mtime = get_file_mtime(file_path)
	end

	return true
end

function M.remove_custom_host(file_path, host_to_remove)
	local hosts = M.read_custom_hosts(file_path)
	local updated_hosts = {}

	for _, host in ipairs(hosts) do
		if host ~= host_to_remove then
			table.insert(updated_hosts, host)
		end
	end

	local success = M.write_custom_hosts(file_path, updated_hosts)

	if success and host_cache.hosts then
		local new_hosts = {}
		for _, host in ipairs(host_cache.hosts) do
			if host ~= host_to_remove then
				table.insert(new_hosts, host)
			end
		end
		host_cache.hosts = new_hosts
		host_cache.save_file_mtime = get_file_mtime(file_path)
	end

	return success
end

return M

