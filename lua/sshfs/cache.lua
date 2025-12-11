-- lua/sshfs/cache.lua
-- Host caching system with file modification time validation

local Cache = {}

local host_cache = {
	hosts = nil,
	ssh_config_mtime = 0,
	save_file_mtime = 0,
}

local function get_modified_time(path)
	local stat = vim.uv.fs_stat(path)
	return stat and stat.mtime.sec or 0
end

function Cache.is_valid(ssh_configs, save_file_path)
	if not host_cache.hosts then
		return false
	end

	local ssh_config_mtime = 0
	for _, config in ipairs(ssh_configs) do
		local mtime = get_modified_time(vim.fn.expand(config))
		if mtime > ssh_config_mtime then
			ssh_config_mtime = mtime
		end
	end

	local save_file_mtime = save_file_path and get_modified_time(save_file_path) or 0

	return (host_cache.ssh_config_mtime == ssh_config_mtime and host_cache.save_file_mtime == save_file_mtime)
end

function Cache.update(hosts, ssh_configs, save_file_path)
	local ssh_config_mtime = 0
	for _, config in ipairs(ssh_configs) do
		local mtime = get_modified_time(vim.fn.expand(config))
		if mtime > ssh_config_mtime then
			ssh_config_mtime = mtime
		end
	end

	local save_file_mtime = save_file_path and get_modified_time(save_file_path) or 0

	host_cache.hosts = hosts
	host_cache.ssh_config_mtime = ssh_config_mtime
	host_cache.save_file_mtime = save_file_mtime
end

function Cache.get_hosts()
	return host_cache.hosts
end

function Cache.reset()
	host_cache.hosts = nil
	host_cache.ssh_config_mtime = 0
	host_cache.save_file_mtime = 0
end

return Cache
