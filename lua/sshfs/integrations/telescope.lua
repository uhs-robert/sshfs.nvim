-- lua/sshfs/integrations/telescope.lua
-- Telescope file picker and search integration

local Telescope = {}

--- Attempts to open telescope file picker
---@param cwd string Current working directory to open picker in
---@return boolean success True if telescope was successfully opened
function Telescope.explore_files(cwd)
  local ok, telescope = pcall(require, "telescope.builtin")
  if ok and telescope.find_files then
    telescope.find_files({ cwd = cwd })
    return true
  end
  return false
end

--- Attempts to open telescope live grep search
---@param cwd string Current working directory to search in
---@param pattern? string Optional search pattern to pre-populate
---@return boolean success True if telescope was successfully opened
function Telescope.grep(cwd, pattern)
  local ok, telescope = pcall(require, "telescope.builtin")
  if ok and telescope.live_grep then
    local opts = { cwd = cwd }
    if pattern and pattern ~= "" then opts.default_text = pattern end
    telescope.live_grep(opts)
    return true
  end
  return false
end

--- Creates telescope entry maker that maps SSH remote paths to SSHFS mount paths
---@param mount_path string Local SSHFS mount path
---@param remote_path string Remote SSH path being searched
---@param parse_fn function Function that parses SSH command output line into structured data
---@return function entry_maker Telescope entry maker function
local function ssh_to_sshfs_entry_maker(mount_path, remote_path, parse_fn)
  return function(line)
    local Path = require("sshfs.lib.path")
    local data = parse_fn(line)

    if not data or not data.filename then return nil end

    local relative_file = Path.map_remote_to_relative(data.filename, remote_path)
    local local_path = mount_path .. "/" .. relative_file

    return {
      value = line,
      display = data.display or relative_file,
      ordinal = data.ordinal or relative_file,
      path = local_path,
      filename = local_path,
      lnum = data.lnum,
      col = data.col,
      text = data.text,
    }
  end
end

--- Attempts to open telescope live grep with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Telescope.live_grep(host, mount_path, path, callback)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_make_entry, make_entry = pcall(require, "telescope.make_entry")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")

  if not (ok_pickers and ok_finders and ok_make_entry and ok_conf and ok_previewers) then
    if callback then callback(false) end
    return
  end

  local Ssh = require("sshfs.lib.ssh")
  local remote_path = path or "."

  -- Parser for vimgrep output format
  local function parse_grep_line(line)
    -- Parse: filename:line:col:text or filename:line:text
    local filename, lnum, col, text = line:match("^([^:]+):(%d+):(%d+):(.*)$")
    if not filename then
      filename, lnum, text = line:match("^([^:]+):(%d+):(.*)$")
      col = nil
    end

    return {
      filename = filename,
      lnum = tonumber(lnum),
      col = col and tonumber(col) or 1,
      text = text,
    }
  end

  -- Create job-based finder that runs remote grep
  local live_grepper = finders.new_job(function(prompt)
    if not prompt or prompt == "" then return nil end

    -- Build command: ssh host "rg ... || grep ..."
    local ssh_cmd = Ssh.build_command(host)
    local grep_cmd = string.format(
      "rg --color=never --no-heading --with-filename --line-number --column --smart-case -- %s %s 2>/dev/null || grep -r -n -H -- %s %s",
      vim.fn.shellescape(prompt),
      remote_path,
      vim.fn.shellescape(prompt),
      remote_path
    )
    table.insert(ssh_cmd, grep_cmd)
    return ssh_cmd
  end, ssh_to_sshfs_entry_maker(mount_path, remote_path, parse_grep_line))

  -- Custom SSH-based previewer for grep results
  local ssh_grep_previewer = previewers.new_termopen_previewer({
    get_command = function(entry)
      if not entry or not entry.value then return { "echo", "No preview available" } end

      -- Parse the grep output to get filename and line
      local data = parse_grep_line(entry.value)
      if not data.filename then return { "echo", "No preview available" } end

      -- Build SSH command to preview file with bat/cat
      -- Limit to first 10000 lines to avoid huge files, bat handles binary files gracefully
      local ssh_cmd = Ssh.build_command(host)
      local preview_cmd = string.format(
        "bat --color=always --style=numbers --highlight-line=%d --line-range=:10000 %s 2>/dev/null || head -n 10000 %s",
        data.lnum or 1,
        vim.fn.shellescape(data.filename),
        vim.fn.shellescape(data.filename)
      )
      table.insert(ssh_cmd, preview_cmd)
      return ssh_cmd
    end,
  })

  pickers
    .new({}, {
      prompt_title = "Remote Live Grep (" .. host .. ")",
      finder = live_grepper,
      previewer = ssh_grep_previewer,
      sorter = conf.values.generic_sorter({}),
    })
    :find()

  if callback then callback(true) end
end

--- Attempts to open telescope live find with remote SSH execution
---@param host string SSH host name
---@param mount_path string Local mount path to map remote files
---@param path? string Optional remote path to search (defaults to home)
---@param callback? function Optional callback(success: boolean)
function Telescope.live_find(host, mount_path, path, callback)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_make_entry, make_entry = pcall(require, "telescope.make_entry")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")

  if not (ok_pickers and ok_finders and ok_make_entry and ok_conf and ok_previewers) then
    if callback then callback(false) end
    return
  end

  local Ssh = require("sshfs.lib.ssh")
  local remote_path = path or "."

  -- Parser for find output (just filenames)
  local function parse_find_line(line)
    return {
      filename = line,
    }
  end

  -- Build command: ssh host "fd ... || find ..."
  local ssh_cmd = Ssh.build_command(host)
  local find_cmd =
    string.format("fd --color=never --type=f . %s 2>/dev/null || find %s -type f", remote_path, remote_path)
  table.insert(ssh_cmd, find_cmd)

  -- Create oneshot job finder that lists all remote files
  local file_finder = finders.new_oneshot_job(ssh_cmd, {
    entry_maker = ssh_to_sshfs_entry_maker(mount_path, remote_path, parse_find_line),
  })

  -- Custom SSH-based previewer for file contents
  local ssh_file_previewer = previewers.new_termopen_previewer({
    get_command = function(entry)
      if not entry or not entry.value then return { "echo", "No preview available" } end

      -- Get the filename from the entry
      local filename = entry.value

      -- Build SSH command to preview file with bat/cat
      -- Limit to first 10000 lines to avoid huge files, bat handles binary files gracefully
      local preview_ssh_cmd = Ssh.build_command(host)
      local preview_cmd = string.format(
        "bat --color=always --style=numbers --line-range=:10000 %s 2>/dev/null || head -n 10000 %s",
        vim.fn.shellescape(filename),
        vim.fn.shellescape(filename)
      )
      table.insert(preview_ssh_cmd, preview_cmd)
      return preview_ssh_cmd
    end,
  })

  pickers
    .new({}, {
      prompt_title = "Remote Find (" .. host .. ")",
      finder = file_finder,
      previewer = ssh_file_previewer,
      sorter = conf.values.file_sorter({}),
    })
    :find()

  if callback then callback(true) end
end

return Telescope
