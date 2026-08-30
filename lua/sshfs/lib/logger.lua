-- lua/sshfs/lib/logger.lua
-- Centralized debug logging for sshfs.nvim

local Logger = {}
local runtime_enabled = nil
local last_write_error = nil

local function get_config()
  local config = require("sshfs.config").get()
  return config.debug or {}
end

local function escape_log_value(value)
  return tostring(value):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
end

local function ensure_parent_dir(path)
  local parent = vim.fn.fnamemodify(path, ":h")
  if parent ~= "" and vim.fn.isdirectory(parent) == 0 then
    local result = vim.fn.mkdir(parent, "p", "0700")
    if result == 0 and vim.fn.isdirectory(parent) == 0 then error("could not create log directory: " .. parent) end
  end
end

local function write_log_line(path, line)
  local uv = vim.uv or vim.loop
  local fd, open_err = uv.fs_open(path, "a", 384)
  if not fd then error("could not open log file: " .. tostring(open_err)) end

  local chmod_ok, chmod_err = uv.fs_fchmod(fd, 384)
  if not chmod_ok then
    uv.fs_close(fd)
    error("could not set log file permissions: " .. tostring(chmod_err))
  end

  local written, write_err = uv.fs_write(fd, line .. "\n", -1)
  uv.fs_close(fd)
  if not written then error("could not write log file: " .. tostring(write_err)) end
end

local function serialize_context(context)
  if not context then return "" end
  if type(context) ~= "table" then return " " .. escape_log_value(context) end

  local parts = {}
  for key, value in pairs(context) do
    if value ~= nil then
      local rendered = type(value) == "table" and vim.inspect(value) or tostring(value)
      table.insert(parts, string.format("%s=%s", key, escape_log_value(rendered)))
    end
  end
  table.sort(parts)

  return #parts > 0 and (" " .. table.concat(parts, " ")) or ""
end

local function notify_write_failure(err)
  local message = tostring(err)
  if message == last_write_error then return end
  last_write_error = message

  vim.schedule(function()
    vim.notify("sshfs.nvim: failed to write debug log: " .. message, vim.log.levels.ERROR)
  end)
end

function Logger.is_enabled()
  if runtime_enabled ~= nil then return runtime_enabled end
  return get_config().enabled == true
end

function Logger.set_enabled(enabled)
  runtime_enabled = enabled == true
end

function Logger.enable()
  Logger.set_enabled(true)
end

function Logger.disable()
  Logger.set_enabled(false)
end

function Logger.toggle()
  Logger.set_enabled(not Logger.is_enabled())
  return Logger.is_enabled()
end

function Logger.path()
  local config = get_config()
  return vim.fn.expand(config.log_file or (vim.fn.stdpath("log") .. "/sshfs.nvim.log"))
end

function Logger.log(level, message, context)
  if not Logger.is_enabled() then return end

  local path = Logger.path()
  local line = string.format(
    "%s [%s] %s%s",
    os.date("%Y-%m-%d %H:%M:%S"),
    string.upper(level or "debug"),
    escape_log_value(message),
    serialize_context(context)
  )

  local ok, result = pcall(function()
    ensure_parent_dir(path)
    write_log_line(path, line)
  end)

  if not ok then
    notify_write_failure(result)
  else
    last_write_error = nil
  end
end

function Logger.debug(message, context)
  Logger.log("debug", message, context)
end

function Logger.info(message, context)
  Logger.log("info", message, context)
end

function Logger.warn(message, context)
  Logger.log("warn", message, context)
end

function Logger.error(message, context)
  Logger.log("error", message, context)
end

return Logger
