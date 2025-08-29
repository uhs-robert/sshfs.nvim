local M = {}

function M.parse_hosts_from_configs(ssh_configs)
	local hosts = {}
	local current_hosts = {}

	for _, path in ipairs(ssh_configs) do
		local current_config = vim.fn.expand(path)
		if vim.fn.filereadable(current_config) == 1 then
			for line in io.lines(current_config) do
				if line:sub(1, 1) ~= "#" and line:match("%S") then
					local host_names = line:match("^%s*Host%s+(.+)$")
					if host_names then
						current_hosts = {}
						for host_name in host_names:gmatch("%S+") do
							if host_name ~= "*" then
								table.insert(current_hosts, host_name)
								hosts[host_name] = { ["Config"] = path, ["Name"] = host_name }
							end
						end
					elseif line:match("^%s*Match%s+") then
						-- Match directive ends the current host block
						current_hosts = {}
					else
						if #current_hosts > 0 then
							local key, value = line:match("^%s*(%S+)%s+(.+)$")
							if key and value then
								for _, host in ipairs(current_hosts) do
									hosts[host][key] = value
								end
							end
						end
					end
				end
			end
		end
	end
	return hosts
end

function M.parse_host_from_command(command)
	local host = {}

	local port = command:match("%-p (%d+)")
	host["Port"] = port

	command = command:gsub("%s*%-p %d+%s*", "")

	local user, hostname, path = command:match("^([^@]+)@([^:]+):?(.*)$")
	if not user then
		hostname, path = command:match("^([^:]+):?(.*)$")
	end

	host["Name"] = hostname
	host["User"] = user
	host["Path"] = path

	return host
end

function M.get_default_ssh_configs()
	return {
		vim.fn.expand("$HOME") .. "/.ssh/config",
		"/etc/ssh/ssh_config",
	}
end

return M

