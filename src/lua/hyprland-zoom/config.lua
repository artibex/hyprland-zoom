-- config.lua — layered configuration (contract C2): schema default <- system <- user file.
-- Invalid input produces warnings and falls back to the next layer; it never aborts the engine.

-- The module table returned to callers.
local M = {}

-- Helpers and the schema validator.
local util = require("hyprland-zoom.util")
local schema_module = require("hyprland-zoom.schema")

-- Default location of the system-wide config file.
local DEFAULT_SYSTEM_CONFIG = "/etc/zoomctl.conf"
-- The 0.1 key that chose between centring and edge tracking.
local LEGACY_CENTER_KEY = "ZOOM_CENTER_CURSOR"

-- non_empty_env — read an environment variable, treating "" as unset.
-- Args:    host platform adapter; name variable name
-- Returns: the value, or nil when unset or empty
local function non_empty_env(host, name)
  -- An empty override must not win over the default path.
  local value = host.getenv(name)
  if value == nil or value == "" then
    return nil
  end
  return value
end

-- M.config_paths — locate the system and user config files.
-- Args:    host platform adapter
-- Returns: system path string, user path string (nil when HOME is unknown)
function M.config_paths(host)
  -- Explicit overrides first: tests and packaging rely on them.
  local system_path = non_empty_env(host, "ZOOMCTL_SYSTEM_CONFIG") or DEFAULT_SYSTEM_CONFIG
  local user_path = non_empty_env(host, "ZOOMCTL_USER_CONFIG")
  if user_path then
    return system_path, user_path
  end
  -- Otherwise ${XDG_CONFIG_HOME:-$HOME/.config}/zoomctl/zoom.conf.
  local config_home = non_empty_env(host, "XDG_CONFIG_HOME")
  local home = non_empty_env(host, "HOME")
  if not config_home and home then
    config_home = home .. "/.config"
  end
  return system_path, config_home and (config_home .. "/zoomctl/zoom.conf") or nil
end

-- parse_layer_text — read KEY=VALUE lines into a raw map.
-- Args:    text file content
-- Returns: map KEY -> raw string (later lines win)
local function parse_layer_text(text)
  local raw = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    -- Comment lines and blanks carry no setting.
    local content = util.trim(line)
    if content ~= "" and content:sub(1, 1) ~= "#" then
      local key, value = content:match("^([%w_]+)%s*=%s*(.-)$")
      if key then
        -- Strip one pair of matching quotes so `KEY="value"` works too.
        local quote = value:match("^([\"'])")
        if quote and value:sub(-1) == quote and #value >= 2 then
          value = value:sub(2, -2)
        end
        raw[key] = util.trim(value)
      end
    end
  end
  return raw
end

-- upgrade_legacy_layer — translate a 0.1 layer to 0.2 keys (contract C2).
-- Args:    raw map for ONE layer (modified in place)
-- Returns: nothing
local function upgrade_legacy_layer(raw)
  -- Only a layer that mentions the 0.1 key is a 0.1-format layer.
  local legacy_center = raw[LEGACY_CENTER_KEY]
  if legacy_center == nil then
    return
  end
  -- 1 -> centred, anything falsy -> edge; an explicit new key always wins.
  if raw.ZOOM_TRACKING == nil then
    local wants_center = schema_module.coerce({ type = "bool" }, legacy_center)
    raw.ZOOM_TRACKING = wants_center and "centered" or "edge"
  end
  -- 0.1 steps were additive; keep their meaning unless the layer says otherwise.
  if raw.ZOOM_STEP_MODE == nil then
    raw.ZOOM_STEP_MODE = "add"
  end
  raw[LEGACY_CENTER_KEY] = nil
end

