-- lua/sshfs/lib/directory.lua

local Directory = {}

--- Check if a directory is empty
--- @param path string The path to the directory to check
--- @return boolean true if the directory is empty or doesn't exist, false otherwise
function Directory.is_empty(path)
	local handle = vim.uv.fs_scandir(path)
	if not handle then
		return true
	end

	local name = vim.uv.fs_scandir_next(handle)
	return name == nil
end

--- Change to directory using tab-local cd
--- @param path string|nil Directory path to change to
function Directory.change(path)
	if not path or path == "" then
		return
	end
	vim.cmd("tcd " .. vim.fn.fnameescape(path))
end

return Directory
