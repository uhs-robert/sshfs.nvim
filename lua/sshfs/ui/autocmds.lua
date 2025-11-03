-- lua/sshfs/ui/autocmds.lua
-- UI-related autocommands for sshfs.nvim

local M = {}

local _state = { armed = false, base_dir = nil }

local function _starts_with(a, b)
	local norm = vim.fs.normalize
	a, b = norm(a or ""), norm(b or "")
	return a == b or vim.startswith(a, b .. "/")
end

local function _chdir(dir)
	if not dir or dir == "" then
		return
	end
	vim.cmd("tcd " .. vim.fn.fnameescape(dir))
end

-- Chdir-on-next-open (tab-local, armed once)
-- Changes to tab-local directory when opening file via SSHBrowse
local _aug = vim.api.nvim_create_augroup("sshfs_chdir_next_open", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
	group = _aug,
	pattern = "*",
	callback = function(args)
		if not _state.armed then
			return
		end
		if vim.bo[args.buf].buftype ~= "" then
			return
		end

		local path = vim.api.nvim_buf_get_name(args.buf)
		if path == "" then
			return
		end
		if _state.base_dir and not _starts_with(path, _state.base_dir) then
			return
		end

		_chdir(vim.fs.dirname(path))
		_state.armed = false
		_state.base_dir = nil
	end,
})

function M.chdir_on_next_open(base_dir)
	_state.armed = true
	_state.base_dir = base_dir
end

return M
