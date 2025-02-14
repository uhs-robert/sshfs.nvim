-- keymaps.lua
local M = {}
local util = require("ssh.util")

function M.setup()
	-- Mount Server from List
	vim.keymap.set("n", "<leader>ms", function()
		local server = util.select_server()
		if server then
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			util.mount_server(server, mount_point)
		end
	end, { desc = "Select and Mount SSH Server" })

	-- Refresh Servers
	vim.keymap.set("n", "<leader>mr", util.refresh_servers(true), { desc = "Refresh SSH Servers" })

	-- Open Mount Directory or Auto-Mount if Empty
	vim.keymap.set("n", "<leader>me", function()
		if util.last_mount_point and vim.fn.isdirectory(util.last_mount_point) == 1 then
			vim.notify("Opening last mount point: " .. util.last_mount_point, vim.log.levels.INFO)
			util.open_explorer(util.last_mount_point)
		else
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			util.check_and_mount(mount_point)
		end
	end, { desc = "Explore Last or Mount Remote Server" })
end

return M
