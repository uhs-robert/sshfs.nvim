-- keymaps.lua
local M = {}

function M.setup_keymaps(ssh)
	-- Mount Server from List
	vim.keymap.set("n", "<leader>ms", function()
		local server = ssh.select_server()
		if server then
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			ssh.mount_server(server, mount_point)
		end
	end, { desc = "Select and Mount SSH Server" })

	-- Refresh Servers
	vim.keymap.set("n", "<leader>mr", ssh.refresh_servers, { desc = "Refresh SSH Servers" })

	-- Open Mount Directory or Auto-Mount if Empty
	vim.keymap.set("n", "<leader>me", function()
		if ssh.last_mount_point and vim.fn.isdirectory(ssh.last_mount_point) == 1 then
			vim.notify("Opening last mount point: " .. ssh.last_mount_point, vim.log.levels.INFO)
			ssh.open_explorer(M.last_mount_point)
		else
			local mount_point = vim.fn.input("Enter mount directory (default: ~/Remote): ", "~/Remote")
			ssh.check_and_mount(mount_point)
		end
	end, { desc = "Explore Last or Mount Remote Server" })
end

return M
