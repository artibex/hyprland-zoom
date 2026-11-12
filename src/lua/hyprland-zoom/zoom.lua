-- zoom.lua — the zoom step model (E12), toggle/reset rules and the Hyprland zoom options.
-- Step maths is pure; only apply_level/apply_rendering talk to `hl`.

-- The module table returned to callers.
local M = {}

-- Helpers shared by all engine modules.
local util = require("hyprland-zoom.util")

-- Two zoom levels closer than this count as "the same level" (float32 noise is ~1e-7).
M.SAME_LEVEL_TOLERANCE = 1e-3
-- Zoom level the first toggle jumps to when no earlier level was remembered.
local DEFAULT_TOGGLE_ZOOM = 2.0
-- Decimal places kept in the authoritative zoom; hides 1.1^n binary noise.
local STORED_DECIMALS = 6
-- Largest notch count one call may apply (guards against absurd eval arguments).
M.MAX_NOTCHES = 100

-- M.next_level — compute the zoom after some notches.
-- Args:    current number; notches number > 0; direction 1 (in) or -1 (out);
--          settings effective settings (ZOOM_STEP, ZOOM_STEP_MODE, ZOOM_MIN, ZOOM_MAX)
-- Returns: the new zoom, clamped to [ZOOM_MIN, ZOOM_MAX]
function M.next_level(current, notches, direction, settings)
  local level
  if settings.ZOOM_STEP_MODE == "add" then
    -- Additive: every notch moves the zoom by the same amount.
    level = current + direction * notches * settings.ZOOM_STEP
  else
    -- Multiplicative: in and out are exact inverses, so n in + n out returns to start.
    level = current * (1 + settings.ZOOM_STEP) ^ (direction * notches)
  end
  -- Clamp first, then round so the bounds themselves stay exact.
  local bounded = util.clamp(level, settings.ZOOM_MIN, settings.ZOOM_MAX)
  return util.round(bounded, STORED_DECIMALS)
end

-- M.clamp_level — limit an absolute zoom request to the configured range.
-- Args:    level number; settings effective settings
-- Returns: number in [ZOOM_MIN, ZOOM_MAX]
function M.clamp_level(level, settings)
  -- Same bounds and rounding as stepping, so both paths agree.
  local bounded = util.clamp(level, settings.ZOOM_MIN, settings.ZOOM_MAX)
  return util.round(bounded, STORED_DECIMALS)
end

-- M.toggle_target — decide where the toggle goes.
-- Args:    current number; saved number or nil; settings effective settings
-- Returns: new zoom number, new saved zoom number or nil
function M.toggle_target(current, saved, settings)
  local reset_level = settings.ZOOM_RESET
  -- Away from the reset level: remember where we were and go back to reset.
  if not util.is_near(current, reset_level, M.SAME_LEVEL_TOLERANCE) then
    return reset_level, current
  end
  -- At the reset level: return to the remembered level when it is a real zoom.
  if saved and not util.is_near(saved, reset_level, M.SAME_LEVEL_TOLERANCE) then
    return M.clamp_level(saved, settings), saved
  end
  -- Nothing remembered: pick a sensible default level inside the range.
  local fallback = math.max(DEFAULT_TOGGLE_ZOOM, reset_level * 1.5)
  return M.clamp_level(fallback, settings), saved
end

-- M.reset_target — decide the result of "reset".
-- Args:    current number; saved number or nil; settings effective settings
-- Returns: new zoom number, new saved zoom number or nil
function M.reset_target(current, saved, settings)
  -- Remember the level we leave so a following toggle can return to it.
  if util.is_near(current, settings.ZOOM_RESET, M.SAME_LEVEL_TOLERANCE) then
    return settings.ZOOM_RESET, saved
  end
  return settings.ZOOM_RESET, current
end

-- M.apply_level — hand a zoom level to Hyprland.
-- Args:    host platform adapter; level number
-- Returns: true; or nil, error text
function M.apply_level(host, level)
  -- hl.config raises on bad keys; keep the engine alive and report instead.
  local applied, problem = pcall(host.hl.config, { cursor = { zoom_factor = level } })
  if not applied then
    return nil, tostring(problem)
  end
  return true
end

-- M.read_applied_level — read the zoom level Hyprland currently holds.
-- Args:    host platform adapter
-- Returns: number (float32 precision), or nil when unavailable
function M.read_applied_level(host)
  -- Protected: the option read must never break a bind callback.
  local read_ok, value = pcall(host.hl.get_config, "cursor.zoom_factor")
  if read_ok and type(value) == "number" then
    return value
  end
  return nil
end

-- M.apply_rendering — set the animation and image smoothing from the settings.
-- Args:    host platform adapter; settings effective settings
-- Returns: true; or nil, error text
function M.apply_rendering(host, settings)
  -- E9: the animation stays enabled; "instant" is just the smallest speed.
  local animated, animation_problem = pcall(host.hl.animation, {
    leaf = "zoomFactor",
    enabled = true,
    speed = settings.ZOOM_ANIMATION_SPEED,
    bezier = "default",
  })
  -- Smoothing off means "disable anti-aliasing" for crisp pixels.
  local configured, config_problem = pcall(host.hl.config, {
    cursor = { zoom_disable_aa = not settings.ZOOM_SMOOTH_IMAGES },
  })
  if not animated then
    return nil, tostring(animation_problem)
  end
  if not configured then
    -- Report the first failure; the other option may be fine.
    return nil, tostring(config_problem)
  end
  return true
end

return M
