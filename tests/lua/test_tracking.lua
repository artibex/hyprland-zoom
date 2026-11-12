-- test_tracking.lua — tracking mode mapping, plugin detection and the effective mode.

-- Framework, fake host and the module under test.
local T = require("framework")
local stub_host = require("stub_host")
local tracking = require("hyprland-zoom.tracking")

-- settings_for — minimal effective settings for tracking.
-- Args:    mode string; margin number (default 0.15)
-- Returns: settings table
local function settings_for(mode, margin)
  -- Only the two tracking keys matter to this module.
  return { ZOOM_TRACKING = mode, ZOOM_EDGE_MARGIN = margin or 0.15 }
end

T.suite("tracking")

T.case("each native mode maps to the verified camera options", function()
  -- Table from spike S1 Q7: detached x rigid per mode.
  local expected = {
    centered = { false, true }, edge = { true, false }, follow = { false, false },
  }
  for mode, options in pairs(expected) do
    local resolved = tracking.resolve(settings_for(mode), false)
    T.eq({ resolved.detached, resolved.rigid }, options, mode)
    T.eq(resolved.effective, mode)
  end
end)

T.case("margin without the plugin degrades to edge and reports the native margin", function()
  -- The user asked for margin but the plugin is absent.
  local resolved = tracking.resolve(settings_for("margin"), false)
  T.eq(resolved.configured, "margin")
  T.eq(resolved.effective, "edge")
  T.eq(resolved.edge_margin, 0.05)
  T.eq(resolved.plugin_enabled, false)
end)

T.case("margin with the plugin keeps the margin and enables the plugin", function()
  -- Effective mode stays margin and the configured value is reported.
  local resolved = tracking.resolve(settings_for("margin", 0.25), true)
  T.eq(resolved.effective, "margin")
  T.eq(resolved.edge_margin, 0.25)
  T.eq(resolved.plugin_enabled, true)
  T.eq({ resolved.detached, resolved.rigid }, { true, false })
end)

T.case("edge_margin is 0 for modes without a margin", function()
  -- centered and follow have no edge at all.
  T.eq(tracking.resolve(settings_for("centered"), false).edge_margin, 0.0)
  T.eq(tracking.resolve(settings_for("follow"), true).edge_margin, 0.0)
end)

T.case("apply sets cursor options and pre-sets the plugin keys even when it is not loaded yet", function()
  -- Verified on 0.56.2: the plugin values apply when the plugin loads later.
  local host = stub_host.new()
  local resolved, problem = tracking.apply(host, settings_for("centered"))
  T.eq(problem, nil)
  T.eq(resolved.plugin_loaded, false)
  T.eq(host.record.config["cursor.zoom_detached_camera"], false)
  T.eq(host.record.config["cursor.zoom_rigid"], true)
  T.eq(host.record.config["plugin.hyprzoom.enabled"], false)
end)

T.case("apply pushes margin and enabled to the plugin when it is loaded", function()
  -- Margin mode: plugin enabled with the configured margin.
  local host = stub_host.new({ plugin_loaded = true })
  local resolved, problem = tracking.apply(host, settings_for("margin", 0.2))
  T.eq(problem, nil)
  T.eq(resolved.effective, "margin")
  T.eq(host.record.config["plugin.hyprzoom.edge_margin"], 0.2)
  T.eq(host.record.config["plugin.hyprzoom.enabled"], true)
end)

T.case("apply disables the plugin outside margin mode", function()
  -- Plugin present but the user chose edge: native margin, plugin off.
  local host = stub_host.new({ plugin_loaded = true })
  tracking.apply(host, settings_for("edge"))
  T.eq(host.record.config["plugin.hyprzoom.enabled"], false)
  T.eq(host.record.config["plugin.hyprzoom.edge_margin"], 0.05)
end)

T.case("plugin detection tolerates a missing or failing hl.get_loaded_plugins", function()
  -- Treated as "plugin absent", never an error.
  local host = stub_host.new()
  host.hl.get_loaded_plugins = nil
  T.eq(tracking.plugin_loaded(host), false)
  host.hl.get_loaded_plugins = function()
    error("not available")
  end
  T.eq(tracking.plugin_loaded(host), false)
end)

T.case("apply reports a failing hl.config as a problem string", function()
  -- Keeps the engine alive and lets status/notify show the cause.
  local host = stub_host.new()
  host.hl.config = function()
    error("bad option")
  end
  local _, problem = tracking.apply(host, settings_for("edge"))
  T.contains(problem, "bad option")
end)
