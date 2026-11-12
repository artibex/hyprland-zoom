-- test_api.lua — the engine end to end on the fake host: C3 API, C6 status, E2/E5/E7/E10/E11.

-- Framework, fixture and helpers.
local T = require("framework")
local fixture = require("engine_fixture")
local stub_host = require("stub_host")

-- new_engine — shorthand for fixture.new with the repository root.
-- Args:    options table (see engine_fixture)
-- Returns: api, host, layout
local function new_engine(options)
  -- Every case gets a completely fresh fake world.
  return fixture.new(T.repository_root, options)
end

-- status_of — HyprZoom.status() parsed into a map.
-- Args:    api table
-- Returns: map key -> value
local function status_of(api)
  -- Parsing in one place keeps assertions short.
  return fixture.status_map(api.status())
end

T.suite("api")

T.case("start applies scroll delay 0, keeps the zoom animation enabled, binds everything", function()
  -- E2 (scroll delay), E9 (animation stays enabled) and C7 (eight default binds).
  local _, host = new_engine()
  T.eq(host.record.config["binds.scroll_event_delay"], 0)
  local animation = host.record.animations[#host.record.animations]
  T.eq({ animation.leaf, animation.enabled, animation.speed }, { "zoomFactor", true, 1.5 })
  T.eq(#stub_host.live_chords(host), 8)
  T.eq(#host.record.window_rules, 1)
  T.eq(host.record.config["cursor.zoom_factor"], 1.0)
end)

T.case("status reports every C6 key in contract order", function()
  -- Order and presence of the keys, plus a few values.
  local api = new_engine()
  local keys = {}
  for key in api.status():gmatch("([%w_]+)=") do
    keys[#keys + 1] = key
  end
  T.eq(keys, { "engine", "version", "hyprland", "zoom", "saved_zoom", "tracking",
    "tracking_effective", "edge_margin", "plugin", "filter", "filter_active", "filter_shader",
    "scroll_event_delay_ms" })
  local status = status_of(api)
  T.eq({ status.engine, status.zoom, status.plugin, status.filter_active, status.filter_shader },
    { "lua", "1.00", "missing", "off", "none" })
  T.eq({ status.tracking, status.tracking_effective, status.scroll_event_delay_ms },
    { "centered", "centered", "0" })
end)

T.case("20 rapid scroll notches (wheel down) all zoom: none is lost", function()
  -- The user's #1 bug: every notch must count. 1.1^20 = 6.7275.
  local api, host = new_engine()
  for _ = 1, 20 do
    T.truthy(host.fire("SUPER + ALT + mouse_down"))
  end
  T.near(tonumber(status_of(api).zoom), 6.73, 0.006)
  T.near(host.record.config["cursor.zoom_factor"], 1.1 ^ 20, 1e-4)
end)

T.case("scroll up zooms out and the zoom never leaves [min, max]", function()
  -- 100 notches in then 100 notches out: bounds hold, return is exact.
  local api, host = new_engine()
  for _ = 1, 100 do
    host.fire("SUPER + ALT + mouse_down")
  end
  T.eq(status_of(api).zoom, "10.00")
  for _ = 1, 100 do
    host.fire("SUPER + ALT + mouse_up")
  end
  T.eq(status_of(api).zoom, "1.00")
end)

T.case("zoom_in and zoom_out take notch counts and return a short string", function()
  -- zoom_in(3) from 1.0: 1.1^3 = 1.331; return format is "zoom=<value>".
  local api = new_engine()
  T.eq(api.zoom_in(3), "zoom=1.33")
  T.eq(api.zoom_out(3), "zoom=1.00")
  T.eq(api.zoom_in(), "zoom=1.10")
end)

T.case("bad arguments return error strings and never raise", function()
  -- Strings, zero, negatives, NaN and tables.
  local api = new_engine()
  T.contains(api.zoom_in("3"), "error=")
  T.contains(api.zoom_in(0), "error=")
  T.contains(api.zoom_out(-1), "error=")
  T.contains(api.zoom_in(0 / 0), "error=")
  T.contains(api.set_zoom("x"), "error=")
  T.contains(api.set_zoom(math.huge), "error=")
  T.contains(api.filter("bogus"), "error=unknown filter action")
  T.contains(api.preview("not a table"), "error=")
end)

T.case("set_zoom clamps to the configured range", function()
  -- ZOOM_MAX 4 in the user config.
  local api = new_engine({ user_config = "ZOOM_MAX=4\n" })
  T.eq(api.set_zoom(2.5), "zoom=2.50")
  T.eq(api.set_zoom(99), "zoom=4.00")
  T.eq(api.set_zoom(0.1), "zoom=1.00")
end)

T.case("toggle remembers the last level and reset keeps it for the next toggle", function()
  -- Zoom to 3, toggle off, toggle back, reset, toggle back.
  local api = new_engine()
  api.set_zoom(3)
  T.eq(api.toggle(), "zoom=1.00")
  T.eq(status_of(api).saved_zoom, "3.00")
  T.eq(api.toggle(), "zoom=3.00")
  T.eq(api.reset(), "zoom=1.00")
  T.eq(api.toggle(), "zoom=3.00")
end)

T.case("an external zoom change is adopted before the next step", function()
  -- Someone (Omarchy's own bind) set the option to 4.0 behind our back.
  local api, host = new_engine()
  api.zoom_in()
  host.hl.config({ cursor = { zoom_factor = 4.0 } })
  T.eq(api.zoom_in(), "zoom=4.40")
end)

T.case("additive mode and a custom step come from the config", function()
  -- 0.5 per notch in add mode.
  local api = new_engine({ user_config = "ZOOM_STEP=0.50\nZOOM_STEP_MODE=add\n" })
  T.eq(api.zoom_in(2), "zoom=2.00")
end)

T.case("tracking modes set the native camera options; margin falls back without the plugin", function()
  -- margin without plugin: effective edge; with plugin: margin and plugin options.
  local api, host = new_engine({ user_config = "ZOOM_TRACKING=margin\nZOOM_EDGE_MARGIN=0.20\n" })
  local status = status_of(api)
  T.eq({ status.tracking, status.tracking_effective, status.plugin, status.edge_margin },
    { "margin", "edge", "missing", "0.05" })
  T.eq({ host.record.config["cursor.zoom_detached_camera"], host.record.config["cursor.zoom_rigid"] },
    { true, false })
  local plugin_api, plugin_host = new_engine({ user_config = "ZOOM_TRACKING=margin\n"
    .. "ZOOM_EDGE_MARGIN=0.20\n", plugin_loaded = true })
  local plugin_status = status_of(plugin_api)
  T.eq({ plugin_status.tracking_effective, plugin_status.plugin, plugin_status.edge_margin },
    { "margin", "loaded", "0.20" })
  T.eq(plugin_host.record.config["plugin.hyprzoom.edge_margin"], 0.2)
end)

T.case("each tracking mode maps to the verified camera option pair", function()
  -- centered, edge and follow on a fresh engine each.
  local expected = { centered = { false, true }, edge = { true, false }, follow = { false, false } }
  for mode, options in pairs(expected) do
    local _, host = new_engine({ user_config = "ZOOM_TRACKING=" .. mode .. "\n" })
    T.eq({ host.record.config["cursor.zoom_detached_camera"], host.record.config["cursor.zoom_rigid"] },
      options, mode)
  end
end)

T.case("SCROLL_EVENT_DELAY_MS and ZOOM_SMOOTH_IMAGES reach Hyprland", function()
  -- 50 ms delay; smoothing off means zoom_disable_aa true.
  local api, host = new_engine({ user_config = "SCROLL_EVENT_DELAY_MS=50\nZOOM_SMOOTH_IMAGES=off\n" })
  T.eq(host.record.config["binds.scroll_event_delay"], 50)
  T.eq(host.record.config["cursor.zoom_disable_aa"], true)
  T.eq(status_of(api).scroll_event_delay_ms, "50")
end)

T.case("filter toggle via the key bind applies and removes the shader", function()
  -- SUPER+ALT+C on, then off; the user's (empty) shader is restored.
  local api, host = new_engine()
  host.fire("SUPER + ALT + C")
  local status = status_of(api)
  T.eq({ status.filter, status.filter_active }, { "smart-invert", "on" })
  T.truthy(status.filter_shader:match("/run/state/filter%-%x+%.frag$"))
  T.eq(host.record.config["decoration.screen_shader"], status.filter_shader)
  host.fire("SUPER + ALT + C")
  T.eq(host.record.config["decoration.screen_shader"], "")
  T.eq(status_of(api).filter_shader, "none")
end)

T.case("filter(name) selects a filter and switches it on", function()
  -- Named selection beats the configured FILTER and implies "on".
  local api = new_engine()
  T.eq(api.filter("grayscale"), "filter=grayscale active=on")
  T.eq(api.filter("off"), "filter=grayscale active=off")
  T.eq(api.filter("toggle"), "filter=grayscale active=on")
end)

T.case("FILTER_ONLY_WHEN_ZOOMED switches the shader at the 1.0 boundary", function()
  -- On at 1.0: no shader; zoom in: shader; reset: shader removed again.
  local api, host = new_engine({ user_config = "FILTER_ONLY_WHEN_ZOOMED=on\n" })
  api.filter("on")
  T.eq(status_of(api).filter_shader, "none")
  api.zoom_in()
  T.truthy(status_of(api).filter_shader ~= "none")
  api.reset()
  -- Zoom-out: the shader stays while the animation runs, then the timer releases it (R-P1a-12).
  T.truthy(status_of(api).filter_shader ~= "none")
  host.run_timers()
  T.eq(status_of(api).filter_shader, "none")
  T.eq(host.record.config["decoration.screen_shader"], "")
end)

T.case("only the newest zoom-out may release the filter (older timers are cancelled)", function()
  -- out, in, out again: the first timer fires while the second animation still runs.
  local api, host = new_engine({ user_config = "FILTER_ONLY_WHEN_ZOOMED=on\n" })
  api.filter("on")
  api.zoom_in()
  api.reset()
  api.zoom_in()
  api.reset()
  T.eq(#host.timers, 2)
  host.timers[1].callback()
  T.truthy(status_of(api).filter_shader ~= "none", "an outdated timer released the filter")
  host.timers[2].callback()
  T.eq(status_of(api).filter_shader, "none")
end)

T.case("the filter release waits for the zoom animation (speed x 100 ms + margin)", function()
  -- ZOOM_ANIMATION_SPEED 2.0 lasts 200 ms; the release is scheduled a little later.
  local api, host = new_engine({
    user_config = "FILTER_ONLY_WHEN_ZOOMED=on\nZOOM_ANIMATION_SPEED=2.00\n" })
  api.filter("on")
  api.zoom_in()
  host.timers = {}
  api.reset()
  T.eq(#host.timers, 1)
  T.eq(host.timers[1].milliseconds, 300)
end)

T.case("a configured FILTER_ACTIVE=on starts with the filter applied", function()
  -- Config value is the initial state when nothing is restored.
  local api = new_engine({ user_config = "FILTER_ACTIVE=on\nFILTER=grayscale\n" })
  local status = status_of(api)
  T.eq({ status.filter, status.filter_active }, { "grayscale", "on" })
  T.truthy(status.filter_shader ~= "none")
end)

T.case("state is persisted on every change", function()
  -- zoom, saved_zoom, filter_active and the instance land in the state file.
  local api, host = new_engine()
  api.set_zoom(2.5)
  api.filter("grayscale")
  local text = host.files[fixture.STATE_DIRECTORY .. "/state"]
  T.contains(text, "zoom=2.500000")
  T.contains(text, "filter_active=on")
  T.contains(text, "filter=grayscale")
  T.contains(text, "instance=instance-1")
end)

T.case("a compositor reload restores zoom and filter (E10)", function()
  -- Fresh hl and Lua state, same filesystem: the zoom and the shader come back.
  local first_api, first_host = new_engine()
  first_api.set_zoom(3)
  first_api.filter("invert")
  local api, host = new_engine({ previous = first_host })
  local status = status_of(api)
  T.eq({ status.zoom, status.filter, status.filter_active }, { "3.00", "invert", "on" })
  T.eq(host.record.config["cursor.zoom_factor"], 3.0)
  T.truthy(host.record.config["decoration.screen_shader"]:match("filter%-%x+%.frag$"))
end)

T.case("ZOOM_RESTORE_ON_RELOAD=off starts unzoomed", function()
  -- The user prefers a clean slate after reloads.
  local first_api, first_host = new_engine()
  first_api.set_zoom(3)
  local api = new_engine({ previous = first_host, user_config = "ZOOM_RESTORE_ON_RELOAD=off\n" })
  T.eq(status_of(api).zoom, "1.00")
end)

T.case("state from another Hyprland instance is not restored", function()
  -- A stale file from the previous login session must not zoom the new one.
  local first_api, first_host = new_engine({ instance = "instance-1" })
  first_api.set_zoom(3)
  local api = new_engine({ previous = first_host, instance = "instance-2" })
  T.eq(status_of(api).zoom, "1.00")
end)

T.case("stale shader files of earlier sessions are removed at start", function()
  -- Leftover filter-*.frag from a crash must disappear; other files stay.
  local _, first_host = new_engine()
  first_host.files[fixture.STATE_DIRECTORY .. "/filter-aaaaaaaaaaaa.frag"] = "old"
  new_engine({ previous = first_host })
  T.eq(first_host.files[fixture.STATE_DIRECTORY .. "/filter-aaaaaaaaaaaa.frag"], nil)
end)

T.case("reload re-reads the config, keeps the zoom and rebinds without duplicates", function()
  -- Change the step in the file, reload twice, check live binds and zoom.
  local api, host = new_engine()
  api.set_zoom(2)
  host.files[fixture.USER_CONFIG] = "ZOOM_STEP=0.50\nBIND_KEY_IN=K\n"
  T.eq(api.reload(), "ok warnings=0")
  T.eq(api.reload(), "ok warnings=0")
  T.eq(api.zoom_in(), "zoom=3.00")
  local chords = stub_host.live_chords(host)
  T.eq(#chords, 8)
  T.truthy(host.fire("SUPER + ALT + K"))
  T.eq(host.fire("SUPER + ALT + I"), false)
end)

T.case("reload reports configuration warnings through warnings()", function()
  -- An unknown key and an invalid value.
  local api = new_engine({ user_config = "BOGUS=1\nZOOM_STEP=abc\n" })
  T.contains(api.warnings(), "unknown key BOGUS")
  T.contains(api.warnings(), "invalid ZOOM_STEP")
  T.eq(api.reload(), "ok warnings=2")
end)

T.case("loading the entry twice in one Lua state keeps the zoom and the binds", function()
  -- Simulates dofile running again: same api table, same store.
  local api, host, layout = new_engine()
  api.set_zoom(2)
  require("hyprland-zoom.api").install(api, host, layout)
  T.eq(status_of(api).zoom, "2.00")
  T.eq(#stub_host.live_chords(host), 8)
  host.fire("SUPER + ALT + mouse_down")
  T.eq(status_of(api).zoom, "2.20")
end)

T.case("Omarchy takeover re-routes SUPER+CTRL+Z and SUPER+CTRL+ALT+Z to the engine", function()
  -- E11: both of Omarchy's zoom binds drive the engine's zoom.
  local api, host = new_engine({ omarchy = true })
  host.fire("SUPER + CTRL + Z")
  T.eq(status_of(api).zoom, "1.10")
  host.fire("SUPER + CTRL + ALT + Z")
  T.eq(status_of(api).zoom, "1.00")
end)

T.case("preview applies overrides live without touching saved settings", function()
  -- FILTER_ACTIVE and a baked contrast value show up in the shader; nothing is persisted as config.
  local api, host = new_engine()
  T.eq(api.preview({ FILTER_ACTIVE = "on", FILTER = "grayscale", FILTER_CONTRAST = "2.00" }), "ok")
  local status = status_of(api)
  T.eq({ status.filter, status.filter_active }, { "grayscale", "on" })
  local shader = host.files[status.filter_shader]
  T.contains(shader, "const float FILTER_CONTRAST = 2.0000;")
  T.eq(host.files[fixture.USER_CONFIG], nil)
end)

T.case("preview_end restores the saved configuration", function()
  -- After the end the shader is gone and the settings are the saved ones again.
  local api, host = new_engine()
  api.preview({ FILTER_ACTIVE = "on", SCROLL_EVENT_DELAY_MS = "120" })
  T.eq(host.record.config["binds.scroll_event_delay"], 120)
  T.eq(api.preview_end(), "ok")
  T.eq(host.record.config["binds.scroll_event_delay"], 0)
  T.eq(status_of(api).filter_active, "off")
  T.eq(host.record.config["decoration.screen_shader"], "")
end)

T.case("an invalid preview is rejected as a whole and changes nothing", function()
  -- One bad value among good ones: no partial application.
  local api, host = new_engine()
  local result = api.preview({ SCROLL_EVENT_DELAY_MS = 120, FILTER = "x'); os.exit() --" })
  T.contains(result, "error=invalid FILTER")
  T.eq(host.record.config["binds.scroll_event_delay"], 0)
end)

T.case("a preview of the bind modifiers rebinds and preview_end rebinds back", function()
  -- Live shortcut preview for the settings window.
  local api, host = new_engine()
  api.preview({ BIND_MODIFIERS = "SUPER + CTRL" })
  for _, chord in ipairs(stub_host.live_chords(host)) do
    T.truthy(chord:find("^SUPER %+ CTRL"), chord)
  end
  api.preview_end()
  for _, chord in ipairs(stub_host.live_chords(host)) do
    T.truthy(chord:find("^SUPER %+ ALT"), chord)
  end
end)

T.case("a forgotten preview ends itself after the timeout", function()
  -- Timer fires before the deadline: re-arms; after the deadline: preview ends.
  local api, host = new_engine()
  api.preview({ SCROLL_EVENT_DELAY_MS = 120 })
  T.eq(#host.timers, 1)
  host.clock = host.clock + 100
  host.run_timers()
  T.eq(host.record.config["binds.scroll_event_delay"], 120)
  host.clock = host.clock + 400
  host.run_timers()
  T.eq(host.record.config["binds.scroll_event_delay"], 0)
end)

T.case("a filter action during a preview is not masked by the preview", function()
  -- Previewed FILTER_ACTIVE on, then the user toggles the filter off for real.
  local api = new_engine()
  api.preview({ FILTER_ACTIVE = true })
  T.eq(api.filter("off"), "filter=smart-invert active=off")
  T.eq(status_of(api).filter_active, "off")
end)

T.case("a missing schema leaves a harmless engine that explains itself", function()
  -- Every function answers with an error string; status names the cause; nothing raises.
  local api, host = new_engine({ without_schema = true })
  T.contains(api.zoom_in(), "error=engine not started")
  T.contains(api.status(), "settings schema not found")
  T.eq(#stub_host.live_chords(host), 0)
  T.truthy(#host.record.notifications >= 1)
end)

T.case("a failing hl call inside a bind callback never raises", function()
  -- Hyprland would otherwise log a Lua error per notch.
  local _, host = new_engine()
  host.hl.config = function()
    error("compositor said no")
  end
  T.truthy(host.fire("SUPER + ALT + mouse_down"))
  T.truthy(#host.record.notifications >= 1)
end)

T.case("notifications are not repeated for the same problem", function()
  -- 20 failing notches produce one notification, not 20.
  local _, host = new_engine()
  host.hl.config = function()
    error("compositor said no")
  end
  local before = #host.record.notifications
  for _ = 1, 20 do
    host.fire("SUPER + ALT + mouse_down")
  end
  T.eq(#host.record.notifications - before, 1)
end)

-- plugin_settings — user config that asks for the margin mode.
local MARGIN_CONFIG = "ZOOM_TRACKING=margin\nZOOM_EDGE_MARGIN=0.30\n"

T.case("without the plugin no operation produces a config error (R-P1a-01, R-P2-01)", function()
  -- Load, reload, set, preview, zoom, filter: the compositor must never see an unknown key.
  local api, host = new_engine({ user_config = MARGIN_CONFIG })
  T.eq(host.record.config_errors, {})
  api.reload()
  api.preview({ ZOOM_TRACKING = "margin", ZOOM_EDGE_MARGIN = "0.20" })
  api.preview_end()
  api.zoom_in()
  api.filter("on")
  api.set_zoom(2, false)
  T.eq(host.record.config_errors, {})
  T.eq(status_of(api).tracking_effective, "edge")
end)

T.case("with the plugin the margin is applied and still no config error", function()
  -- The plugin keys exist, so setting them is valid.
  local api, host = new_engine({ user_config = MARGIN_CONFIG, plugin_loaded = true })
  T.eq(host.record.config["plugin.hyprzoom.edge_margin"], 0.3)
  T.eq(status_of(api).tracking_effective, "margin")
  T.eq(host.record.config_errors, {})
end)

T.case("a plugin loaded after the engine activates the margin on the next event (R-P1a-03)", function()
  -- Engine first, plugin later: hyprland.start / config.reloaded re-apply without a manual reload.
  local api, host = new_engine({ user_config = MARGIN_CONFIG })
  T.eq(status_of(api).plugin, "missing")
  host.set_plugin({ listed = true, config = true })
  host.emit("config.reloaded")
  local status = status_of(api)
  T.eq({ status.plugin, status.tracking_effective, status.edge_margin }, { "loaded", "margin", "0.30" })
  T.eq(host.record.config["plugin.hyprzoom.enabled"], true)
end)

T.case("an unloaded plugin falls back to edge on the next event without config errors", function()
  -- Plugin gone again: status says so and nothing tries to set its removed keys.
  local api, host = new_engine({ user_config = MARGIN_CONFIG, plugin_loaded = true })
  host.set_plugin({ listed = false, config = false })
  host.emit("hyprland.start")
  T.eq(status_of(api).tracking_effective, "edge")
  T.eq(status_of(api).plugin, "missing")
  T.eq(host.record.config_errors, {})
end)

T.case("an event without a plugin change does not re-apply anything", function()
  -- config.reloaded fires on every reload; the refresh must be cheap when nothing changed.
  local _, host = new_engine({ user_config = MARGIN_CONFIG })
  local calls_before = #host.record.config_calls
  host.emit("config.reloaded")
  T.eq(#host.record.config_calls, calls_before)
end)

T.case("running the install again in the same Lua state registers the events only once", function()
  -- Two handlers would double the work of every reload.
  local api, host, layout = new_engine()
  require("hyprland-zoom.api").install(api, host, layout)
  T.eq(#host.record.handlers["config.reloaded"], 1)
  T.eq(#host.record.handlers["hyprland.start"], 1)
end)

T.case("repeated previews do not pile up bind warnings (R-P1a-06)", function()
  -- Three previews of the same duplicate shortcut produce one warning line, none after the end.
  local api = new_engine()
  for _ = 1, 3 do
    api.preview({ BIND_KEY_OUT = "I" })
  end
  local _, count = api.warnings():gsub("duplicate shortcut", "")
  T.eq(count, 1)
  api.preview_end()
  T.eq(api.warnings(), "none")
end)

T.case("a shortcut another tool binds is reported through warnings() (R-P1a-09)", function()
  -- The user's bindings.lua already uses SUPER+ALT+I; both would run.
  local api = new_engine({ files = {
    ["/home/test/.config/hypr/bindings.lua"] = 'hl.bind("SUPER + ALT + I", my_function)\n' } })
  T.contains(api.warnings(), "SUPER + ALT + I is also bound in your hypr/bindings.lua")
end)

-- Omarchy's tiling binds as the fake filesystem holds them: the scroll chords and the zoom key the
-- takeover frees, plus SUPER+ALT+I which the takeover never touches.
local OMARCHY_TILING_PATH = "/usr/share/omarchy/default/hypr/bindings/tiling.lua"
local OMARCHY_TILING_BINDS = table.concat({
  'hl.bind("SUPER + ALT + mouse_down", cycle_next)',
  'hl.bind("SUPER + ALT + mouse_up", cycle_previous)',
  'hl.bind("SUPER + CTRL + Z", omarchy_zoom)',
  'hl.bind("SUPER + ALT + I", something_else)',
}, "\n")

T.case("Omarchy's bind files are ignored when Omarchy is not loaded (nested instance)", function()
  -- The files exist on disk (package installed) but this Hyprland never loaded them.
  local api = new_engine({ omarchy = false, files = { [OMARCHY_TILING_PATH] = OMARCHY_TILING_BINDS } })
  T.eq(api.warnings(), "none")
end)

T.case("the takeover frees chords: only the untouched Omarchy chord is reported", function()
  -- With Omarchy loaded and the takeover on, the freed chords are no collision any more.
  local api = new_engine({ omarchy = true, files = { [OMARCHY_TILING_PATH] = OMARCHY_TILING_BINDS } })
  local warnings = api.warnings()
  T.contains(warnings, "SUPER + ALT + I is also bound in Omarchy bindings/tiling.lua")
  T.eq(warnings:find("mouse_down", 1, true), nil)
  T.eq(warnings:find("mouse_up", 1, true), nil)
  T.eq(warnings:find("SUPER + CTRL + Z", 1, true), nil)
end)

T.case("with the takeover off and Omarchy loaded the scroll collision is reported", function()
  -- Nothing is freed, so Omarchy's bind and ours both run on the scroll chords.
  local api = new_engine({ omarchy = true, user_config = "BIND_TAKEOVER_OMARCHY=off\n",
    files = { [OMARCHY_TILING_PATH] = OMARCHY_TILING_BINDS } })
  local warnings = api.warnings()
  T.contains(warnings, "SUPER + ALT + mouse_down is also bound in Omarchy bindings/tiling.lua")
  T.contains(warnings, "SUPER + ALT + mouse_up is also bound in Omarchy bindings/tiling.lua")
end)

T.case("reload adopts a zoom another tool set instead of overwriting it (R-P1a-07)", function()
  -- Omarchy's own bind or `hyprctl keyword` changed the zoom behind the engine's back.
  local api, host = new_engine()
  api.zoom_in()
  host.hl.config({ cursor = { zoom_factor = 3.0 } })
  api.reload()
  T.eq(status_of(api).zoom, "3.00")
  T.near(host.record.config["cursor.zoom_factor"], 3.0, 1e-6)
  host.hl.config({ cursor = { zoom_factor = 2.0 } })
  api.preview({ ZOOM_STEP = "0.50" })
  T.eq(status_of(api).zoom, "2.00")
end)

T.case("set_zoom(factor, false) is transient: saved_zoom stays untouched (C3)", function()
  -- A UI test zoom must not change where the toggle returns to.
  local api = new_engine()
  api.set_zoom(3)
  api.reset()
  T.eq(status_of(api).saved_zoom, "3.00")
  api.set_zoom(2, false)
  T.eq(status_of(api).saved_zoom, "3.00")
  api.set_zoom(1.5, false)
  T.eq(status_of(api).saved_zoom, "3.00")
  T.eq(status_of(api).zoom, "1.50")
end)

T.case("set_zoom without the flag remembers the level it leaves, like reset", function()
  -- Default is remember=true: 3 -> 2 keeps 3 for the toggle; leaving 1.0 keeps what was there.
  local api = new_engine()
  api.set_zoom(3)
  api.set_zoom(2)
  T.eq(status_of(api).saved_zoom, "3.00")
  api.set_zoom(1)
  T.eq(status_of(api).saved_zoom, "2.00")
  api.set_zoom(4)
  T.eq(status_of(api).saved_zoom, "2.00")
  T.contains(api.set_zoom(2, "yes"), "error=remember must be true or false")
end)

T.case("status reports the version of the VERSION file; a missing file says unknown", function()
  -- The version has one source (E3-style): the repository's VERSION file.
  local handle = assert(io.open(T.repository_root .. "/VERSION", "rb"))
  local file_version = handle:read("a"):match("%S+")
  handle:close()
  T.eq(status_of(new_engine()).version, file_version)
  local api_module = require("hyprland-zoom.api")
  T.eq(api_module.read_version({ read_file = function() return nil end }, "/x"), "unknown")
  T.eq(api_module.read_version({ read_file = function() return "not a version!\n" end }, "/x"),
    "unknown")
  T.eq(api_module.read_version({ read_file = function() return "1.2.3\n" end }, "/x"), "1.2.3")
end)

