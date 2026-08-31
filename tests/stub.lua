-- tests/stub.lua
-- Stubbing helpers for the system-facing calls sshfs.nvim makes
--
-- Unit tests must never touch a real SSH server or mount table, so the few
-- entry points that reach the operating system (vim.fn.system, vim.fn.executable,
-- vim.system, vim.uv.fs_stat, vim.notify) are replaced per test and restored
-- afterwards by Stub.restore_all().

local Stub = {}

local restorers = {}

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^%.]+") do
    table.insert(parts, part)
  end
  return parts
end

--- Replace a dotted field under `vim` (e.g. "fn.system") for the current test
--- @param path string Dotted path relative to the vim table
--- @param value any Replacement value
function Stub.set(path, value)
  local parts = split_path(path)
  local target = vim
  for index = 1, #parts - 1 do
    target = target[parts[index]]
  end

  local key = parts[#parts]
  local original = target[key]
  target[key] = value
  table.insert(restorers, function()
    target[key] = original
  end)
end

--- Replace vim.v so tests can control v:shell_error, which is read-only
--- @param shell_error number Value reported to code that inspects vim.v.shell_error
function Stub.shell_error(shell_error)
  local original = vim.v
  vim.v = setmetatable({ shell_error = shell_error }, { __index = original })
  table.insert(restorers, function()
    vim.v = original
  end)
end

--- Stub vim.fn.system with a handler and set the resulting v:shell_error
--- The handler receives the command (string or list) and returns output plus an
--- optional exit code, defaulting to 0.
--- @param handler function fun(cmd): string, number|nil
function Stub.system(handler)
  local shell_error = 0
  Stub.set("fn.system", function(cmd)
    local output, code = handler(cmd)
    shell_error = code or 0
    return output or ""
  end)

  local original = vim.v
  vim.v = setmetatable({}, {
    __index = function(_, key)
      if key == "shell_error" then return shell_error end
      return original[key]
    end,
  })
  table.insert(restorers, function()
    vim.v = original
  end)
end

--- Stub vim.fn.executable from a set of available command names
--- @param available table Map or list of command names that should report as present
function Stub.executable(available)
  local lookup = {}
  if vim.islist(available) then
    for _, name in ipairs(available) do
      lookup[name] = true
    end
  else
    lookup = available
  end

  Stub.set("fn.executable", function(name)
    return lookup[name] and 1 or 0
  end)
end

--- Build a vim.system replacement
--- The handler receives the command list and returns a result table with code,
--- stdout, and stderr. The stub supports both call styles used in the plugin:
--- an async callback and a synchronous `:wait()` on the returned object.
--- @param handler function fun(cmd): table
--- @return table calls List of command lists the stub received
function Stub.vim_system(handler)
  local calls = {}

  Stub.set("system", function(cmd, _, callback)
    table.insert(calls, cmd)
    local result = handler(cmd) or {}
    result.code = result.code or 0
    result.stdout = result.stdout or ""
    result.stderr = result.stderr or ""

    if callback then
      callback(result)
      return {
        wait = function()
          return result
        end,
      }
    end

    return {
      wait = function()
        return result
      end,
    }
  end)

  return calls
end

--- Capture vim.notify calls instead of printing them
--- @return table notifications List of {message, level} tables
function Stub.notifications()
  local captured = {}
  Stub.set("notify", function(message, level)
    table.insert(captured, { message = message, level = level })
  end)
  return captured
end

--- Drop cached sshfs.nvim modules so per-module state is rebuilt
--- Several modules memoize (SSHFS version detection, config options), so tests
--- that exercise that state must start from a clean load.
function Stub.reload()
  for name in pairs(package.loaded) do
    if name:match("^sshfs") then package.loaded[name] = nil end
  end
end

--- Undo every stub applied since the last restore
function Stub.restore_all()
  for index = #restorers, 1, -1 do
    restorers[index]()
  end
  restorers = {}
end

return Stub
