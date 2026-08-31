-- tests/harness.lua
-- Minimal dependency-free test harness for sshfs.nvim
--
-- Tests are plain Lua files that call describe/it and the expect helpers. The
-- runner executes them inside headless Neovim so the real vim API is available
-- and only the system-facing calls need stubbing.

local Harness = {}

local suites = {}
local current_suite = nil

--- Register a group of test cases
--- @param name string Suite name
--- @param fn function Function that registers cases with it()
function Harness.describe(name, fn)
  local suite = { name = name, cases = {} }
  table.insert(suites, suite)

  current_suite = suite
  local ok, err = pcall(fn)
  current_suite = nil

  if not ok then
    -- A suite that fails to register is reported as a single failing case so
    -- the runner still exits non-zero instead of silently skipping it.
    table.insert(suite.cases, {
      name = "<suite registration>",
      fn = function()
        error(err, 0)
      end,
    })
  end
end

--- Register a single test case
--- @param name string Case name
--- @param fn function Test body; failures are raised as errors
function Harness.it(name, fn)
  if not current_suite then error("it() called outside of describe()", 2) end
  table.insert(current_suite.cases, { name = name, fn = fn })
end

local function render(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) == "table" then return vim.inspect(value) end
  return tostring(value)
end

local function fail(message, level)
  error(message, (level or 2) + 1)
end

Harness.expect = {}

--- Assert deep equality, comparing tables by value
function Harness.expect.eq(actual, expected, context)
  if not vim.deep_equal(actual, expected) then
    fail(
      string.format("%sexpected %s\n     got %s", context and (context .. ": ") or "", render(expected), render(actual))
    )
  end
end

--- Assert a value is neither nil nor false
function Harness.expect.truthy(value, context)
  if not value then
    fail(string.format("%sexpected a truthy value, got %s", context and (context .. ": ") or "", render(value)))
  end
end

--- Assert a value is nil or false
function Harness.expect.falsy(value, context)
  if value then
    fail(string.format("%sexpected a falsy value, got %s", context and (context .. ": ") or "", render(value)))
  end
end

--- Assert a value is exactly nil (distinct from false)
function Harness.expect.is_nil(value, context)
  if value ~= nil then
    fail(string.format("%sexpected nil, got %s", context and (context .. ": ") or "", render(value)))
  end
end

--- Assert a string contains a plain substring
function Harness.expect.contains(haystack, needle, context)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    fail(
      string.format(
        "%sexpected %s to contain %s",
        context and (context .. ": ") or "",
        render(haystack),
        render(needle)
      )
    )
  end
end

--- Assert a function raises, optionally matching a plain substring of the error
function Harness.expect.errors(fn, needle, context)
  local ok, err = pcall(fn)
  if ok then fail(string.format("%sexpected the call to raise an error", context and (context .. ": ") or "")) end
  if needle then Harness.expect.contains(tostring(err), needle, context) end
end

--- Assert a function does not raise, returning every result it produced
function Harness.expect.no_error(fn, context)
  local results = { pcall(fn) }
  if not results[1] then
    fail(string.format("%sexpected no error, got %s", context and (context .. ": ") or "", tostring(results[2])))
  end
  return unpack(results, 2, #results)
end

--- Run every registered suite and report results
--- @return number exit_code 0 when all cases pass
function Harness.run()
  -- io.write keeps line breaks deterministic; print() interleaves oddly under `nvim -l`
  local function say(text)
    io.write((text or "") .. "\n")
  end

  local passed, failed = 0, 0
  local failures = {}

  for _, suite in ipairs(suites) do
    say(suite.name)
    for _, case in ipairs(suite.cases) do
      local ok, err = pcall(case.fn)
      if ok then
        passed = passed + 1
        say("  ok   " .. case.name)
      else
        failed = failed + 1
        say("  FAIL " .. case.name)
        table.insert(failures, { name = suite.name .. " :: " .. case.name, err = tostring(err) })
      end
    end
  end

  say("")
  if failed > 0 then
    say("Failures:")
    for _, failure in ipairs(failures) do
      say("")
      say("  " .. failure.name)
      for line in failure.err:gmatch("[^\r\n]+") do
        say("    " .. line)
      end
    end
    say("")
  end

  say(string.format("%d passed, %d failed", passed, failed))
  return failed == 0 and 0 or 1
end

--- Discard registered suites (used by the runner between files in-process)
function Harness.reset()
  suites = {}
  current_suite = nil
end

return Harness
