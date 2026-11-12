-- collisions.lua — find shortcuts the engine wants that another bind already uses (R-P1a-09).
-- Hyprland 0.56 has no Lua call that lists the existing binds, so the chords are read from the
-- Omarchy and user bind files as text, once at load time. Foreign binds are never removed here;
-- the only takeover is the explicit Omarchy set of binds.lua (E11).

-- The module table returned to callers.
local M = {}

-- Directory of Omarchy's own bind files, below its install path.
local OMARCHY_BINDINGS_SUBDIRECTORY = "/default/hypr/bindings"
-- Omarchy install path when the environment does not say otherwise.
local DEFAULT_OMARCHY_PATH = "/usr/share/omarchy"
-- The user's own bind file inside the Hyprland config directory.
local USER_BINDINGS_FILE = "/hypr/bindings.lua"
-- Spellings that mean the same modifier in a chord.
local MODIFIER_ALIASES = { control = "ctrl", mod4 = "super", win = "super", windows = "super" }

-- M.canonical_chord — make a chord comparable (modifier order, case and spacing ignored).
-- Args:    keys string such as "SUPER + CTRL + I"
-- Returns: string such as "ctrl+super+i"; nil when the text has no key
function M.canonical_chord(keys)
  local parts = {}
  for part in keys:gmatch("[^+]+") do
    -- Whitespace around a part is not significant; case is not either.
    local trimmed = part:match("^%s*(.-)%s*$"):lower()
    if trimmed ~= "" then
      parts[#parts + 1] = MODIFIER_ALIASES[trimmed] or trimmed
    end
  end
  if #parts == 0 then
    return nil
  end
  -- The last part is the key; the modifiers before it are sorted so their order is irrelevant.
  local key = table.remove(parts)
  table.sort(parts)
  parts[#parts + 1] = key
  return table.concat(parts, "+")
end

-- M.extract_chords — list the chords a bind file binds.
-- Args:    text string (the content of a Lua bind file)
-- Returns: array of canonical chord strings
-- Notes:   Matches calls such as hl.bind("..."), o.bind("..."), o.bind_toggle("...") and
--          o.rebind("..."); unbind calls free a chord and are skipped.
function M.extract_chords(text)
  local chords = {}
  -- A call name that contains "bind", then the first string argument.
  for name, keys in text:gmatch('%f[%w_]([%w_]*bind[%w_]*)%(%s*"([^"]+)"') do
    local chord = M.canonical_chord(keys)
    if chord and not name:find("unbind", 1, true) then
      chords[#chords + 1] = chord
    end
  end
  return chords
end

-- add_chords_of_file — record the chords of one file in the map.
-- Args:    host platform adapter; path string; label string (shown in warnings); map table
-- Returns: nothing
local function add_chords_of_file(host, path, label, map)
  local text = host.read_file(path)
  if not text then
    return
  end
  for _, chord in ipairs(M.extract_chords(text)) do
    -- The first source wins; one name is enough for the warning.
    map[chord] = map[chord] or label
  end
end

-- user_config_directory — the base of the user's config files.
-- Args:    host platform adapter
-- Returns: directory path string; nil when neither XDG_CONFIG_HOME nor HOME is set
local function user_config_directory(host)
  local configured = host.getenv("XDG_CONFIG_HOME")
  if configured and configured ~= "" then
    return configured
  end
  local home = host.getenv("HOME")
  return home and (home .. "/.config") or nil
end

-- M.scan — read the chords other tools bind.
-- Args:    host platform adapter
-- Returns: map canonical chord -> short source label ("Omarchy bindings/tiling.lua")
-- Notes:   Lists a directory (spawns `ls`): call it at load time only, never from a callback.
function M.scan(host)
  local map = {}
  local omarchy_path = host.getenv("OMARCHY_PATH") or DEFAULT_OMARCHY_PATH
  local directory = omarchy_path .. OMARCHY_BINDINGS_SUBDIRECTORY
  for _, name in ipairs(host.list_dir(directory)) do
    -- Only Lua bind modules carry binds; other files are skipped.
    if name:match("%.lua$") then
      add_chords_of_file(host, directory .. "/" .. name, "Omarchy bindings/" .. name, map)
    end
  end
  local config_directory = user_config_directory(host)
  if config_directory then
    add_chords_of_file(host, config_directory .. USER_BINDINGS_FILE, "your hypr/bindings.lua", map)
  end
  return map
end

-- M.find — compare a bind plan with the known foreign chords.
-- Args:    plan table from binds.plan; foreign map from M.scan (nil is allowed)
-- Returns: array of warning strings, one per colliding engine shortcut
function M.find(plan, foreign)
  local warnings = {}
  -- Chords the plan frees on purpose (the Omarchy takeover) are not collisions.
  local taken_over = {}
  for _, keys in ipairs(plan.unbind) do
    taken_over[M.canonical_chord(keys)] = true
  end
  for _, bind in ipairs(plan.binds) do
    local chord = M.canonical_chord(bind.keys)
    local source = foreign and foreign[chord]
    if source and not taken_over[chord] then
      warnings[#warnings + 1] = "shortcut " .. bind.keys .. " is also bound in " .. source
        .. "; both actions run"
    end
  end
  return warnings
end

return M
