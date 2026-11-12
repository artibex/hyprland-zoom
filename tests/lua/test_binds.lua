-- test_binds.lua — the bind table (C7), disabled keys, Omarchy takeover (E11), reload idempotency.

-- Framework, fake host and the modules under test.
local T = require("framework")
local stub_host = require("stub_host")
local schema_module = require("hyprland-zoom.schema")
local binds = require("hyprland-zoom.binds")

-- default_settings — schema defaults with optional overrides.
-- Args:    overrides table (optional)
-- Returns: settings table
local function default_settings(overrides)
  -- Defaults come straight from the shipped schema.
  local handle = assert(io.open(T.repository_root .. "/config/settings.schema", "rb"))
  local schema = assert(schema_module.parse(handle:read("a")))
  handle:close()
  local settings = schema_module.defaults(schema)
  for key, value in pairs(overrides or {}) do
    settings[key] = value
  end
  return settings
end

-- chord_map — index a plan's binds by chord for easy assertions.
-- Args:    plan table from binds.plan
-- Returns: map chord -> bind table
local function chord_map(plan)
  -- Plan chords are unique by construction.
  local map = {}
  for _, bind in ipairs(plan.binds) do
    map[bind.keys] = bind
  end
  return map
end

-- recording_actions — action functions that count their calls.
-- Args:    calls table receiving name -> count
-- Returns: map action name -> function
local function recording_actions(calls)
  -- One counter per action name used by the plan.
  local actions = {}
  for _, name in ipairs({ "zoom_in", "zoom_out", "toggle", "filter_toggle", "reset" }) do
    actions[name] = function()
      calls[name] = (calls[name] or 0) + 1
    end
  end
  return actions
end

T.suite("binds")

