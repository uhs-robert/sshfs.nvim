-- lua/sshfs/ui/terminal.lua
-- Terminal UI components: floating windows and terminal buffers

local Terminal = {}

--- Open SSH terminal session to remote host
function Terminal.open_ssh()
	local MountPoint = require("sshfs.lib.mount_point")
	local Ssh = require("sshfs.lib.ssh")
	local active_connections = MountPoint.list_active()

	if #active_connections == 0 then
		vim.notify("No active SSH connections", vim.log.levels.WARN)
		return
	end

	if #active_connections == 1 then
		local conn = active_connections[1]
		Ssh.open_terminal(conn.host, conn.remote_path)
		return
	end

	local items = {}
	for _, conn in ipairs(active_connections) do
		table.insert(items, conn.host)
	end

	vim.ui.select(items, {
		prompt = "Select host for SSH terminal:",
	}, function(_, idx)
		if idx then
			local conn = active_connections[idx]
			Ssh.open_terminal(conn.host, conn.remote_path)
		end
	end)
end

--- Open SSH authentication terminal in a floating window
--- Creates a centered floating window and runs the SSH command in a terminal buffer
---@param cmd table SSH command as array (e.g., {"ssh", "-o", "ControlMaster=yes", "host", "exit"})
---@param host string SSH host name (for display in title and notifications)
---@param callback function Callback(success: boolean, exit_code: number)
function Terminal.open_auth_floating(cmd, host, callback)
	-- Create buffer for terminal
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"

	-- Calculate floating window dimensions (80% of editor)
	local width = math.floor(vim.o.columns * 0.8)
	local height = math.floor(vim.o.lines * 0.8)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Create floating window
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " SSH Authentication: " .. host .. " ",
		title_pos = "center",
	}
	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Start terminal job with exit callback
	local job_id = vim.fn.jobstart(cmd, {
		term = true,
		on_exit = function(_, exit_code, _)
			vim.schedule(function()
				local success = exit_code == 0
				if success then
					-- Auto-close floating window on success
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
				else
					vim.notify(
						string.format("SSH authentication failed for %s (exit code: %d)", host, exit_code),
						vim.log.levels.ERROR
					)
				end
				callback(success, exit_code)
			end)
		end,
	})

	-- Handle failure to launch
	if job_id <= 0 then
		vim.notify("Failed to start SSH terminal for " .. host, vim.log.levels.ERROR)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		callback(false, -1)
		return
	end

	-- Enter insert mode for user interaction
	vim.cmd("startinsert")
end

return Terminal
