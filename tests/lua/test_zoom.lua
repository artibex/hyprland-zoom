-- test_zoom.lua — step model, clamping, float32 handling, toggle/reset and rendering options.

-- Framework, fake host and the module under test.
local T = require("framework")
local stub_host = require("stub_host")
local zoom = require("hyprland-zoom.zoom")

-- make_settings — build an effective-settings table with the schema defaults.
-- Args:    overrides table of KEY -> value (optional)
-- Returns: settings table
local function make_settings(overrides)
  -- Only the keys the zoom module reads are needed here.
  local settings = {
    ZOOM_STEP = 0.10, ZOOM_STEP_MODE = "multiply", ZOOM_MIN = 1.0, ZOOM_MAX = 10.0,
    ZOOM_RESET = 1.0, ZOOM_ANIMATION_SPEED = 1.5, ZOOM_SMOOTH_IMAGES = true,
  }
  for key, value in pairs(overrides or {}) do
    settings[key] = value
  end
  return settings
end

T.suite("zoom")

T.case("multiply mode zooms by (1 + step) per notch", function()
  -- Three notches from 1.0 with 10 %: 1.1^3 = 1.331.
  T.near(zoom.next_level(1.0, 3, 1, make_settings()), 1.331, 1e-9)
  T.near(zoom.next_level(2.0, 1, 1, make_settings()), 2.2, 1e-9)
end)

T.case("add mode adds the step per notch", function()
  -- 0.5 per notch in add mode.
  local settings = make_settings({ ZOOM_STEP_MODE = "add", ZOOM_STEP = 0.5 })
  T.near(zoom.next_level(1.0, 2, 1, settings), 2.0, 1e-9)
  T.near(zoom.next_level(3.0, 1, -1, settings), 2.5, 1e-9)
end)

T.case("n notches in then n notches out return exactly to the start", function()
  -- Multiplicative steps are exact inverses; rounding must hide binary noise.
  T.eq(zoom.next_level(zoom.next_level(1.0, 20, 1, make_settings()), 20, -1, make_settings()), 1.0)
end)

T.case("results are clamped to [ZOOM_MIN, ZOOM_MAX] and bounds stay exact", function()
  -- Out below 1.0, in above 10.0, and custom bounds.
  T.eq(zoom.next_level(1.0, 1, -1, make_settings()), 1.0)
  T.eq(zoom.next_level(9.9, 5, 1, make_settings()), 10.0)
  T.eq(zoom.next_level(2.0, 9, 1, make_settings({ ZOOM_MAX = 3.0 })), 3.0)
  T.eq(zoom.next_level(1.0, 1, 1, make_settings({ ZOOM_MIN = 1.5 })), 1.5)
end)

T.case("clamp_level limits absolute requests", function()
  -- Same bounds as stepping.
  T.eq(zoom.clamp_level(99, make_settings()), 10.0)
  T.eq(zoom.clamp_level(0.2, make_settings()), 1.0)
  T.eq(zoom.clamp_level(2.5, make_settings()), 2.5)
end)

T.case("the Lua value stays exact while the compositor stores float32", function()
  -- 20 notches of 0.1 additive would read back as 2.9999992847 from Hyprland (spike Q3).
  local host = stub_host.new()
  local settings = make_settings({ ZOOM_STEP_MODE = "add" })
  local level = 1.0
  for _ = 1, 20 do
    level = zoom.next_level(level, 1, 1, settings)
    zoom.apply_level(host, level)
  end
  T.eq(level, 3.0)
  -- 1.1 is not representable in float32: the stub must read back a slightly different value.
  zoom.apply_level(host, 1.1)
  T.truthy(host.record.config["cursor.zoom_factor"] ~= 1.1, "stub must model float32 storage")
  T.near(host.record.config["cursor.zoom_factor"], 1.1, 1e-6)
end)

T.case("toggle remembers the level it leaves and returns to it", function()
  -- Zoomed at 3.0: toggle goes to reset (1.0) and saves 3.0; toggling again returns to 3.0.
  local first, saved = zoom.toggle_target(3.0, nil, make_settings())
  T.eq({ first, saved }, { 1.0, 3.0 })
  local second, kept = zoom.toggle_target(1.0, saved, make_settings())
  T.eq({ second, kept }, { 3.0, 3.0 })
end)

T.case("toggle without a remembered level uses a default inside the range", function()
  -- Default 2.0; clamped when the maximum is lower; raised for a high reset level.
  T.eq((zoom.toggle_target(1.0, nil, make_settings())), 2.0)
  T.eq((zoom.toggle_target(1.0, nil, make_settings({ ZOOM_MAX = 1.5 }))), 1.5)
  T.eq((zoom.toggle_target(4.0, nil, make_settings({ ZOOM_RESET = 4.0 }))), 6.0)
end)

T.case("a remembered level equal to reset is not a real zoom", function()
  -- saved_zoom 1.0 with reset 1.0 would make the toggle a no-op; use the default instead.
  T.eq((zoom.toggle_target(1.0, 1.0, make_settings())), 2.0)
end)

T.case("reset goes to ZOOM_RESET and keeps the left level for the toggle", function()
  -- From 4.0: reset to 1.0, saved 4.0; already at reset: saved unchanged.
  local level, saved = zoom.reset_target(4.0, 2.0, make_settings())
  T.eq({ level, saved }, { 1.0, 4.0 })
  level, saved = zoom.reset_target(1.0, 2.0, make_settings())
  T.eq({ level, saved }, { 1.0, 2.0 })
end)

T.case("apply_rendering keeps the animation enabled and maps smoothing to zoom_disable_aa", function()
  -- E9: never disable the animation; speed comes from ZOOM_ANIMATION_SPEED.
  local host = stub_host.new()
  T.truthy(zoom.apply_rendering(host, make_settings({ ZOOM_ANIMATION_SPEED = 0.1,
    ZOOM_SMOOTH_IMAGES = false })))
  T.eq(host.record.animations[1], { leaf = "zoomFactor", enabled = true, speed = 0.1,
    bezier = "default" })
  T.eq(host.record.config["cursor.zoom_disable_aa"], true)
end)

T.case("read_applied_level returns the compositor value or nil", function()
  -- The stub starts at 1.0.
  local host = stub_host.new()
  T.eq(zoom.read_applied_level(host), 1.0)
  host.hl.get_config = function()
    error("boom")
  end
  T.eq(zoom.read_applied_level(host), nil)
end)

T.case("apply_level reports hl.config failures instead of raising", function()
  -- A broken hl must not escape into a bind callback.
  local host = stub_host.new()
  host.hl.config = function()
    error("unknown config key")
  end
  local applied, problem = zoom.apply_level(host, 2.0)
  T.eq(applied, nil)
  T.contains(problem, "unknown config key")
end)