T.case("the default plan matches contract C7", function()
  -- All eight default chords with the right actions; no unbinds without Omarchy.
  local plan = binds.plan(default_settings(), false)
  local map = chord_map(plan)
  local expected = {
    ["SUPER + ALT + mouse_up"] = "zoom_in", ["SUPER + ALT + mouse_down"] = "zoom_out",
    ["SUPER + ALT + mouse:274"] = "toggle", ["SUPER + ALT + I"] = "zoom_in",
    ["SUPER + ALT + O"] = "zoom_out", ["SUPER + ALT + 0"] = "toggle",
    ["SUPER + ALT + C"] = "filter_toggle", ["SUPER + ALT + Z"] = "open_settings",
  }
  for chord, action in pairs(expected) do
    T.eq(map[chord] and map[chord].action, action, chord)
  end
  T.eq(#plan.binds, 8)
  T.eq(plan.unbind, {})
  T.eq(map["SUPER + ALT + I"].repeating, true)
  T.eq(map["SUPER + ALT + O"].repeating, true)
end)

T.case("an empty key or a disabled switch removes that bind", function()
  -- Zoom-in key empty, scroll and middle click off.
  local plan = binds.plan(default_settings({ BIND_KEY_IN = "", BIND_SCROLL = false,
    BIND_MOUSE_TOGGLE = false }), false)
  local map = chord_map(plan)
  T.eq(map["SUPER + ALT + I"], nil)
  T.eq(map["SUPER + ALT + mouse_up"], nil)
  T.eq(map["SUPER + ALT + mouse:274"], nil)
  T.eq(#plan.binds, 4)
end)

T.case("custom modifiers apply to every bind", function()
  -- SUPER + CTRL for all chords.
  local plan = binds.plan(default_settings({ BIND_MODIFIERS = { "SUPER", "CTRL" } }), false)
  for _, bind in ipairs(plan.binds) do
    T.truthy(bind.keys:find("^SUPER %+ CTRL %+ "), bind.keys)
  end
end)

T.case("two actions on one chord keep the first and warn", function()
  -- Zoom in and out on the same key: the second must be dropped.
  local plan = binds.plan(default_settings({ BIND_KEY_OUT = "I" }), false)
  local map = chord_map(plan)
  T.eq(map["SUPER + ALT + I"].action, "zoom_in")
  T.eq(#plan.warnings, 1)
  T.contains(plan.warnings[1], "duplicate shortcut")
end)

T.case("takeover on Omarchy frees the scroll chords and re-routes Omarchy's zoom keys", function()
  -- E11: unbind SUPER+ALT+mouse_up/down and SUPER+CTRL+Z / SUPER+CTRL+ALT+Z, then re-bind.
  local plan = binds.plan(default_settings(), true)
  local map = chord_map(plan)
  T.eq(plan.unbind, { "SUPER + ALT + mouse_up", "SUPER + ALT + mouse_down", "SUPER + CTRL + Z",
    "SUPER + CTRL + ALT + Z" })
  T.eq(map["SUPER + CTRL + Z"].action, "zoom_in")
  T.eq(map["SUPER + CTRL + ALT + Z"].action, "reset")
end)

T.case("no takeover without Omarchy or when the switch is off", function()
  -- Plain Hyprland users must not get binds they never had.
  local without_omarchy = binds.plan(default_settings(), false)
  local switched_off = binds.plan(default_settings({ BIND_TAKEOVER_OMARCHY = false }), true)
  T.eq(without_omarchy.unbind, {})
  T.eq(switched_off.unbind, {})
  T.eq(chord_map(switched_off)["SUPER + CTRL + Z"], nil)
end)

T.case("other modifiers do not unbind Omarchy's scroll chords", function()
  -- Only SUPER + ALT collides with group cycling.
  local plan = binds.plan(default_settings({ BIND_MODIFIERS = { "SUPER", "SHIFT" } }), true)
  T.eq(plan.unbind, { "SUPER + CTRL + Z", "SUPER + CTRL + ALT + Z" })
end)

T.case("apply binds everything and a pre-existing Omarchy bind on the chord loses", function()
  -- Simulate Omarchy's group-cycling bind, then apply with takeover.
  local host = stub_host.new({ omarchy = true })
  local calls = {}
  host.hl.bind("SUPER + ALT + mouse_up", function()
    calls.omarchy = true
  end)
  local store = {}
  local problems = binds.apply(host, binds.plan(default_settings(), true), recording_actions(calls),
    store)
  T.eq(problems, {})
  host.fire("SUPER + ALT + mouse_up")
  T.eq(calls.zoom_in, 1)
  T.eq(calls.omarchy, nil)
end)

T.case("every default chord fires its action", function()
  -- Fire each live bind once; the counters must match the plan.
  local host = stub_host.new()
  local calls = {}
  binds.apply(host, binds.plan(default_settings(), false), recording_actions(calls), {})
  host.fire("SUPER + ALT + mouse_up")
  host.fire("SUPER + ALT + I")
  host.fire("SUPER + ALT + mouse_down")
  host.fire("SUPER + ALT + 0")
  host.fire("SUPER + ALT + mouse:274")
  host.fire("SUPER + ALT + C")
  T.eq(calls, { zoom_in = 2, zoom_out = 1, toggle = 2, filter_toggle = 1 })
end)

T.case("the settings key uses an exec dispatcher, not a Lua function", function()
  -- hl.dsp.exec_cmd("hyprland-zoom-settings") object is passed to hl.bind.
  local host = stub_host.new()
  binds.apply(host, binds.plan(default_settings(), false), recording_actions({}), {})
  local found
  for _, binding in ipairs(host.record.bindings) do
    if binding.keys == "SUPER + ALT + Z" then
      found = binding.action
    end
  end
  T.eq(found, { kind = "exec_cmd", command = "hyprland-zoom-settings" })
end)

T.case("applying twice leaves exactly one live bind per chord (reload idempotency)", function()
  -- The second apply removes the first apply's handles before rebinding.
  local host = stub_host.new()
  local store = {}
  local plan = binds.plan(default_settings(), false)
  binds.apply(host, plan, recording_actions({}), store)
  local first = require("stub_host").live_chords(host)
  binds.apply(host, plan, recording_actions({}), store)
  T.eq(stub_host.live_chords(host), first)
  T.eq(#first, 8)
end)

T.case("changed settings drop obsolete chords", function()
  -- Re-apply with another modifier set: the old SUPER+ALT chords must be gone.
  local host = stub_host.new()
  local store = {}
  binds.apply(host, binds.plan(default_settings(), false), recording_actions({}), store)
  binds.apply(host, binds.plan(default_settings({ BIND_MODIFIERS = { "SUPER", "CTRL" } }), false),
    recording_actions({}), store)
  for _, chord in ipairs(stub_host.live_chords(host)) do
    T.truthy(chord:find("^SUPER %+ CTRL"), chord)
  end
end)

T.case("a failing hl.bind is reported and the remaining binds still install", function()
  -- Hyprland may reject a key name; one bad bind must not block the rest.
  local host = stub_host.new()
  local original_bind = host.hl.bind
  host.hl.bind = function(keys, ...)
    if keys:find("mouse:274", 1, true) then
      error("unknown key")
    end
    return original_bind(keys, ...)
  end
  local problems = binds.apply(host, binds.plan(default_settings(), false),
    recording_actions({}), {})
  T.eq(#problems, 1)
  T.contains(problems[1], "mouse:274")
  T.eq(#stub_host.live_chords(host), 7)
end)

T.case("signature is equal for equal plans and differs when anything changes", function()
  -- The api skips re-binding when the signature is unchanged.
  local first = binds.signature(binds.plan(default_settings(), false))
  T.eq(first, binds.signature(binds.plan(default_settings(), false)))
  T.truthy(first ~= binds.signature(binds.plan(default_settings({ BIND_KEY_IN = "K" }), false)))
  T.truthy(first ~= binds.signature(binds.plan(default_settings(), true)))
end)

T.case("the settings window rule is registered once, floating and centred", function()
  -- Class match is anchored and dot-escaped.
  local host, store = stub_host.new(), {}
  binds.ensure_settings_window_rule(host, store)
  binds.ensure_settings_window_rule(host, store)
  T.eq(#host.record.window_rules, 1)
  local rule = host.record.window_rules[1]
  T.eq(rule.match.class, "^io\\.github\\.artibex\\.HyprlandZoom$")
  T.eq({ rule.float, rule.center }, { true, true })
end)