-- apply_layer — copy the valid values of one layer over the current settings.
-- Args:    schema parsed schema; settings map (modified); raw layer map;
--          label string for messages; warnings array (appended)
-- Returns: nothing
local function apply_layer(schema, settings, raw, label, warnings)
  -- Iterate in sorted order so warnings are deterministic.
  for _, key in ipairs(util.sorted_keys(raw)) do
    local entry = schema.by_key[key]
    if not entry then
      warnings[#warnings + 1] = label .. ": unknown key " .. util.printable_excerpt(key)
    else
      -- An invalid value is skipped, so the earlier layer's value stays in force.
      local value, problem = schema_module.coerce(entry, raw[key])
      if value == nil then
        warnings[#warnings + 1] = string.format("%s: invalid %s: %s", label, key, problem)
      else
        settings[key] = value
      end
    end
  end
end

-- enforce_zoom_bounds — repair ZOOM_MIN <= ZOOM_RESET <= ZOOM_MAX (cross-field rule C1).
-- Args:    schema parsed schema; settings map (modified); warnings array (appended)
-- Returns: nothing
function M.enforce_zoom_bounds(schema, settings, warnings)
  -- An inverted range cannot be repaired sensibly: restore both defaults.
  if settings.ZOOM_MIN > settings.ZOOM_MAX then
    warnings[#warnings + 1] = "ZOOM_MIN is above ZOOM_MAX; using the defaults for both"
    settings.ZOOM_MIN = schema.by_key.ZOOM_MIN.default
    settings.ZOOM_MAX = schema.by_key.ZOOM_MAX.default
  end
  -- The reset level must lie inside the range; pull it in rather than refuse.
  local bounded_reset = util.clamp(settings.ZOOM_RESET, settings.ZOOM_MIN, settings.ZOOM_MAX)
  if bounded_reset ~= settings.ZOOM_RESET then
    warnings[#warnings + 1] = "ZOOM_RESET is outside ZOOM_MIN..ZOOM_MAX; clamped"
    settings.ZOOM_RESET = bounded_reset
  end
end

-- load_layer — read and parse one config file.
-- Args:    host platform adapter; path file path or nil
-- Returns: raw map, or nil when the file is missing
local function load_layer(host, path)
  -- A missing file is normal (fresh install); no warning.
  local text = path and host.read_file(path)
  if not text then
    return nil
  end
  local raw = parse_layer_text(text)
  upgrade_legacy_layer(raw)
  return raw
end

-- M.load — compute the effective settings.
-- Args:    host platform adapter; schema parsed schema
-- Returns: settings map KEY -> typed value; warnings array of strings
function M.load(host, schema)
  -- Start from the schema defaults, then overlay system and user layers.
  local settings = schema_module.defaults(schema)
  local warnings = {}
  local system_path, user_path = M.config_paths(host)
  for _, layer in ipairs({ { "system", system_path }, { "user", user_path } }) do
    local raw = load_layer(host, layer[2])
    if raw then
      apply_layer(schema, settings, raw, layer[1] .. " config", warnings)
    end
  end
  M.enforce_zoom_bounds(schema, settings, warnings)
  return settings, warnings
end

-- M.with_overrides — layer live preview overrides over loaded settings.
-- Args:    schema parsed schema; settings loaded settings (not modified);
--          overrides map KEY -> boolean, number or string
-- Returns: new settings map; or nil, error text when any override is invalid
function M.with_overrides(schema, settings, overrides)
  -- Work on a copy so a rejected preview leaves everything untouched.
  local merged = {}
  for key, value in pairs(settings) do
    merged[key] = value
  end
  for _, key in ipairs(util.sorted_keys(overrides)) do
    local entry = schema.by_key[key]
    if not entry then
      return nil, "unknown setting " .. util.printable_excerpt(key)
    end
    -- Values arrive as Lua values; render to text so one validator handles everything.
    local value, problem = schema_module.coerce(entry, util.to_raw_value(overrides[key]))
    if value == nil then
      return nil, string.format("invalid %s: %s", key, problem)
    end
    merged[key] = value
  end
  M.enforce_zoom_bounds(schema, merged, {})
  return merged
end

return M
