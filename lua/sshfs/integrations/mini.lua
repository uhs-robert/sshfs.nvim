-- lua/sshfs/integrations/mini.lua
-- Mini.pick file picker and search integration

local Mini = {}

--- Attempts to open mini.pick file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if mini.pick was successfully opened
function Mini.explore_files(cwd)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.files then
		mini_pick.builtin.files({}, { source = { cwd = cwd } })
		return true
	end
	return false
end

--- Attempts to open mini.pick live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if mini.pick was successfully opened
function Mini.grep(cwd, pattern)
	local ok, mini_pick = pcall(require, "mini.pick")
	if ok and mini_pick.builtin and mini_pick.builtin.grep_live then
		local opts = { source = { cwd = cwd } }
		if pattern and pattern ~= "" then
			opts.input = vim.split(pattern, "")
		end
		mini_pick.builtin.grep_live({}, opts)
		return true
	end
	return false
end

--- Attempts to open mini.pick live grep with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Mini.live_grep(host, mount_path, path, callback)
	local mini_ok, mini_pick = pcall(require, "mini.pick")
	if not mini_ok then
		if callback then
			callback(false)
		end
		return
	end

	local Ssh = require("sshfs.lib.ssh")
	local Path = require("sshfs.lib.path")
	local remote_path = path or "."

	-- Handler for opening grep results
	local function open_grep_result(item)
		if not item then
			vim.notify("No item selected", vim.log.levels.WARN)
			return
		end

		-- Parse grep output: filename:line:column:text
		local filename, lnum, col, _ = item:match("^([^:]+):(%d+):(%d+):(.*)$")
		if not filename then
			filename, lnum, _ = item:match("^([^:]+):(%d+):(.*)$")
			col = "1"
		end

		if not filename or not lnum then
			vim.notify("Failed to parse grep output: " .. item, vim.log.levels.ERROR)
			return
		end

		local relative_file = Path.map_remote_to_relative(filename, remote_path)
		local local_file = mount_path .. "/" .. relative_file

		-- Stop picker and schedule file opening after UI updates
		vim.schedule(function()
			local open_ok, err = pcall(function()
				vim.cmd("edit +" .. lnum .. " " .. vim.fn.fnameescape(local_file))
				if col then
					vim.api.nvim_win_set_cursor(0, { tonumber(lnum), tonumber(col) - 1 })
				end
			end)

			if not open_ok then
				vim.notify("Error opening file: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end

	-- MiniPick source that refreshes items on every keystroke.
	-- `items` is initialized empty; `match` repopulates it per query.
	local set_items_opts = { do_match = false }
	local source = {
		name = "Remote Grep (" .. host .. ")",
		items = {},
		match = function(_, _, query)
			-- mini.pick passes the current input as a table of characters.
			if type(query) == "table" then
				query = table.concat(query)
			end
			if not query or query == "" then
				return mini_pick.set_picker_items({}, set_items_opts)
			end

			-- Build SSH grep command
			local ssh_cmd = Ssh.build_command(host)
			local grep_cmd = string.format(
				"rg --color=never --no-heading --with-filename --line-number --column --smart-case -- %s %s 2>/dev/null || grep -r -n -H -- %s %s",
				vim.fn.shellescape(query),
				remote_path,
				vim.fn.shellescape(query),
				remote_path
			)
			table.insert(ssh_cmd, grep_cmd)

			-- Execute command and collect results
			local output = vim.fn.systemlist(ssh_cmd)
			local results = {}
			for _, line in ipairs(output) do
				if line and line ~= "" then
					table.insert(results, line)
				end
			end

			-- Replace picker items without extra matching
			return mini_pick.set_picker_items(results, set_items_opts)
		end,
		choose = function(item)
			open_grep_result(item)
		end,
		choose_marked = function(chosen)
			if chosen and #chosen > 0 then
				for _, item in ipairs(chosen) do
					open_grep_result(item)
				end
			end
		end,
	}

	-- Start the picker with the custom source
	mini_pick.start({
		source = source,
	})

	if callback then
		callback(true)
	end
end

--- Attempts to open mini.pick live find with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Mini.live_find(host, mount_path, path, callback)
	local mini_ok, mini_pick = pcall(require, "mini.pick")
	if not mini_ok then
		if callback then
			callback(false)
		end
		return
	end

	local Ssh = require("sshfs.lib.ssh")
	local Path = require("sshfs.lib.path")
	local remote_path = path or "."

	-- Handler for opening file results
	local function open_file_result(item)
		if not item then
			vim.notify("No item selected", vim.log.levels.WARN)
			return
		end

		local filename = item
		if not filename or filename == "" then
			vim.notify("Empty filename", vim.log.levels.ERROR)
			return
		end

		local relative_file = Path.map_remote_to_relative(filename, remote_path)
		local local_file = mount_path .. "/" .. relative_file

		-- Schedule file opening after UI updates
		vim.schedule(function()
			local open_ok, err = pcall(function()
				vim.cmd("edit " .. vim.fn.fnameescape(local_file))
			end)

			if not open_ok then
				vim.notify("Error opening file: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end

	-- Build SSH find command once
	local ssh_cmd = Ssh.build_command(host)
	local find_cmd =
		string.format("fd --color=never --type=f . %s 2>/dev/null || find %s -type f", remote_path, remote_path)
	table.insert(ssh_cmd, find_cmd)

	-- Execute command once and get all files
	local output = vim.fn.systemlist(ssh_cmd)
	local items = {}
	for _, line in ipairs(output) do
		if line and line ~= "" then
			table.insert(items, line)
		end
	end

	-- Create a custom source for file finding
	local source = {
		name = "Remote Find (" .. host .. ")",
		items = items,
		choose = function(item)
			open_file_result(item)
		end,
		choose_marked = function(chosen)
			if chosen and #chosen > 0 then
				for _, item in ipairs(chosen) do
					open_file_result(item)
				end
			end
		end,
	}

	-- Start the picker with the custom source
	mini_pick.start({
		source = source,
	})

	if callback then
		callback(true)
	end
end

return Mini
