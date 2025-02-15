local connections = require("ssh.connections")

local M = {}

-- Allow connection to be called via api
M.mount = function(opts)
	require("telescope").extensions["ssh"].connect(opts)
end

-- Allow disconnection to be called via api
M.unmount = function()
	connections.unmount_host()
end

-- Allow config edit to be called via api
M.edit = function(opts)
	require("telescope").extensions["ssh"].edit(opts)
end

-- Allow configuration reload to be called via api
M.reload = function()
	connections.reload()
end

-- Trigger remote find_files
M.find_files = function(opts)
	require("telescope").extensions["ssh"].find_files(opts)
end

-- Trigger remote live_grep
M.live_grep = function(opts)
	require("telescope").extensions["ssh"].live_grep(opts)
end

-- Trigger open in explorer
M.open_explorer = function(opts)
	require("telescope").extensions["ssh"].open_explorer(opts)
end

return M
