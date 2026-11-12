-- api.lua — the public engine API (contract C3): the global table HyprZoom.
-- Every function returns a short non-empty string and never raises into Hyprland.

-- The module table returned to callers.
local M = {}

-- Engine modules.
local util = require("hyprland-zoom.util")
local engine = require("hyprland-zoom.engine")
local tracking = require("hyprland-zoom.tracking")
local zoom = require("hyprland-zoom.zoom")

-- Package version reported by status().
M.VERSION = "0.2.0"

-- guarded — wrap an API body so errors become "error=<text>" strings.
-- Args:    session table; name string (for messages); body function(session, ...)
-- Returns: function(...) returning the body's string result
local function guarded(session, name, body)
  return function(...)
    -- Without settings (schema missing) nothing can work; say why instead of crashing.
    if not session.ready then
      return "error=engine not started: " .. tostring(session.start_problem)
    end
    local succeeded, result = pcall(body, session, ...)
    if succeeded then
      -- Success: hand the body's string straight back to the caller.
      return result
    end
    -- A Lua error in a bind callback must not reach Hyprland; log, notify once, return text.
    engine.report_problem(session, name .. ": " .. tostring(result))
    return "error=" .. util.printable_excerpt(result, 120)
  end
end

-- parse_notches — validate the notch argument of zoom_in/zoom_out.
-- Args:    value any (nil means one notch)
-- Returns: number in (0, MAX_NOTCHES]; or nil, error text
local function parse_notches(value)
  -- Default is one notch; strings from hyprctl eval are not accepted (use numbers).
  if value == nil then
    return 1
  end
  if type(value) ~= "number" or value ~= value or value <= 0 then
    return nil, "notches must be a positive number"
  end
  -- Cap absurd counts so one call cannot spin the compositor.
  return math.min(value, zoom.MAX_NOTCHES)
end

-- format_zoom — render the standard action result.
-- Args:    level number
-- Returns: "zoom=<two decimals>"
local function format_zoom(level)
  -- Two decimals match the canonical config form and are plenty for a status line.
  return string.format("zoom=%.2f", level)
end

-- change_zoom_result — shared body of zoom_in and zoom_out.
-- Args:    session table; notches any; direction 1 or -1
-- Returns: result string
local function change_zoom_result(session, notches, direction)
  local count, problem = parse_notches(notches)
  if not count then
    return "error=" .. problem
  end
  return format_zoom(engine.change_zoom(session, count, direction))
end

-- zoom_in_result — body of HyprZoom.zoom_in.
-- Args:    session table; notches any (nil means one)
-- Returns: result string
local function zoom_in_result(session, notches)
  return change_zoom_result(session, notches, 1)
end

-- zoom_out_result — body of HyprZoom.zoom_out.
-- Args:    session table; notches any (nil means one)
-- Returns: result string
local function zoom_out_result(session, notches)
  return change_zoom_result(session, notches, -1)
end

-- set_zoom_result — body of HyprZoom.set_zoom.
-- Args:    session table; factor number; remember boolean or nil (false = transient zoom)
-- Returns: result string
local function set_zoom_result(session, factor, remember)
  -- Only finite numbers are accepted; anything else is a caller bug.
  local finite = type(factor) == "number" and factor == factor and math.abs(factor) < math.huge
  if not finite then
    return "error=zoom factor must be a finite number"
  end
  -- The flag is optional, but a wrong type is a caller bug as well.
  if remember ~= nil and type(remember) ~= "boolean" then
    return "error=remember must be true or false"
  end
  return format_zoom(engine.set_zoom(session, factor, remember))
end

-- toggle_result — body of HyprZoom.toggle.
-- Args:    session table
-- Returns: result string
local function toggle_result(session)
  return format_zoom(engine.toggle_zoom(session))
end

-- reset_result — body of HyprZoom.reset.
-- Args:    session table
-- Returns: result string
local function reset_result(session)
  return format_zoom(engine.reset_zoom(session))
end

-- filter_result — body of HyprZoom.filter.
-- Args:    session table; action string (nil means toggle)
-- Returns: result string
local function filter_result(session, action)
  local acted, problem = engine.filter_action(session, action or "toggle")
  if not acted then
    return "error=" .. problem
  end
  local active = engine.current_filter_active(session) and "on" or "off"
  -- Short, parseable result for `hyprctl repl`.
  return "filter=" .. engine.current_filter_name(session) .. " active=" .. active
end

-- reload_result — body of HyprZoom.reload.
-- Args:    session table
-- Returns: result string
local function reload_result(session)
  local reloaded, problem = engine.reload(session)
  if not reloaded then
    return "error=" .. problem
  end
  return "ok warnings=" .. #engine.all_warnings(session)
end

