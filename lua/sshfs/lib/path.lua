-- lua/sshfs/lib/path.lua
-- Path manipulation utilities

local Path = {}

--- Map remote file path to local mount path
--- Converts absolute or relative remote paths to paths relative to the search base
---@param file_path string Remote file path from find/grep command
---@param remote_base_path string The remote base path that was searched (e.g., "/var/www/app" or ".")
---@return string relative_path Path relative to the remote base, without leading slashes
function Path.map_remote_to_relative(file_path, remote_base_path)
  -- If remote base path is absolute and file starts with it, strip the base path
  if remote_base_path ~= "." and file_path:sub(1, #remote_base_path) == remote_base_path then
    local relative = file_path:sub(#remote_base_path + 1)
    relative = relative:gsub("^/", "") -- Strip leading slash if present
    return relative
  end

  -- For relative paths (. or relative file paths), strip leading ./ and /
  local normalized = file_path:gsub("^%./", "")
  normalized = normalized:gsub("^/", "")
  return normalized
end

--- A local directory path in its one canonical spelling: absolute, normalized, no trailing slash, symlinks resolved
--- The path need not exist: its deepest existing ancestor is resolved and the rest appended, so the spelling
--- stays the same once the missing part is created.
---@param path string
---@return string
function Path.canonical(path)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(path), ":p"))
  local missing, current = {}, normalized
  while true do
    local real = vim.uv.fs_realpath(current)
    if real then
      if #missing == 0 then return real end
      return (real == "/" and "" or real) .. "/" .. table.concat(missing, "/")
    end
    local parent = vim.fs.dirname(current)
    if parent == current then return normalized end
    table.insert(missing, 1, vim.fs.basename(current))
    current = parent
  end
end

return Path
