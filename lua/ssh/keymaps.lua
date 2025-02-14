-- keymaps.lua
local M = {}
local utils = require("ssh.utils")

function M.setup()
	-- Mount Server from List
	vim.keymap.set("n", "<leader>ms", function()
		local server = utils.select_server()
		if server then
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			utils.mount_server(server, mount_point)
		end
	end, { desc = "Select and Mount SSH Server" })

	-- Refresh Servers
	vim.keymap.set("n", "<leader>mr", function()
		utils.refresh_servers(true)
	end, { desc = "Refresh SSH Servers" })

	-- Open Mount Directory or Auto-Mount if Empty
	vim.keymap.set("n", "<leader>me", function()
		if utils.last_mount_point and vim.fn.isdirectory(utils.last_mount_point) == 1 then
			vim.notify("Opening last mount point: " .. utils.last_mount_point, vim.log.levels.INFO)
			utils.open_explorer(utils.last_mount_point)
		else
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			utils.check_and_mount(mount_point)
		end
	end, { desc = "Explore Last or Mount Remote Server" })
end

return M
