-- tests/path_spec.lua
-- Remote-to-local path mapping used by the picker integrations

local function load_path()
  stub.reload()
  return require("sshfs.lib.path")
end

describe("Path.map_remote_to_relative", function()
  it("strips an absolute remote base path", function()
    local Path = load_path()
    expect.eq(Path.map_remote_to_relative("/srv/app/lib/init.lua", "/srv/app"), "lib/init.lua")
  end)

  it("strips a leading ./ for relative searches", function()
    local Path = load_path()
    expect.eq(Path.map_remote_to_relative("./lib/init.lua", "."), "lib/init.lua")
  end)

  it("strips a leading slash when the base does not match", function()
    local Path = load_path()
    expect.eq(Path.map_remote_to_relative("/other/lib/init.lua", "/srv/app"), "other/lib/init.lua")
  end)

  it("returns the base path itself as an empty relative path", function()
    local Path = load_path()
    expect.eq(Path.map_remote_to_relative("/srv/app", "/srv/app"), "")
  end)

  it("leaves an already relative path untouched", function()
    local Path = load_path()
    expect.eq(Path.map_remote_to_relative("lib/init.lua", "."), "lib/init.lua")
  end)
end)
