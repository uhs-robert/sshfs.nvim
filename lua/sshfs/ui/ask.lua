-- lua/sshfs/ui/ask.lua
-- User choice prompts to the user. Ask: for_mount_path

local Ask = {}

--- Normalize remote mount path to handle edge cases
--- @param path string|nil User-provided path
--- @param host table Host object with user field
--- @return string Normalized path suitable for remote mounting
local function normalize_remote_path(path, host)
	-- Handle empty/nil -> root directory
	if not path or path == "" then
		return "/"
	end

	-- Trim whitespace
	path = vim.trim(path)

	-- Handle empty after trim
	if path == "" then
		return "/"
	end

	-- Pass through ~ paths as-is to resolve during mount
	if path == "~" or path:match("^~/") then
		return path
	end

	-- Handle paths without leading slash -> prepend /
	if path:sub(1, 1) ~= "/" then
		return "/" .. path
	end

	return path
end

--- Ask for mount location
--- @param host table Host object with name field
--- @param config table Plugin configuration
--- @param callback function Callback invoked with selected remote path or nil
function Ask.for_mount_path(host, config, callback)
	local options = {
		{ label = "Home directory (~)", path = "~" },
		{ label = "Root directory (/)", path = "/" },
		{ label = "Custom Path", path = nil },
	}

	-- Add global paths that apply to all hosts
	local global_paths = config.global_paths
	if global_paths and type(global_paths) == "table" then
		for _, path in ipairs(global_paths) do
			table.insert(options, { label = path, path = path })
		end
	end

	-- Add host-specific configured path options (string or array)
	local configured_paths = config.host_paths and config.host_paths[host.name]
	if configured_paths then
		if type(configured_paths) == "string" then
			table.insert(options, { label = configured_paths, path = configured_paths })
		elseif type(configured_paths) == "table" then
			for _, path in ipairs(configured_paths) do
				table.insert(options, { label = path, path = path })
			end
		end
	end

	vim.ui.select(options, {
		prompt = "Select mount location:",
		format_item = function(item)
			return item.label
		end,
	}, function(selected)
		if not selected then
			callback(nil)
			return
		end

		-- Handle manual path entry
		if selected.path == nil then
			vim.ui.input({ prompt = "Enter remote path to mount:" }, function(path)
				if not path then
					callback(nil)
					return
				end
				local normalized_path = normalize_remote_path(path, host)
				callback(normalized_path)
			end)
		else
			local normalized_path = normalize_remote_path(selected.path, host)
			callback(normalized_path)
		end
	end)
end

return Ask
