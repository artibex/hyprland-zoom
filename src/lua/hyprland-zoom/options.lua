-- options.lua — set Hyprland options without ever producing a config error.
-- Hyprland's `hl.config` never raises on an unknown key: it records an error and shows the red
-- "config has errors" bar (R-P1a-01). Every key is therefore probed with `hl.get_config` first
-- (which returns nil for an unknown key) and only known keys are handed to `hl.config`.

-- The module table returned to callers.
local M = {}

-- flatten — turn a nested option table into dotted keys.
-- Args:    nested table such as {cursor = {zoom_factor = 2}}; prefix string or nil;
--          flat table receiving the pairs (created when nil)
-- Returns: map "cursor.zoom_factor" -> 2
local function flatten(nested, prefix, flat)
  flat = flat or {}
  for key, value in pairs(nested) do
    local dotted = prefix and (prefix .. "." .. key) or key
    -- Leaves are anything that is not a table; tables are walked recursively.
    if type(value) == "table" then
      flatten(value, dotted, flat)
    else
      flat[dotted] = value
    end
  end
  return flat
end

-- assign_path — store a value in a nested table under a dotted key.
-- Args:    nested table to extend; dotted string such as "plugin.hyprzoom.edge_margin"; value any
-- Returns: nothing
local function assign_path(nested, dotted, value)
  local cursor = nested
  local segments = {}
  for segment in dotted:gmatch("[^.]+") do
    segments[#segments + 1] = segment
  end
  -- Create the intermediate tables, then set the leaf.
  for index = 1, #segments - 1 do
    cursor[segments[index]] = cursor[segments[index]] or {}
    cursor = cursor[segments[index]]
  end
  cursor[segments[#segments]] = value
end

-- M.is_known — test whether Hyprland knows an option.
-- Args:    host platform adapter; key dotted option name
-- Returns: true when `hl.get_config` finds the option
function M.is_known(host, key)
  -- get_config returns nil plus a message for an unknown key; a failing call counts as unknown.
  local read_ok, value = pcall(host.hl.get_config, key)
  return read_ok and value ~= nil
end

-- known_subset — split a flat option map into the known options (nested) and unknown keys.
-- Args:    host platform adapter; flat map dotted key -> value
-- Returns: nested table of the known options; sorted array of the unknown keys
local function known_subset(host, flat)
  local known, unknown = {}, {}
  for key, value in pairs(flat) do
    if M.is_known(host, key) then
      assign_path(known, key, value)
    else
      unknown[#unknown + 1] = key
    end
  end
  -- Sorted so that the message is the same on every run.
  table.sort(unknown)
  return known, unknown
end

-- M.set — set options, skipping (and reporting) the ones Hyprland does not know.
-- Args:    host platform adapter; nested table such as {cursor = {zoom_factor = 2}}
-- Returns: true when everything was set; nil, problem text when a key was unknown or failed
-- Notes:   The known options are still applied when another one is unknown.
function M.set(host, nested)
  local known, unknown = known_subset(host, flatten(nested))
  local problems = {}
  if next(known) ~= nil then
    -- Protected: a raising host must not break a bind callback either.
    local applied, problem = pcall(host.hl.config, known)
    if not applied then
      problems[#problems + 1] = tostring(problem)
    end
  end
  if #unknown > 0 then
    problems[#problems + 1] = "unknown option " .. table.concat(unknown, ", ")
  end
  if #problems > 0 then
    return nil, table.concat(problems, "; ")
  end
  return true
end

return M
