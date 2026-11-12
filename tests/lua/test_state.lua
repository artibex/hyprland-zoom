-- test_state.lua — runtime state persistence (contract C5) against the in-memory fake host.

-- Framework, fake host and the module under test.
local T = require("framework")
local stub_host = require("stub_host")
local state = require("hyprland-zoom.state")

T.suite("state")

T.case("directory prefers ZOOMCTL_STATE_DIR, then XDG_RUNTIME_DIR, else nil", function()
  -- Override wins; the default is a subdirectory of the runtime dir.
  T.eq(state.directory(stub_host.new({ env = { ZOOMCTL_STATE_DIR = "/x/state" } })), "/x/state")
  T.eq(state.directory(stub_host.new()), "/run/user/1000/hyprland-zoom")
  -- Neither variable: persistence is disabled.
  local bare = stub_host.new()
  bare.env = {}
  T.eq(state.directory(bare), nil)
end)

T.case("write then read round-trips every key", function()
  -- Zoom values keep six decimals; flags and the filter name survive.
  local host = stub_host.new()
  host.ensure_dir("/s")
  local values = { zoom = 2.345678, saved_zoom = 3.5, filter_active = true, filter = "grayscale" }
  T.truthy(state.write(host, "/s", values))
  T.eq(state.read(host, "/s"), values)
end)

T.case("the file is plain KEY=VALUE text in a fixed order", function()
  -- Shell readers (zoomctl, status bars) rely on this format.
  local host = stub_host.new()
  host.ensure_dir("/s")
  state.write(host, "/s", { zoom = 2, filter_active = false })
  T.eq(host.files["/s/state"], "zoom=2.000000\nfilter_active=off\n")
end)

T.case("missing or corrupt files read as empty values", function()
  -- No file at all, then garbage values and out-of-range zooms.
  local host = stub_host.new()
  T.eq(state.read(host, "/s"), {})
  host.files["/s/state"] = "zoom=abc\nsaved_zoom=99\nfilter=bad name!\nfilter_active=maybe\nzzz\n"
  T.eq(state.read(host, "/s"), { filter_active = false })
end)

T.case("unknown keys are ignored for forward compatibility", function()
  -- A newer engine may add keys; an older one must not choke.
  local host = stub_host.new()
  host.files["/s/state"] = "zoom=1.5\nfuture_key=whatever\n"
  T.eq(state.read(host, "/s"), { zoom = 1.5 })
end)

T.case("the 0.1 last_zoom file is read as saved_zoom when none is stored", function()
  -- Legacy location is $XDG_RUNTIME_DIR/zoomctl/last_zoom.
  local host = stub_host.new()
  host.files["/run/user/1000/zoomctl/last_zoom"] = "2.50\n"
  T.eq(state.read(host, "/s").saved_zoom, 2.5)
  -- A stored value wins over the legacy file.
  host.files["/s/state"] = "saved_zoom=4.0\n"
  T.eq(state.read(host, "/s").saved_zoom, 4.0)
end)

T.case("write reports failure when the directory is missing", function()
  -- The engine must notice and keep running without persistence.
  local host = stub_host.new()
  local written, problem = state.write(host, "/nowhere", { zoom = 2 })
  T.eq(written, nil)
  T.contains(problem, "no such directory")
end)

T.case("the previous shader path round-trips, including the empty string", function()
  -- Empty means "the user had no shader", which differs from "nothing saved".
  local host = stub_host.new()
  host.ensure_dir("/s")
  T.eq(state.read_previous_shader(host, "/s"), nil)
  state.write_previous_shader(host, "/s", "")
  T.eq(state.read_previous_shader(host, "/s"), "")
  state.write_previous_shader(host, "/s", "/home/me/night.frag")
  T.eq(state.read_previous_shader(host, "/s"), "/home/me/night.frag")
end)
