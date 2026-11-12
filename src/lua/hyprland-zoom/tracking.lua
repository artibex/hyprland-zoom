-- tracking.lua — pointer tracking modes (E5) mapped onto Hyprland's native camera options.
-- A configurable edge margin needs the optional hyprzoom plugin (E6, C9); without it `margin`
-- falls back to `edge` and the effective mode says so.

-- The module table returned to callers.
local M = {}

-- Name under which the plugin registers itself with Hyprland.
local PLUGIN_NAME = "hyprzoom"
-- Hyprland's built-in edge margin (a 0.9 camera box leaves 5 % per side).
M.NATIVE_EDGE_MARGIN = 0.05

-- Camera options per mode, from the verified 4-combination table (spike S1, Q7).
local CAMERA_OPTIONS = {
  -- Pointer stays in the middle: attached camera, rigid.
  centered = { detached = false, rigid = true },
  -- Camera pans only when the pointer leaves the native margin box.
  edge = { detached = true, rigid = false },
  -- Same camera as edge; the plugin widens the margin.
  margin = { detached = true, rigid = false },
  -- The view slides proportionally with the pointer.
  follow = { detached = false, rigid = false },
}

-- M.plugin_loaded — detect the hyprzoom plugin.
-- Args:    host platform adapter
-- Returns: true when Hyprland reports a plugin named hyprzoom
function M.plugin_loaded(host)
  -- Older or stripped builds may lack the call; treat that as "no plugin".
  local listed, plugins = pcall(host.hl.get_loaded_plugins)
  if not listed or type(plugins) ~= "table" then
    return false
  end
  for _, plugin in ipairs(plugins) do
    -- Match the plugin by its registered name.
    if plugin.name == PLUGIN_NAME then
      return true
    end
  end
  return false
end

-- M.resolve — decide the effective tracking behaviour (pure).
-- Args:    settings effective settings; plugin_loaded boolean
-- Returns: table {configured, effective, detached, rigid, edge_margin, plugin_enabled}
function M.resolve(settings, plugin_loaded)
  local configured = settings.ZOOM_TRACKING
  -- `margin` without the plugin degrades to `edge` (fixed 5 % margin).
  local effective = configured
  if configured == "margin" and not plugin_loaded then
    effective = "edge"
  end
  -- Report the margin the user actually gets; modes without a margin report 0.
  local edge_margin = 0.0
  if effective == "margin" then
    edge_margin = settings.ZOOM_EDGE_MARGIN
  elseif effective == "edge" then
    edge_margin = M.NATIVE_EDGE_MARGIN
  end
  -- The resolved behaviour, one table for status and apply.
  return {
    configured = configured,
    effective = effective,
    detached = CAMERA_OPTIONS[effective].detached,
    rigid = CAMERA_OPTIONS[effective].rigid,
    edge_margin = edge_margin,
    plugin_enabled = effective == "margin",
  }
end

-- apply_plugin_options — push margin and enabled flag to the plugin's own config values.
-- Args:    host platform adapter; resolved table from M.resolve
-- Returns: true; or nil, error text
local function apply_plugin_options(host, resolved)
  -- Outside margin mode the plugin runs disabled with the native margin value.
  local margin = resolved.plugin_enabled and resolved.edge_margin or M.NATIVE_EDGE_MARGIN
  local applied, problem = pcall(host.hl.config, {
    plugin = { hyprzoom = { edge_margin = margin, enabled = resolved.plugin_enabled } },
  })
  if not applied then
    return nil, tostring(problem)
  end
  -- Plugin options accepted (or queued until the plugin loads).
  return true
end

-- M.apply — set the Hyprland camera options (and the plugin's, when present).
-- Args:    host platform adapter; settings effective settings
-- Returns: resolved table (see M.resolve) with `plugin_loaded` added; plus error text or nil
function M.apply(host, settings)
  local plugin_loaded = M.plugin_loaded(host)
  local resolved = M.resolve(settings, plugin_loaded)
  resolved.plugin_loaded = plugin_loaded
  -- Native options first: they decide how the camera behaves with or without the plugin.
  local applied, problem = pcall(host.hl.config, {
    cursor = { zoom_detached_camera = resolved.detached, zoom_rigid = resolved.rigid },
  })
  if not applied then
    return resolved, tostring(problem)
  end
  -- Verified on 0.56.2 (P3): plugin keys may be set before the plugin loads; they apply at load.
  local _, plugin_problem = apply_plugin_options(host, resolved)
  if plugin_problem then
    return resolved, plugin_problem
  end
  return resolved, nil
end

return M
