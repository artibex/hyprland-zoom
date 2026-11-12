-- engine.lua — the runtime session: settings, persistent store and all state-changing operations.
-- api.lua exposes these as the global HyprZoom; only report_problem and filter_action build
-- user-visible text, everything else returns values.
-- All functions take the session explicitly (params in, results out; no module-level state).

-- The module table returned to callers.
local M = {}

-- Engine modules.
local util = require("hyprland-zoom.util")
local options = require("hyprland-zoom.options")
local schema_module = require("hyprland-zoom.schema")
-- Config files and the persistent state file.
local config = require("hyprland-zoom.config")
local state = require("hyprland-zoom.state")
-- Zoom step maths and Hyprland zoom options.
local zoom = require("hyprland-zoom.zoom")
local tracking = require("hyprland-zoom.tracking")
local filter = require("hyprland-zoom.filter")
local binds = require("hyprland-zoom.binds")
-- Foreign-bind detection (reads other tools' bind files once).
local collisions = require("hyprland-zoom.collisions")

-- A preview that is not refreshed for this many seconds ends itself (UI crashed or closed).
M.PREVIEW_TIMEOUT_SECONDS = 300
-- Zoom of an unzoomed screen; the persisted state of a fresh session starts here.
local UNZOOMED = 1.0
-- Hyprland's animation speed unit: a `speed` of 1 lasts this many milliseconds.
local ANIMATION_UNIT_MS = 100
-- Extra wait after the zoom-out animation before the filter is released.
local FILTER_RELEASE_MARGIN_MS = 100

-- M.new_session — create the session table.
-- Args:    host platform adapter; layout {schema_path, shader_directory}; store persistent table
-- Returns: session table
function M.new_session(host, layout, store)
  -- `store` outlives re-runs of the entry file inside one Lua state; everything else is rebuilt.
  local session = { host = host, layout = layout, store = store, warnings = {},
    bind_warnings = {}, overrides = nil, state_directory = state.directory(host), actions = {} }
  -- Event handlers registered once per Lua state find the newest session through this getter.
  store.current_session = function()
    return session
  end
  return session
end

-- report_problem — log a problem and notify the user once per distinct message.
-- Args:    session table; text string
-- Returns: nothing
local function report_problem(session, text)
  -- Logging is cheap; notifications are rate-limited by comparing with the last one.
  session.host.log(text)
  if session.store.last_problem ~= text then
    session.store.last_problem = text
    session.host.notify("hyprland-zoom: " .. text)
  end
end
-- Exported so api.lua reports through the same path.
M.report_problem = report_problem

-- effective_settings — the settings that are in force right now (saved config + preview).
-- Args:    session table
-- Returns: settings table
function M.effective_settings(session)
  -- Without a preview the saved settings are used directly.
  if not session.overrides then
    return session.settings
  end
  return session.effective
end

-- M.all_warnings — the config warnings plus the current bind warnings.
-- Args:    session table
-- Returns: array of strings (a new array; the session's lists are not exposed)
function M.all_warnings(session)
  local all = {}
  -- Config warnings change only on reload; bind warnings are rebuilt on every apply (R-P1a-06).
  for _, list in ipairs({ session.warnings, session.bind_warnings }) do
    for _, warning in ipairs(list) do
      all[#all + 1] = warning
    end
  end
  return all
end

-- load_settings — read the schema and the config files into the session.
-- Args:    session table
-- Returns: true; or nil, error text (the engine cannot run without a schema)
local function load_settings(session)
  local host = session.host
  local schema_text = host.read_file(session.layout.schema_path)
  if not schema_text then
    return nil, "settings schema not found at " .. tostring(session.layout.schema_path)
  end
  -- A broken schema makes the engine inert, never crashes Hyprland.
  local schema, problem = schema_module.parse(schema_text)
  if not schema then
    return nil, problem
  end
  session.schema = schema
  -- Config problems become warnings; the engine always gets usable settings.
  session.settings, session.warnings = config.load(host, schema)
  return true
end

-- recompute_effective — rebuild the preview-merged settings after any change.
-- Args:    session table
-- Returns: nothing
local function recompute_effective(session)
  -- A rejected override set (config changed under a running preview) ends the preview.
  if session.overrides then
    local merged = config.with_overrides(session.schema, session.settings, session.overrides)
    if merged then
      session.effective = merged
    else
      -- Drop the preview rather than keep half-valid overrides.
      session.overrides = nil
    end
  end
end

-- M.current_filter_active — whether the filter is switched on (preview wins over runtime).
-- Args:    session table
-- Returns: boolean
function M.current_filter_active(session)
  -- A previewed FILTER_ACTIVE shows the effect without changing the persisted runtime flag.
  if session.overrides and session.overrides.FILTER_ACTIVE ~= nil then
    return session.effective.FILTER_ACTIVE
  end
  return session.store.filter_active == true
end

-- M.current_filter_name — the filter that would be applied (preview > runtime > config).
-- Args:    session table
-- Returns: filter name string
function M.current_filter_name(session)
  -- Same precedence as the active flag; the runtime name comes from HyprZoom.filter("<name>").
  local effective = M.effective_settings(session)
  if session.overrides and session.overrides.FILTER ~= nil then
    return effective.FILTER
  end
  return session.store.filter_name or effective.FILTER
end

-- persist — write the runtime state file.
-- Args:    session table
-- Returns: nothing
local function persist(session)
  -- No state directory (no runtime dir) simply means no persistence.
  if not session.state_directory then
    return
  end
  local store = session.store
  local written, problem = state.write(session.host, session.state_directory, {
    zoom = store.zoom, saved_zoom = store.saved_zoom, filter_active = store.filter_active,
    filter = store.filter_name, instance = session.host.getenv("HYPRLAND_INSTANCE_SIGNATURE"),
  })
  -- Persistence is best effort; tell the user once, keep running.
  if not written then
    report_problem(session, "cannot persist state: " .. tostring(problem))
  end
end

-- sync_filter — bring the screen shader in line with filter settings and zoom.
-- Args:    session table
-- Returns: result table from filter.sync ({applied = false} without a state directory)
function M.sync_filter(session)
  local effective = M.effective_settings(session)
  local wanted = filter.is_wanted(effective, M.current_filter_active(session), session.store.zoom)
  -- Shader files live in the state directory; without one the filter cannot work.
  if not session.state_directory then
    if wanted then
      report_problem(session, "filter: XDG_RUNTIME_DIR is not set, cannot write shaders")
    end
    return { applied = false }
  end
  -- filter.sync decides apply/restore and returns what it did.
  local result = filter.sync(session.host, {
    settings = effective,
    filter_name = M.current_filter_name(session),
    wanted = wanted,
    shader_directory = session.layout.shader_directory,
    state_directory = session.state_directory,
    store = session.store,
  })
  if result.problem then
    report_problem(session, "filter: " .. result.problem)
  end
  return result
end

-- sync_with_compositor — adopt a zoom level someone else set (another script, Omarchy).
-- Args:    session table
-- Returns: nothing
local function sync_with_compositor(session)
  -- Float32 storage differs from our double by ~1e-7; only real differences count.
  local applied = zoom.read_applied_level(session.host)
  if applied and not util.is_near(applied, session.store.zoom, zoom.SAME_LEVEL_TOLERANCE) then
    session.store.zoom = applied
  end
end

-- apply_options — push rendering, scroll delay (E2) and camera behaviour (E5) to Hyprland.
-- Args:    session table; effective settings table
-- Returns: array of problem strings
local function apply_options(session, effective)
  local host = session.host
  local problems = {}
  local _, rendering_problem = zoom.apply_rendering(host, effective)
  -- The scroll delay is THE fix for dropped notches (E2): Hyprland's default is 300 ms.
  local _, delay_problem = options.set(host,
    { binds = { scroll_event_delay = effective.SCROLL_EVENT_DELAY_MS } })
  local resolved, tracking_problem = tracking.apply(host, effective)
  session.tracking = resolved
  -- Remember which plugin state the options were applied for (see M.refresh_plugin_state).
  session.store.plugin_seen = resolved.plugin_loaded
  -- Collect only real problems, keeping the list free of nil holes.
  util.append_present(problems, rendering_problem)
  util.append_present(problems, delay_problem)
  util.append_present(problems, tracking_problem)
  return problems
end

-- apply_binds — (re)install the binds when the plan changed.
-- Args:    session table; effective settings table
-- Returns: array of problem strings
local function apply_binds(session, effective)
  local host, store = session.host, session.store
  -- Binds are rebuilt only when the plan changed (preview drags would rebind needlessly).
  local plan = binds.plan(effective, host.omarchy_present())
  local signature = binds.signature(plan)
  local problems = {}
  if store.bind_signature ~= signature then
    -- Rebinding is the expensive part, so it only happens on a changed plan.
    problems = binds.apply(host, plan, session.actions, store)
    store.bind_signature = signature
  end
  binds.ensure_settings_window_rule(host, store)
  -- Rebuilt from scratch on every apply, so repeated previews never pile up duplicates.
  session.bind_warnings = plan.warnings
  for _, warning in ipairs(collisions.find(plan, store.foreign_chords)) do
    session.bind_warnings[#session.bind_warnings + 1] = warning
  end
  return problems
end

-- M.apply_all — push every setting to Hyprland (also the reload path).
-- Args:    session table; adopt_live_zoom boolean (true: another tool's zoom wins over ours)
-- Returns: array of problem strings (empty when all went well)
-- Notes:   Only the first start after a Hyprland reload re-asserts the stored zoom (the reload
--          reset the compositor's value, E10); every later apply adopts the live value first.
function M.apply_all(session, adopt_live_zoom)
  local store = session.store
  -- Someone else may have changed the zoom since our last apply.
  if adopt_live_zoom then
    sync_with_compositor(session)
  end
  local effective = M.effective_settings(session)
  local problems = apply_options(session, effective)
  -- Option problems and bind problems are reported together.
  for _, problem in ipairs(apply_binds(session, effective)) do
    problems[#problems + 1] = problem
  end
  -- Re-assert the zoom level and the filter.
  zoom.apply_level(session.host, store.zoom)
  M.sync_filter(session)
  persist(session)
  for _, problem in ipairs(problems) do
    -- Each distinct problem is notified once.
    report_problem(session, problem)
  end
  return problems
end

-- restorable_state — read the persisted state when it belongs to this compositor session.
-- Args:    session table
-- Returns: table as from state.read, empty when absent or from another Hyprland instance
local function restorable_state(session)
  -- Without a state directory, or for a foreign instance, nothing is restored.
  if not session.state_directory then
    return {}
  end
  local saved = state.read(session.host, session.state_directory)
  local instance = session.host.getenv("HYPRLAND_INSTANCE_SIGNATURE")
  -- The file belongs to an earlier Hyprland session: keep only the toggle memory.
  if saved.instance ~= instance then
    return { saved_zoom = saved.saved_zoom }
  end
  return saved
end

-- initialise_runtime — fill the store on the first start of this Lua state.
-- Args:    session table
-- Returns: nothing
local function initialise_runtime(session)
  local store = session.store
  -- A re-run in the same Lua state keeps the values it already holds.
  if store.zoom ~= nil then
    return
  end
  local settings = session.settings
  local saved = restorable_state(session)
  -- The toggle memory is always restored; zoom and filter only when the user wants that (E10).
  store.saved_zoom = saved.saved_zoom
  store.zoom = UNZOOMED
  store.filter_active = settings.FILTER_ACTIVE
  if not settings.ZOOM_RESTORE_ON_RELOAD then
    -- Restore disabled: zoom stays at 1.0 and the filter keeps its configured default.
    return
  end
  if saved.zoom then
    store.zoom = zoom.clamp_level(saved.zoom, settings)
  end
  if saved.filter_active ~= nil then
    -- The runtime flag beats the config default.
    store.filter_active = saved.filter_active
  end
  -- The persisted filter name must still be a valid enum value.
  if saved.filter and util.contains(session.schema.by_key.FILTER.values, saved.filter) then
    store.filter_name = saved.filter
  end
end

-- adopt_config_changes — let a changed config value win over the runtime state.
-- Args:    session table
-- Returns: nothing
local function adopt_config_changes(session)
  -- Only a CHANGE of the file value overrides what the user toggled at runtime.
  local store, settings = session.store, session.settings
  if store.config_filter_active ~= nil and store.config_filter_active ~= settings.FILTER_ACTIVE then
    store.filter_active = settings.FILTER_ACTIVE
  end
  if store.config_filter ~= nil and store.config_filter ~= settings.FILTER then
    -- A changed config filter wins over a runtime selection.
    store.filter_name = nil
  end
  store.config_filter_active, store.config_filter = settings.FILTER_ACTIVE, settings.FILTER
end

-- M.start — first start (entry file load): settings, restore, apply, clean up.
-- Args:    session table
-- Returns: true; or nil, error text
function M.start(session)
  local loaded, problem = load_settings(session)
  if not loaded then
    return nil, problem
  end
  if session.state_directory then
    -- Create the private state directory (load time only: it spawns mkdir).
    session.host.ensure_dir(session.state_directory)
  end
  -- A store that already holds a zoom means the entry file ran again in the same Lua state.
  local is_rerun = session.store.zoom ~= nil
  initialise_runtime(session)
  adopt_config_changes(session)
  -- Foreign binds are read once, here at load time (it lists a directory); later applies reuse it.
  session.store.foreign_chords = collisions.scan(session.host)
  M.apply_all(session, is_rerun)
  M.watch_plugin_events(session)
  -- Stale shader files of earlier sessions go now; listing a directory is load-time only.
  if session.state_directory then
    filter.remove_stale_files(session.host, session.state_directory, session.store.shader_path)
  end
  return true
end

-- M.reload — re-read schema and config files and re-apply everything.
-- Args:    session table
-- Returns: true; or nil, error text
function M.reload(session)
  local loaded, problem = load_settings(session)
  if not loaded then
    return nil, problem
  end
  adopt_config_changes(session)
  -- Overrides must be re-validated against the new settings.
  recompute_effective(session)
  M.apply_all(session, true)
  return true
end

-- filter_release_delay — how long the filter stays after a zoom-out starts.
-- Args:    settings effective settings
-- Returns: milliseconds (the zoom-out animation plus a margin)
local function filter_release_delay(settings)
  return math.floor(settings.ZOOM_ANIMATION_SPEED * ANIMATION_UNIT_MS) + FILTER_RELEASE_MARGIN_MS
end

-- update_filter_for_zoom — switch the shader when a zoom change crosses the 1.0 boundary.
-- Args:    session table; was_wanted boolean; now_wanted boolean; effective settings
-- Returns: nothing
-- Notes:   Zooming in applies the shader at once. Zooming out keeps it until the animation has
--          finished (R-P1a-12); a newer zoom change cancels the pending release.
local function update_filter_for_zoom(session, was_wanted, now_wanted, effective)
  local store = session.store
  -- Every level change invalidates a release that is still waiting.
  store.filter_release_ticket = (store.filter_release_ticket or 0) + 1
  local ticket = store.filter_release_ticket
  if was_wanted == now_wanted then
    return
  end
  -- Zooming in (or a change that leaves the filter as it is) needs the shader right away.
  if now_wanted then
    M.sync_filter(session)
    return
  end
  -- Zooming out: wait for the animation, then release the shader.
  session.host.after(filter_release_delay(effective), function()
    -- Only the newest level change may release the filter.
    if store.filter_release_ticket == ticket then
      M.sync_filter(session)
    end
  end)
end

-- M.set_level — make a zoom level current (apply, filter boundary, persist).
-- Args:    session table; level number (already clamped)
-- Returns: the level
function M.set_level(session, level)
  local store = session.store
  local effective = M.effective_settings(session)
  local active = M.current_filter_active(session)
  local was_wanted = filter.is_wanted(effective, active, store.zoom)
  -- The Lua double is the authoritative zoom (Hyprland keeps float32).
  store.zoom = level
  local _, problem = zoom.apply_level(session.host, level)
  if problem then
    report_problem(session, "zoom: " .. problem)
  end
  -- Only the 1.0 boundary needs a shader change; skip the work on every other notch.
  update_filter_for_zoom(session, was_wanted, filter.is_wanted(effective, active, level),
    effective)
  persist(session)
  return level
end

-- M.change_zoom — zoom in or out by some notches.
-- Args:    session table; notches number > 0; direction 1 or -1
-- Returns: the new zoom level
function M.change_zoom(session, notches, direction)
  sync_with_compositor(session)
  local level = zoom.next_level(session.store.zoom, notches, direction,
    M.effective_settings(session))
  return M.set_level(session, level)
end

-- M.set_zoom — go to an absolute level (clamped to the configured range).
-- Args:    session table; level number; remember boolean or nil (nil and true remember)
-- Returns: the new zoom level
-- Notes:   remember=false is a transient zoom (a UI test zoom): saved_zoom stays untouched.
--          Otherwise the level that is left becomes the toggle's memory, like `reset` does.
function M.set_zoom(session, level, remember)
  sync_with_compositor(session)
  local store = session.store
  local effective = M.effective_settings(session)
  -- A transient zoom leaves the toggle's memory alone.
  if remember ~= false then
    store.saved_zoom = zoom.remember_target(store.zoom, store.saved_zoom, effective)
  end
  return M.set_level(session, zoom.clamp_level(level, effective))
end

-- M.toggle_zoom — switch between the reset level and the last level.
-- Args:    session table
-- Returns: the new zoom level
function M.toggle_zoom(session)
  sync_with_compositor(session)
  local store = session.store
  local level, saved = zoom.toggle_target(store.zoom, store.saved_zoom,
    M.effective_settings(session))
  store.saved_zoom = saved
  -- Apply, persist and handle the filter boundary.
  return M.set_level(session, level)
end

-- M.reset_zoom — go to ZOOM_RESET, remembering the level that is left.
-- Args:    session table
-- Returns: the new zoom level
function M.reset_zoom(session)
  sync_with_compositor(session)
  local store = session.store
  local level, saved = zoom.reset_target(store.zoom, store.saved_zoom,
    M.effective_settings(session))
  store.saved_zoom = saved
  -- Apply, persist and handle the filter boundary.
  return M.set_level(session, level)
end

-- M.filter_action — switch the filter on/off/toggle or select a filter by name.
-- Args:    session table; action string ("on", "off", "toggle" or a filter name)
-- Returns: true; or nil, error text
function M.filter_action(session, action)
  local store = session.store
  local names = session.schema.by_key.FILTER.values
  -- A runtime action replaces the matching preview override so it is not masked.
  local wanted_active = store.filter_active
  if action == "on" or action == "off" then
    wanted_active = (action == "on")
  elseif action == "toggle" then
    wanted_active = not M.current_filter_active(session)
  elseif util.contains(names, action) then
    -- Selecting a filter by name also switches it on.
    wanted_active = true
    store.filter_name = action
    if session.overrides then
      session.overrides.FILTER = nil
    end
  else
    -- The action text is untrusted; only a sanitised excerpt is echoed.
    return nil, "unknown filter action '" .. util.printable_excerpt(action) .. "'"
  end
  store.filter_active = wanted_active
  if session.overrides then
    session.overrides.FILTER_ACTIVE = nil
    -- Overrides must be re-validated against the new settings.
    recompute_effective(session)
  end
  M.sync_filter(session)
  persist(session)
  return true
end

-- schedule_preview_expiry — arrange for a forgotten preview to end itself.
-- Args:    session table
-- Returns: nothing
local function schedule_preview_expiry(session)
  local store, host = session.store, session.host
  store.preview_deadline = host.now() + M.PREVIEW_TIMEOUT_SECONDS
  -- At most one timer is pending; it re-arms itself while the preview is still fresh.
  if store.preview_timer_pending then
    return
  end
  store.preview_timer_pending = true
  host.after(M.PREVIEW_TIMEOUT_SECONDS * 1000, function()
    store.preview_timer_pending = false
    if session.overrides and host.now() >= store.preview_deadline then
      M.preview_end(session)
    elseif session.overrides then
      schedule_preview_expiry(session)
    end
  end)
end

-- M.preview — apply overrides live without writing anything.
-- Args:    session table; overrides map KEY -> boolean, number or string
-- Returns: true; or nil, error text (nothing changed on error)
function M.preview(session, overrides)
  if type(overrides) ~= "table" then
    return nil, "preview expects a table of KEY = value"
  end
  -- Merge with an earlier preview so the UI can send only what it just changed.
  local combined = {}
  for key, value in pairs(session.overrides or {}) do
    combined[key] = value
  end
  for key, value in pairs(overrides) do
    -- New values replace older previewed ones.
    combined[key] = value
  end
  local merged, problem = config.with_overrides(session.schema, session.settings, combined)
  if not merged then
    return nil, problem
  end
  -- Commit only after the whole override set validated.
  session.overrides, session.effective = combined, merged
  schedule_preview_expiry(session)
  M.apply_all(session, true)
  return true
end

-- M.preview_end — drop the preview and re-apply the saved configuration.
-- Args:    session table
-- Returns: true
function M.preview_end(session)
  -- Re-read the files too: the UI may have saved settings while previewing.
  session.overrides, session.effective = nil, nil
  load_settings(session)
  adopt_config_changes(session)
  -- The saved configuration is back in force; the preview itself is gone.
  M.apply_all(session, true)
  return true
end

-- M.refresh_plugin_state — re-apply everything when the plugin appeared or vanished.
-- Args:    session table
-- Returns: true when it re-applied, false when nothing changed
-- Notes:   Cheap when nothing changed: two reads. Fixes `plugin=missing` after a late plugin load
--          (R-P1a-03) even if no Lua-state restart follows.
function M.refresh_plugin_state(session)
  local loaded = tracking.plugin_loaded(session.host)
  -- Same plugin state as at the last apply: nothing to do.
  if loaded == session.store.plugin_seen then
    return false
  end
  M.apply_all(session, true)
  return true
end

-- on_plugin_event — body of the start/reload event handlers.
-- Args:    store persistent table (gives access to the newest session)
-- Returns: nothing
local function on_plugin_event(store)
  -- The newest session of this Lua state answers; an engine that failed to start stays inert.
  local session = store.current_session()
  if not session.ready then
    return
  end
  -- An event callback must never raise into Hyprland.
  local refreshed, problem = pcall(M.refresh_plugin_state, session)
  if not refreshed then
    report_problem(session, "plugin refresh: " .. tostring(problem))
  end
end

-- M.watch_plugin_events — register the events that can change the plugin state.
-- Args:    session table
-- Returns: nothing
-- Notes:   One registration per Lua state; the handlers look the newest session up in the store.
function M.watch_plugin_events(session)
  local store = session.store
  if store.events_registered or not session.host.hl.on then
    return
  end
  -- Registered once: a second entry run in the same Lua state must not stack handlers.
  store.events_registered = true
  for _, event in ipairs({ "hyprland.start", "config.reloaded" }) do
    pcall(session.host.hl.on, event, function()
      on_plugin_event(store)
    end)
  end
end

return M
