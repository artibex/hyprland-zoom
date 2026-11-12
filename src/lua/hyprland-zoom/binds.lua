-- binds.lua — key and mouse binds (contract C7) built from the settings, plus Omarchy takeover.
-- `plan` is pure (testable without Hyprland); `apply` talks to `hl`. Binds are Lua functions, so a
-- scroll notch is handled inside the compositor without spawning a process (E1).

-- The module table returned to callers.
local M = {}

-- Helpers shared by all engine modules.
local util = require("hyprland-zoom.util")

-- Application id and Wayland class of the settings window (contract C8).
M.SETTINGS_APP_ID = "io.github.artibex.HyprlandZoom"
-- Command the settings key starts.
local SETTINGS_COMMAND = "hyprland-zoom-settings"
-- What `tostring` says about a bind handle whose bind was removed by someone else (0.56.2).
local EXPIRED_HANDLE_TEXT = "HL.Keybind(expired)"
-- Hyprland's name for the middle mouse button.
local MIDDLE_MOUSE_KEY = "mouse:274"
-- Modifiers of Omarchy's group-cycling scroll binds that collide with the default scroll zoom.
local OMARCHY_SCROLL_MODIFIERS = { "SUPER", "ALT" }
-- Omarchy's own zoom binds that are re-routed to the engine (key, action).
local OMARCHY_ZOOM_BINDS = {
  { keys = "SUPER + CTRL + Z", action = "zoom_in", description = "Zoom in" },
  { keys = "SUPER + CTRL + ALT + Z", action = "reset", description = "Reset zoom" },
}
-- Key settings: schema key -> action name, repeat flag and menu description.
local KEY_BINDS = {
  { setting = "BIND_KEY_IN", action = "zoom_in", repeating = true, description = "Zoom in" },
  { setting = "BIND_KEY_OUT", action = "zoom_out", repeating = true, description = "Zoom out" },
  { setting = "BIND_KEY_TOGGLE", action = "toggle", description = "Toggle zoom" },
  { setting = "BIND_KEY_FILTER", action = "filter_toggle", description = "Toggle color filter" },
  { setting = "BIND_KEY_SETTINGS", action = "open_settings", description = "Open settings" },
}

-- normalize_chord — make a chord string comparable (case and spaces ignored, like Hyprland).
-- Args:    keys string such as "SUPER + ALT + I"
-- Returns: lower-case string without spaces
local function normalize_chord(keys)
  -- Hyprland's own unbind matching ignores both.
  local compact = keys:gsub(" ", "")
  return compact:lower()
end

-- same_modifiers — compare a modifier array with another (both canonical order).
-- Args:    first array; second array
-- Returns: true when equal
local function same_modifiers(first, second)
  -- Canonical order means element-wise comparison is enough.
  -- Different lengths cannot be equal.
  if #first ~= #second then
    return false
  end
  for index, name in ipairs(first) do
    -- The first differing element decides.
    if second[index] ~= name then
      return false
    end
  end
  return true
end