-- preview_result — body of HyprZoom.preview.
-- Args:    session table; overrides table KEY -> value
-- Returns: result string
local function preview_result(session, overrides)
  local previewed, problem = engine.preview(session, overrides)
  if not previewed then
    return "error=" .. problem
  end
  return "ok"
end

-- preview_end_result — body of HyprZoom.preview_end.
-- Args:    session table
-- Returns: result string
local function preview_end_result(session)
  engine.preview_end(session)
  return "ok"
end

-- warnings_result — body of HyprZoom.warnings (extension to C3, for zoomctl doctor).
-- Args:    session table
-- Returns: the configuration warnings, one per line, or "none"
local function warnings_result(session)
  local warnings = engine.all_warnings(session)
  if #warnings == 0 then
    return "none"
  end
  return table.concat(warnings, "\n")
end

-- Public function name -> body; each body is wrapped by `guarded` when installed.
local FUNCTION_BODIES = {
  zoom_in = zoom_in_result, zoom_out = zoom_out_result, set_zoom = set_zoom_result,
  toggle = toggle_result, reset = reset_result, filter = filter_result,
  reload = reload_result, preview = preview_result, preview_end = preview_end_result,
  warnings = warnings_result,
}

-- status_text — build the C6 key=value status.
-- Args:    session table
-- Returns: string of `key=value` lines
local function status_text(session)
  local host, store = session.host, session.store
  local effective = engine.effective_settings(session)
  local resolved = session.tracking or tracking.resolve(effective, false)
  local hyprland_version = select(2, pcall(host.hl.version))
  -- Report what Hyprland really holds, not just what we asked for.
  local applied_delay = select(2, pcall(host.hl.get_config, "binds.scroll_event_delay"))
  local fields = {
    { "engine", "lua" }, { "version", M.VERSION }, { "hyprland", tostring(hyprland_version) },
    { "zoom", string.format("%.2f", store.zoom) },
    { "saved_zoom", string.format("%.2f", store.saved_zoom or effective.ZOOM_RESET) },
    { "tracking", resolved.configured }, { "tracking_effective", resolved.effective },
    { "edge_margin", string.format("%.2f", resolved.edge_margin) },
    { "plugin", tracking.plugin_loaded(host) and "loaded" or "missing" },
    { "filter", engine.current_filter_name(session) },
    { "filter_active", engine.current_filter_active(session) and "on" or "off" },
    { "filter_shader", store.shader_path or "none" },
    { "scroll_event_delay_ms", tostring(type(applied_delay) == "number"
      and math.tointeger(applied_delay) or effective.SCROLL_EVENT_DELAY_MS) },
  }
  local lines = {}
  for _, field in ipairs(fields) do
    -- One key=value line per field, in contract order.
    lines[#lines + 1] = field[1] .. "=" .. field[2]
  end
  return table.concat(lines, "\n")
end

-- define_actions — create the bind callbacks (one notch / one press each).
-- Args:    api table (the public functions)
-- Returns: map action name -> function
local function define_actions(api)
  -- Binds call the public functions so every bind goes through the same guarded path.
  return {
    zoom_in = function() api.zoom_in(1) end,
    zoom_out = function() api.zoom_out(1) end,
    toggle = function() api.toggle() end,
    reset = function() api.reset() end,
    filter_toggle = function() api.filter("toggle") end,
  }
end

-- define_functions — attach the guarded C3 functions to the api table.
-- Args:    api table; session table
-- Returns: nothing
local function define_functions(api, session)
  for name, body in pairs(FUNCTION_BODIES) do
    api[name] = guarded(session, name, body)
  end
end

-- M.install — build the session, define the API on `api` and start the engine.
-- Args:    api table (the global HyprZoom, reused across re-runs); host adapter;
--          layout {schema_path, shader_directory}
-- Returns: the api table
function M.install(api, host, layout)
  -- The persistent store survives re-running the entry file inside one Lua state.
  api._store = api._store or {}
  local session = engine.new_session(host, layout, api._store)
  api._session = session
  define_functions(api, session)
  -- status works even when the engine failed to start, so zoomctl doctor can explain why.
  api.status = function()
    if not session.ready then
      return "engine=lua\nerror=" .. tostring(session.start_problem)
    end
    local succeeded, text = pcall(status_text, session)
    -- A failing status must still answer with a string.
    return succeeded and text or ("error=" .. util.printable_excerpt(text, 120))
  end
  session.actions = define_actions(api)
  local started, problem = engine.start(session)
  session.ready, session.start_problem = started == true, problem
  -- Tell the user once why the engine is inert; its API keeps answering with errors.
  if not started then
    engine.report_problem(session, "engine not started: " .. tostring(problem))
  end
  return api
end

return M
