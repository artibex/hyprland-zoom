-- test_options.lua — the safe option setter: unknown keys are reported, never set (R-P1a-01).

-- Framework, fake host and the module under test.
local T = require("framework")
local stub_host = require("stub_host")
local options = require("hyprland-zoom.options")

T.suite("options")

T.case("known options are set in one call", function()
  -- Nested tables are flattened for the probe and rebuilt for hl.config.
  local host = stub_host.new()
  T.eq(options.set(host, { cursor = { zoom_rigid = true }, binds = { scroll_event_delay = 0 } }),
    true)
  T.eq(host.record.config["cursor.zoom_rigid"], true)
  T.eq(host.record.config["binds.scroll_event_delay"], 0)
  T.eq(#host.record.config_calls, 1)
end)

T.case("an unknown option is reported and never reaches hl.config", function()
  -- The stub records a config error for every unknown key it is handed, like Hyprland 0.56.
  local host = stub_host.new()
  local applied, problem = options.set(host, { plugin = { hyprzoom = { enabled = true } } })
  T.eq(applied, nil)
  T.contains(problem, "unknown option plugin.hyprzoom.enabled")
  T.eq(host.record.config_errors, {})
  T.eq(#host.record.config_calls, 0)
end)

T.case("known options are still applied when another one is unknown", function()
  -- One missing option must not block the rest of the call.
  local host = stub_host.new()
  local applied = options.set(host, { cursor = { zoom_rigid = true }, nothing = { here = 1 } })
  T.eq(applied, nil)
  T.eq(host.record.config["cursor.zoom_rigid"], true)
  T.eq(host.record.config_errors, {})
end)

T.case("the fake host records config errors like 0.56 instead of raising", function()
  -- Guards the guard: a test double that raises would hide R-P1a-01 type bugs (R-P1a-04).
  local host = stub_host.new()
  local ok = pcall(host.hl.config, { plugin = { hyprzoom = { edge_margin = 0.3 } } })
  T.eq(ok, true)
  T.eq(host.record.config_errors, { "unknown config key 'plugin.hyprzoom.edge_margin'" })
  local value, message = host.hl.get_config("plugin.hyprzoom.edge_margin")
  T.eq(value, nil)
  T.contains(message, "unknown config key")
end)

T.case("a raising hl.config is turned into a problem string", function()
  -- Protects bind callbacks from a host that does raise.
  local host = stub_host.new()
  host.hl.config = function()
    error("boom")
  end
  local applied, problem = options.set(host, { cursor = { zoom_rigid = true } })
  T.eq(applied, nil)
  T.contains(problem, "boom")
end)
