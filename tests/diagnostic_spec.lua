-- tests/diagnostic_spec.lua
-- :SSHTest preflight reporting and ControlMaster handling

local SSH_G_OUTPUT = table.concat({
  "host example.com",
  "user deploy",
  "hostname 10.0.0.5",
  "port 2222",
  "proxyjump bastion.example.com",
  "identityfile ~/.ssh/id_ed25519",
  "identityfile ~/.ssh/id_rsa",
  "addkeystoagent false",
}, "\n")

--- Run Diagnostic.test against stubbed ssh invocations
--- @param opts table {host, auth_code, auth_stderr, home_stdout, pids, socket_error}
--- @return table report Lines of the report buffer
--- @return table control Control operations that were run, in order
--- @return table commands Every ssh command the preflight executed
local function run_preflight(opts)
  stub.reload()
  -- A real writable directory: the preflight refuses to authenticate without one.
  local socket_dir = vim.fn.tempname() .. "/sockets"
  require("sshfs.config").setup({ connections = { socket_dir = socket_dir } })

  local control = {}
  local commands = {}
  local pids = vim.deepcopy(opts.pids or {})

  -- ssh -O check / -O exit go through vim.fn.system
  stub.system(function(cmd)
    local operation = nil
    for index, argument in ipairs(cmd) do
      if argument == "-O" then operation = cmd[index + 1] end
    end
    table.insert(control, operation)

    if operation == "check" then
      -- `false` stands for "no master running" so the list keeps no nil holes.
      local pid = table.remove(pids, 1)
      if pid then return "Master running (pid=" .. pid .. ")", 0 end
      return "Control socket connect: No such file or directory", 255
    end
    return "", 0
  end)

  stub.set("schedule", function(fn)
    fn()
  end)
  stub.set("system", function(cmd, _, callback)
    table.insert(commands, cmd)

    local result = { code = 0, stdout = "", stderr = "" }
    if vim.tbl_contains(cmd, "-G") then
      result.stdout = SSH_G_OUTPUT
    elseif cmd[#cmd] == "exit" then
      result.code = opts.auth_code or 0
      result.stderr = opts.auth_stderr or ""
    else
      result.stdout = opts.home_stdout or "/home/deploy"
    end

    if callback then callback(result) end
    return {
      wait = function()
        return result
      end,
    }
  end)

  if opts.socket_error then
    package.loaded["sshfs.lib.ssh"] = setmetatable({
      prepare_socket_dir = function()
        return nil, opts.socket_error
      end,
    }, { __index = require("sshfs.lib.ssh") })
  end

  require("sshfs.diagnostic").test(opts.host or { name = "example.com" })

  local report = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.cmd("bwipeout!")
  stub.restore_all()
  vim.fn.delete(vim.fn.fnamemodify(socket_dir, ":h"), "rf")

  return report, control, commands
end

--- Join report lines for substring assertions
local function text(report)
  return table.concat(report, "\n")
end

describe("SSHTest report", function()
  it("summarizes the resolved SSH configuration", function()
    local report = run_preflight({})
    local body = text(report)

    expect.contains(body, "hostname: 10.0.0.5")
    expect.contains(body, "user: deploy")
    expect.contains(body, "port: 2222")
    expect.contains(body, "proxyjump: bastion.example.com")
  end)

  it("joins every identity file into one summary line", function()
    local report = run_preflight({})
    expect.contains(text(report), "identityfile: ~/.ssh/id_ed25519, ~/.ssh/id_rsa")
  end)

  it("omits the raw ssh -G dump that the summary already covers", function()
    local report = run_preflight({})
    local body = text(report)

    expect.falsy(body:find("addkeystoagent", 1, true), "the full resolved config would bury the results")
    expect.truthy(#report < 45, "the report stays readable; got " .. #report .. " lines")
  end)

  it("marks a successful authentication as passing", function()
    local report = run_preflight({})
    expect.contains(text(report), "[PASS] SSH authentication")
  end)

  it("reports the exit code and stderr of a failed authentication", function()
    local report = run_preflight({
      auth_code = 255,
      auth_stderr = "ssh: Could not resolve hostname example.com",
    })
    local body = text(report)

    expect.contains(body, "[FAIL] SSH authentication")
    expect.contains(body, "Exit code: 255")
    expect.contains(body, "Could not resolve hostname")
  end)

  it("shows the prospective sshfs command without running it", function()
    local report, _, commands = run_preflight({ host = { name = "example.com", path = "/srv/app" } })

    expect.contains(text(report), "sshfs")
    expect.contains(text(report), "<mount-point>")
    for _, cmd in ipairs(commands) do
      expect.falsy(cmd[1] == "sshfs", "the preflight must never execute a mount")
    end
  end)

  it("explains why no sshfs command is shown without a remote path", function()
    local report = run_preflight({})

    expect.contains(text(report), "Not shown")
    expect.falsy(text(report):find("<mount-point>", 1, true))
  end)

  it("resolves a tilde path through the remote home before showing the command", function()
    local report = run_preflight({
      host = { name = "example.com", path = "~/projects" },
      home_stdout = "/home/deploy",
    })

    expect.contains(text(report), "/home/deploy/projects")
  end)

  it("reports a socket directory failure instead of authenticating", function()
    local report = run_preflight({ socket_error = "Failed to create socket directory: permission denied" })

    expect.contains(text(report), "permission denied")
    expect.contains(text(report), "[FAIL] SSH authentication")
  end)

  it("renders into a disposable scratch buffer", function()
    stub.reload()
    require("sshfs.config").setup({})
    stub.system(function()
      return "", 255
    end)
    stub.set("schedule", function(fn)
      fn()
    end)
    stub.set("system", function(cmd, _, callback)
      local result = { code = 0, stdout = vim.tbl_contains(cmd, "-G") and SSH_G_OUTPUT or "", stderr = "" }
      if callback then callback(result) end
      return {
        wait = function()
          return result
        end,
      }
    end)

    require("sshfs.diagnostic").test({ name = "example.com" })
    local buf = vim.api.nvim_get_current_buf()

    expect.eq(vim.bo[buf].buftype, "nofile")
    expect.eq(vim.bo[buf].bufhidden, "wipe")
    expect.falsy(vim.bo[buf].modifiable, "the report is read-only")
    expect.falsy(vim.bo[buf].swapfile)

    vim.cmd("bwipeout!")
    stub.restore_all()
  end)
end)

describe("SSHTest ControlMaster handling", function()
  it("closes a master it created itself", function()
    -- No master before, one running afterwards: the preflight created it.
    local _, control = run_preflight({ pids = { false, 4242, 4242 } })

    expect.truthy(vim.tbl_contains(control, "exit"), "a diagnostic connection must not outlive the report")
  end)

  it("preserves a master that already existed", function()
    local _, control = run_preflight({ pids = { 1111, 1111 } })

    expect.falsy(vim.tbl_contains(control, "exit"), "an existing shared session must survive the preflight")
  end)

  it("does not close a master created by something else mid-test", function()
    -- No master before, but authentication failed, so the master that appeared
    -- belongs to a concurrent :SSHConnect rather than to this preflight.
    local _, control = run_preflight({ auth_code = 255, pids = { false, 9999, 9999 } })

    expect.falsy(vim.tbl_contains(control, "exit"), "closing another process's connection would break its mount")
  end)

  it("does not close a master whose pid changed after the test ran", function()
    -- Our master exited and a different one replaced it before cleanup.
    local _, control = run_preflight({ pids = { false, 4242, 5555 } })

    expect.falsy(vim.tbl_contains(control, "exit"), "the socket is no longer the one this preflight created")
  end)

  it("leaves no master behind when none was ever created", function()
    local _, control = run_preflight({ auth_code = 255, pids = {} })

    expect.falsy(vim.tbl_contains(control, "exit"))
  end)
end)
