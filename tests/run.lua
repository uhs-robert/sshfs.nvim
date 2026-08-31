-- tests/run.lua
-- Test entry point: `nvim -l tests/run.lua [pattern]`
--
-- Discovers tests/*_spec.lua, runs them in one headless Neovim instance, and
-- exits non-zero when any case fails so CI can gate on it.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Harness = require("tests.harness")
local Stub = require("tests.stub")

-- describe/it/expect are exposed as globals so spec files stay free of boilerplate
_G.describe = Harness.describe
_G.it = Harness.it
_G.expect = Harness.expect
_G.stub = Stub

local pattern = arg and arg[1]
local spec_files = vim.fn.globpath(root .. "/tests", "*_spec.lua", false, true)
table.sort(spec_files)

local loaded = 0
for _, file in ipairs(spec_files) do
  if not pattern or file:find(pattern, 1, true) then
    loaded = loaded + 1
    local chunk, err = loadfile(file)
    if not chunk then error("could not load " .. file .. ": " .. tostring(err)) end
    chunk()
  end
end

if loaded == 0 then
  print("no spec files matched" .. (pattern and (" pattern " .. pattern) or ""))
  os.exit(1)
end

-- Every case restores its own stubs, but a case that fails mid-test may not, so
-- the runner clears anything left behind before reporting.
local exit_code = Harness.run()
Stub.restore_all()
os.exit(exit_code)
