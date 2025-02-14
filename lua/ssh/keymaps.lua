local M = {}
local utils = require("ssh.utils")
if not utils then
	vim.notify("Failed to load ssh.utils", vim.log.levels.ERROR)
	return
end

function M.setup()
	-- Select Server to Mount from List
	vim.keymap.set("n", "<leader>mm", function()
		utils.user_pick_mount()
	end, { desc = "Mount a SSH Server" })

	-- Unmount Server
	vim.keymap.set("n", "<leader>mu", function()
		utils.user_pick_unmount()
	end, { desc = "Unmount a SSH Server" })

	-- Refresh Servers
	vim.keymap.set("n", "<leader>mr", function()
		utils.refresh_servers(true)
	end, { desc = "Reload SSH Server Config List" })

	-- Open Mount Directory or Auto-Mount if Empty
	vim.keymap.set("n", "<leader>me", function()
		utils.open_explorer()
	end, { desc = "Open Explorer in a Mounted Directory" })
end

return M
