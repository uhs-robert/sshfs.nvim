-- lua/sshfs/integrations/fzf_lua.lua
-- Fzf-lua file picker and search integration

local FzfLua = {}

--- Attempts to open fzf-lua file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if fzf-lua was successfully opened
function FzfLua.explore_files(cwd)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.files then
		fzf.files({ cwd = cwd, previewer = "builtin" })
		return true
	end
	return false
end

--- Attempts to open fzf-lua live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if fzf-lua was successfully opened
function FzfLua.grep(cwd, pattern)
	local ok, fzf = pcall(require, "fzf-lua")
	if ok and fzf.live_grep then
		local opts = { cwd = cwd, previewer = "builtin" }
		if pattern and pattern ~= "" then
			opts.query = pattern
		end
		fzf.live_grep(opts)
		return true
	end
	return false
end

--- Attempts to open fzf-lua live grep with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function FzfLua.live_grep(host, mount_path, path, callback)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok or not fzf.fzf_live then
		if callback then
			callback(false)
		end
		return
	end

	-- Build grep command string. fzf_live will replace {q} with user input.
	local Ssh = require("sshfs.lib.ssh")
	local ssh_cmd = Ssh.build_command(host)
	local ssh_base = table.concat(ssh_cmd, " ")
	local remote_path = path or "."
	local rg_cmd = string.format(
		'%s "rg --color=never --no-heading --with-filename --line-number --column --smart-case -- {q} %s || true"',
		ssh_base,
		remote_path
	)

	-- Configure fzf-lua live grep with preview
	local preview_cmd = string.format(
		[[%s "bat --color=always --style=numbers --highlight-line={2} {1} 2>/dev/null || cat {1}" 2>/dev/null || echo "Preview unavailable"]],
		ssh_base
	)

	local opts = {
		prompt = "Remote Grep (" .. host .. ")> ",
		cmd = rg_cmd,
		preview = preview_cmd,
		fzf_opts = {
			["--delimiter"] = ":",
			["--preview-window"] = "right:50%:+{2}-/2",
		},
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then
					return
				end

				-- Parse ripgrep output: filename:line:column:text
				local entry = selected[1]
				local file, line, col = entry:match("^([^:]+):(%d+):(%d+):")
				if not file then
					file, line = entry:match("^([^:]+):(%d+):")
					col = 1
				end

				-- Open file
				if file and line then
					local Path = require("sshfs.lib.path")
					local relative_file = Path.map_remote_to_relative(file, remote_path)
					local local_file = mount_path .. "/" .. relative_file
					vim.notify("Opening file...", vim.log.levels.INFO)
					vim.cmd("edit +" .. line .. " " .. vim.fn.fnameescape(local_file))
					if col then
						vim.api.nvim_win_set_cursor(0, { tonumber(line), tonumber(col) - 1 })
					end
				end
			end,
		},
	}

	fzf.fzf_live(rg_cmd, opts)

	if callback then
		callback(true)
	end
end

--- Attempts to open fzf-lua live find with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function FzfLua.live_find(host, mount_path, path, callback)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok or not fzf.fzf_exec then
		if callback then
			callback(false)
		end
		return
	end

	-- Build remote find command. Try fd first, fallback to find
	local Ssh = require("sshfs.lib.ssh")
	local ssh_cmd = Ssh.build_command(host)
	local ssh_base = table.concat(ssh_cmd, " ")
	local remote_path = path or "."
	local find_cmd = string.format(
		'%s "fd --color=never --type=f . %s 2>/dev/null || find %s -type f"',
		ssh_base,
		remote_path,
		remote_path
	)

	-- Configure fzf-lua with custom command and preview
	local preview_cmd = string.format(
		[[%s "bat --color=always --style=numbers {} 2>/dev/null || cat {}" 2>/dev/null || echo "Preview unavailable"]],
		ssh_base
	)

	local opts = {
		prompt = "Remote Find (" .. host .. ")> ",
		preview = preview_cmd,
		actions = {
			["default"] = function(selected)
				if not selected or #selected == 0 then
					return
				end

				-- Open file
				local file = selected[1]
				local Path = require("sshfs.lib.path")
				local relative_file = Path.map_remote_to_relative(file, remote_path)
				local local_file = mount_path .. "/" .. relative_file
				vim.notify("Opening file...", vim.log.levels.INFO)
				vim.cmd("edit " .. vim.fn.fnameescape(local_file))
			end,
		},
	}

	fzf.fzf_exec(find_cmd, opts)

	if callback then
		callback(true)
	end
end

return FzfLua
