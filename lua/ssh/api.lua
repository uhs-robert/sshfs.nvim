local connections = require("ssh.connections")
local telescope_ssh = require("telescope").extensions["ssh"]

local M = {}

-- Allow connection to be called via api
M.mount = function(opts)
	telescope_ssh.connect(opts)
end

-- Allow disconnection to be called via api
M.unmount = function()
	connections.unmount_host()
end

-- Allow config edit to be called via api
M.edit = function(opts)
	telescope_ssh.edit(opts)
end

-- Allow configuration reload to be called via api
M.reload = function()
	connections.reload()
end

-- Trigger remote find_files
M.find_files = function(opts)
	telescope_ssh.find_files(opts)
end

-- Trigger remote live_grep
M.live_grep = function(opts)
	telescope_ssh.live_grep(opts)
end

-- Trigger open in explorer
M.open_directory = function(opts)
	telescope_ssh.open_directory(opts)
end

return M