-- add_bind — append a bind unless its chord is already taken.
-- Args:    plan table; seen set of normalized chords; bind table
-- Returns: nothing
local function add_bind(plan, seen, bind)
  -- Two actions on one chord would shadow each other; keep the first and say so.
  local chord = normalize_chord(bind.keys)
  if seen[chord] then
    plan.warnings[#plan.warnings + 1] = "duplicate shortcut " .. bind.keys .. " ignored for "
      .. bind.action
    -- A repeated chord is skipped; the warning above explains why.
    return
  end
  seen[chord] = true
  plan.binds[#plan.binds + 1] = bind
end

-- add_scroll_and_mouse_binds — the wheel and middle-click binds.
-- Args:    plan table; seen set; settings effective settings; modifier_text string
-- Returns: nothing
local function add_scroll_and_mouse_binds(plan, seen, settings, modifier_text)
  -- Default `down-in`: wheel towards the user (mouse_down) zooms in, as in 0.1 (C7).
  if settings.BIND_SCROLL then
    local zooms_in_on_down = settings.BIND_SCROLL_DIRECTION == "down-in"
    add_bind(plan, seen, { keys = modifier_text .. " + mouse_down",
      action = zooms_in_on_down and "zoom_in" or "zoom_out",
      description = zooms_in_on_down and "Zoom in" or "Zoom out" })
    -- The opposite wheel direction does the opposite zoom.
    add_bind(plan, seen, { keys = modifier_text .. " + mouse_up",
      action = zooms_in_on_down and "zoom_out" or "zoom_in",
      description = zooms_in_on_down and "Zoom out" or "Zoom in" })
  end
  -- Middle click toggles the zoom (C7).
  if settings.BIND_MOUSE_TOGGLE then
    add_bind(plan, seen, { keys = modifier_text .. " + " .. MIDDLE_MOUSE_KEY, action = "toggle",
      description = "Toggle zoom" })
  end
end

-- plan_takeover — add the Omarchy collision handling to a plan.
-- Args:    plan table; seen set; settings effective settings; modifier_text string
-- Returns: nothing
local function plan_takeover(plan, seen, settings, modifier_text)
  -- Free the scroll chords from Omarchy's group cycling when we use the same modifiers.
  if settings.BIND_SCROLL and same_modifiers(settings.BIND_MODIFIERS, OMARCHY_SCROLL_MODIFIERS) then
    plan.unbind[#plan.unbind + 1] = modifier_text .. " + mouse_up"
    plan.unbind[#plan.unbind + 1] = modifier_text .. " + mouse_down"
  end
  -- Re-route Omarchy's own zoom keys so two engines never fight over the zoom factor.
  for _, omarchy_bind in ipairs(OMARCHY_ZOOM_BINDS) do
    plan.unbind[#plan.unbind + 1] = omarchy_bind.keys
    add_bind(plan, seen, { keys = omarchy_bind.keys, action = omarchy_bind.action,
      description = omarchy_bind.description })
  end
end

-- M.plan — compute every bind the engine wants (pure).
-- Args:    settings effective settings; omarchy_present boolean
-- Returns: plan {binds = array of {keys, action, repeating, description},
--          unbind = array of chords to free first, warnings = array of strings}
function M.plan(settings, omarchy_present)
  local plan = { binds = {}, unbind = {}, warnings = {} }
  local seen = {}
  local modifier_text = table.concat(settings.BIND_MODIFIERS, " + ")
  add_scroll_and_mouse_binds(plan, seen, settings, modifier_text)
  -- Key binds: an empty key disables the bind.
  for _, spec in ipairs(KEY_BINDS) do
    local key = settings[spec.setting]
    if key ~= "" then
      add_bind(plan, seen, { keys = modifier_text .. " + " .. key, action = spec.action,
        repeating = spec.repeating, description = spec.description })
    end
  end
  -- Takeover only makes sense on Omarchy and only when the user wants it (E11).
  if settings.BIND_TAKEOVER_OMARCHY and omarchy_present then
    plan_takeover(plan, seen, settings, modifier_text)
  end
  return plan
end

-- M.signature — fingerprint a plan so unchanged plans are not re-applied.
-- Args:    plan table from M.plan
-- Returns: string identical for equal plans
function M.signature(plan)
  -- Chords, actions and flags fully describe the bind set.
  local parts = {}
  for _, bind in ipairs(plan.binds) do
    parts[#parts + 1] = bind.keys .. "=" .. bind.action .. (bind.repeating and "*" or "")
  end
  parts[#parts + 1] = "unbind:" .. table.concat(plan.unbind, ",")
  -- One comparable string per plan.
  return table.concat(parts, ";")
end

-- is_expired — test whether Hyprland already dropped the bind behind a handle.
-- Args:    handle value returned by hl.bind
-- Returns: true when the handle is expired or not a handle at all
-- Notes:   tostring() is the only method that is safe on an expired handle in 0.56.2; every
--          other call, remove() included, dereferences a null pointer and kills Hyprland.
local function is_expired(handle)
  return handle == nil or tostring(handle) == EXPIRED_HANDLE_TEXT
end

-- remove_previous_binds — drop the handles of an earlier apply.
-- Args:    store persistent table holding `bind_handles`
-- Returns: nothing
-- Notes:   Anything that unbinds one of our chords (user rebind, another script, unbind all)
--          expires the handle; calling remove() on it would crash the compositor.
local function remove_previous_binds(store)
  for _, handle in ipairs(store.bind_handles or {}) do
    -- Only live handles may be removed; an expired one has nothing left to remove.
    if not is_expired(handle) then
      pcall(handle.remove, handle)
    end
  end
  store.bind_handles = {}
end

-- build_action — turn an action name into what hl.bind accepts.
-- Args:    host platform adapter; name string; actions table of name -> function
-- Returns: a Lua function or a dispatcher object; nil for an unknown action
local function build_action(host, name, actions)
  -- The settings key starts an external program, so it uses a dispatcher.
  if name == "open_settings" then
    return host.hl.dsp.exec_cmd(SETTINGS_COMMAND)
  end
  return actions[name]
end

-- M.apply — install a plan: free chords, bind, remember the handles.
-- Args:    host platform adapter; plan table; actions table name -> function;
--          store persistent table (bind_handles)
-- Returns: array of problem strings (empty when everything was bound)
function M.apply(host, plan, actions, store)
  local problems = {}
  remove_previous_binds(store)
  -- Unbinding Omarchy's chords must happen BEFORE our binds on the same chords.
  for _, chord in ipairs(plan.unbind) do
    local freed, problem = pcall(host.hl.unbind, chord)
    if not freed then
      problems[#problems + 1] = "unbind " .. chord .. ": " .. tostring(problem)
    end
  end
  -- Bind every planned chord; one failure must not stop the others.
  for _, bind in ipairs(plan.binds) do
    local action = build_action(host, bind.action, actions)
    local options = { description = "hyprland-zoom: " .. bind.description,
      repeating = bind.repeating or nil }
    local bound, handle = pcall(host.hl.bind, bind.keys, action, options)
    -- Keep the handle so the next apply can remove exactly our binds.
    if bound then
      store.bind_handles[#store.bind_handles + 1] = handle
    else
      problems[#problems + 1] = "bind " .. bind.keys .. ": " .. util.printable_excerpt(handle, 80)
    end
  end
  return problems
end

-- M.ensure_settings_window_rule — float and centre the settings window (C8).
-- Args:    host platform adapter; store persistent table (window_rule_added)
-- Returns: nothing
function M.ensure_settings_window_rule(host, store)
  -- One rule per Lua state is enough; the rule name makes re-registration idempotent anyway.
  if store.window_rule_added then
    return
  end
  local added = pcall(host.hl.window_rule, {
    name = "hyprland-zoom-settings",
    match = { class = "^" .. M.SETTINGS_APP_ID:gsub("%.", "\\.") .. "$" },
    float = true,
    center = true,
  })
  store.window_rule_added = added
end

return M
