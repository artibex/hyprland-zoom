-- test_entry.lua — the real entry file, real host and real filesystem (sandbox), fake `hl`.

-- Framework and the fake Hyprland API.
local T = require("framework")
local stub_host = require("stub_host")

-- Sandbox prepared by run.sh; the environment variables point into it.
local SANDBOX = assert(os.getenv("ZOOMCTL_TEST_SANDBOX"), "run via tests/lua/run.sh")
-- State directory the engine derives from ZOOMCTL_STATE_DIR.
local STATE_DIRECTORY = assert(os.getenv("ZOOMCTL_STATE_DIR"))

-- run_entry — execute the entry file as Hyprland would (dofile with global hl).
-- Args:    existing_fake fake host to reuse (same Lua state, same compositor); nil for a new one
-- Returns: the fake host whose hl was installed globally
local function run_entry(existing_fake)
  -- The fake supplies hl; everything else (io, os, filesystem) is real.
  local fake = existing_fake or stub_host.new()
  _G.hl = fake.hl
  dofile(T.repository_root .. "/src/lua/hyprland-zoom.lua")
  return fake
end

-- read_real_file — read a file from the real filesystem.
-- Args:    path string
-- Returns: content or nil
local function read_real_file(path)
  -- Missing files are expected in some checks.
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("a")
  handle:close()
  return content
end

T.suite("entry")

-- Fake compositor shared by the cases below (one Lua state, like Hyprland).
local shared_fake

T.case("dofile of the entry from a checkout installs HyprZoom and binds", function()
  -- Layout is found from the script's own path; no ZOOMCTL_SHARE_DIR needed.
  local fake = run_entry()
  shared_fake = fake
  T.truthy(type(HyprZoom) == "table" and HyprZoom.zoom_in)
  T.eq(#stub_host.live_chords(fake), 8)
  T.eq(HyprZoom.zoom_in(2), "zoom=1.21")
  T.contains(HyprZoom.status(), "engine=lua")
end)

T.case("the real state file appears in the sandbox state directory with mode 0700", function()
  -- Real mkdir and real atomic write through the real host.
  local state_text = read_real_file(STATE_DIRECTORY .. "/state")
  T.contains(state_text, "zoom=1.210000")
  local pipe = assert(io.popen("stat -c %a '" .. STATE_DIRECTORY .. "'"))
  local mode = pipe:read("l")
  pipe:close()
  T.eq(mode, "700")
end)

T.case("a real generated shader file is valid GLSL and named by its hash", function()
  -- End to end through templates on disk; compile with glslang when available.
  HyprZoom.filter("grayscale")
  local path = HyprZoom.status():match("filter_shader=([^\n]+)")
  T.truthy(path:match("/filter%-%x+%.frag$"), path)
  T.contains(read_real_file(path), "#version 300 es")
  if os.execute("command -v glslangValidator > /dev/null 2>&1") then
    T.truthy(os.execute("glslangValidator -S frag '" .. path .. "' > /dev/null"))
  end
  HyprZoom.filter("off")
  T.eq(read_real_file(path), nil)
end)

T.case("running the entry again in the same Lua state is idempotent", function()
  -- Same table, same zoom, still exactly eight live binds.
  local table_before = HyprZoom
  run_entry(shared_fake)
  T.eq(HyprZoom, table_before)
  T.contains(HyprZoom.status(), "zoom=1.21")
  T.eq(#stub_host.live_chords(shared_fake), 8)
end)

T.case("the sandbox config files named by the environment are the ones the engine reads", function()
  -- Tests must never see the real user config: ZOOMCTL_USER_CONFIG points into the sandbox.
  T.eq(os.getenv("ZOOMCTL_USER_CONFIG"), SANDBOX .. "/user.conf")
  T.eq(os.getenv("HOME"), SANDBOX .. "/home")
end)
