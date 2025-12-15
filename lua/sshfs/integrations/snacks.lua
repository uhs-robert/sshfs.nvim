-- lua/sshfs/integrations/snacks.lua
-- Snacks.nvim picker and search integration

local Snacks = {}

--- Attempts to open snacks.nvim file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if snacks picker was successfully opened
function Snacks.explore_files(cwd)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.files then
		snacks.picker.files({ cwd = cwd })
		return true
	end
	return false
end

--- Attempts to open snacks.nvim grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if snacks grep was successfully opened
function Snacks.grep(cwd, pattern)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker and snacks.picker.grep then
		local opts = { cwd = cwd }
		if pattern and pattern ~= "" then
			opts.search = pattern
		end
		snacks.picker.grep(opts)
		return true
	end
	return false
end

--- Attempts to open snacks.nvim live grep with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Snacks.live_grep(host, mount_path, path, callback)
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		if callback then
			callback(false)
		end
		return
	end

	local Ssh = require("sshfs.lib.ssh")
	local remote_path = path or "."

	-- Build SSH command
	local ssh_cmd = Ssh.build_command(host)
	local grep_cmd = string.format(
		"rg --color=never --no-heading --with-filename --line-number --column --smart-case -- {q} %s 2>/dev/null || grep -r -n -H -- {q} %s",
		remote_path,
		remote_path
	)
	table.insert(ssh_cmd, grep_cmd)

	-- Custom picker with SSH grep
	snacks.picker.pick({
		prompt = "Remote Grep (" .. host .. ")",
		live = true,
		finder = function(_, ctx)
			local search = ctx.filter.search
			if not search or search == "" then
				return function() end
			end

			-- Replace {q} placeholder with actual search term
			local final_cmd = grep_cmd:gsub("{q}", vim.fn.shellescape(search))
			local ssh_args = vim.list_slice(ssh_cmd, 2)
			ssh_args[#ssh_args] = final_cmd

			local proc = require("snacks.picker.source.proc")
			return proc.proc({
				cmd = ssh_cmd[1],
				args = ssh_args,
				notify = false,
				transform = function(item)
					-- Parse grep output: filename:line:column:text
					local filename, lnum, col, text = item.text:match("^([^:]+):(%d+):(%d+):(.*)$")
					if not filename then
						filename, lnum, text = item.text:match("^([^:]+):(%d+):(.*)$")
						col = "1"
					end

					if not filename or not lnum then
						return false
					end

					local Path = require("sshfs.lib.path")
					local relative_file = Path.map_remote_to_relative(filename, remote_path)
					local local_file = mount_path .. "/" .. relative_file

					item.file = local_file
					item.pos = { tonumber(lnum), tonumber(col) - 1 }
					item.text = filename .. ":" .. lnum .. ":" .. (text or "")
				end,
			}, ctx)
		end,
	})

	if callback then
		callback(true)
	end
end

--- Attempts to open snacks.nvim live find with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Snacks.live_find(host, mount_path, path, callback)
	local ok, snacks = pcall(require, "snacks")
	if not ok or not snacks.picker then
		if callback then
			callback(false)
		end
		return
	end

	local Ssh = require("sshfs.lib.ssh")
	local remote_path = path or "."

	-- Build SSH find command
	local ssh_cmd = Ssh.build_command(host)
	local find_cmd =
		string.format("fd --color=never --type=f . %s 2>/dev/null || find %s -type f", remote_path, remote_path)
	table.insert(ssh_cmd, find_cmd)

	local proc = require("snacks.picker.source.proc")

	-- Custom picker with SSH find
	snacks.picker.pick({
		prompt = "Remote Find (" .. host .. ")",
		finder = function(_, ctx)
			return proc.proc({
				cmd = ssh_cmd[1],
				args = vim.list_slice(ssh_cmd, 2),
				notify = false,
				transform = function(item)
					local filename = item.text

					if not filename or filename == "" then
						return false
					end

					local Path = require("sshfs.lib.path")
					local relative_file = Path.map_remote_to_relative(filename, remote_path)
					local local_file = mount_path .. "/" .. relative_file

					item.file = local_file
					item.text = filename
				end,
			}, ctx)
		end,
	})

	if callback then
		callback(true)
	end
end

return Snacks
