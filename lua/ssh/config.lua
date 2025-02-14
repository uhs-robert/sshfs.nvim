-- lua/ssh/config.lua
local M = {}

--Default options, can be overridden by user
M.opts = {
	mount_directory = vim.fn.expand("~/.local/share/ssh_mounts"),
	ssh_config = { vim.fn.expand("~/.ssh/config") }, -- Allows multiple config file paths
}

--- Validate and normalize `ssh_config`
---@param opts table User options
local function normalize_options(opts)
	if type(opts.ssh_config) == "string" then
		opts.ssh_config = { opts.ssh_config }
	elseif type(opts.ssh_config) == "table" then
		for i, path in ipairs(opts.ssh_config) do
			opts.ssh_config[i] = vim.fn.expand(path)
		end
	else
		opts.ssh_config = M.opts.ssh_config
	end
end

--- Setup user configuration
---@param user_opts table User-defined options
function M.setup(user_opts)
	user_opts = user_opts or {}
	normalize_options(user_opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, user_opts)
	M.create_mount_directory()
end

--- Create mount directory if it does not exist
function M.create_mount_directory()
	if vim.fn.isdirectory(M.opts.mount_directory) == 0 then
		vim.fn.mkdir(M.opts.mount_directory, "p")
	end
end

return M
