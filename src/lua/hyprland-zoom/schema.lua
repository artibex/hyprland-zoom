-- schema.lua — parse config/settings.schema (contract C1) and validate raw values against it.
-- The schema file is the only source of keys, types, defaults and ranges (decision E3).

-- The module table returned to callers.
local M = {}

-- Local helpers shared by all engine modules.
local util = require("hyprland-zoom.util")

-- Number of mandatory `|`-separated fields in a schema line (the help text may contain `|`).
local FIELD_COUNT = 7
-- Longest accepted key name; real Hyprland key names are far shorter.
local MAX_KEY_LENGTH = 32
-- Modifier names the engine accepts, in the canonical output order.
local MODIFIER_ORDER = { "SUPER", "CTRL", "ALT", "SHIFT" }
-- Alternative spellings that map onto the canonical modifier names.
local MODIFIER_ALIASES = { WIN = "SUPER", LOGO = "SUPER", META = "SUPER", CONTROL = "CTRL" }
-- Accepted spellings of booleans, lower-cased (canonical `on`/`off` plus input aliases).
local BOOLEAN_WORDS = {
  on = true, ["1"] = true, ["true"] = true, yes = true,
  off = false, ["0"] = false, ["false"] = false, no = false,
}

-- parse_range — read a `min..max` constraint.
-- Args:    constraint string such as "0.01..2.00" or "-0.50..0.50"
-- Returns: minimum number, maximum number; nil when the text is not a range
local function parse_range(constraint)
  -- Both bounds may be negative decimals; ".." separates them.
  local low, high = constraint:match("^(-?[%d%.]+)%.%.(-?[%d%.]+)$")
  if not low then
    return nil
  end
  return tonumber(low), tonumber(high)
end

-- build_entry — turn the fields of one schema line into an entry table.
-- Args:    fields array of 7+ strings (KEY..HELP)
-- Returns: entry table; or nil, error text
local function build_entry(fields)
  -- Trim every field so padding in the schema file never matters.
  local entry = {
    key = util.trim(fields[1]),
    type = util.trim(fields[2]),
    default_raw = util.trim(fields[3]),
    constraint = util.trim(fields[4]),
    group = util.trim(fields[5]),
    label = util.trim(fields[6]),
    -- The help text may legitimately contain "|"; rejoin the tail.
    help = util.trim(table.concat(fields, "|", 7)),
  }
  -- Numeric types need a range, enums need a value list.
  if entry.type == "float" or entry.type == "int" then
    entry.min, entry.max = parse_range(entry.constraint)
    if not entry.min then
      return nil, "bad range '" .. entry.constraint .. "' for " .. entry.key
    end
  elseif entry.type == "enum" then
    -- Enum values come from the constraint list.
    entry.values = util.split(entry.constraint, ",")
  end
  return entry
end

-- parse_float — strictly parse a decimal number (no hex, no exponent, no "nan").
-- Args:    text string
-- Returns: number; or nil when the text is not a plain decimal
local function parse_float(text)
  -- Only digits with an optional sign and one optional dot are accepted.
  if not (text:match("^[+-]?%d+%.?%d*$") or text:match("^[+-]?%.%d+$")) then
    return nil
  end
  return tonumber(text)
end

-- normalize_modifiers — validate and canonicalise a `mods` value.
-- Args:    text string such as "SUPER + ALT"
-- Returns: array of canonical modifier names; or nil, error text
local function normalize_modifiers(text)
  -- Collect the wanted modifiers as a set so duplicates collapse.
  local wanted = {}
  for _, part in ipairs(util.split(text, "+")) do
    -- Names are case-insensitive; aliases map to the canonical spelling.
    local name = util.trim(part):upper()
    name = MODIFIER_ALIASES[name] or name
    if not util.contains(MODIFIER_ORDER, name) then
      return nil, "unknown modifier '" .. util.printable_excerpt(part) .. "'"
    end
    -- A set, so duplicates collapse.
    wanted[name] = true
  end
  -- Emit in canonical order so equal sets always compare equal.
  local ordered = {}
  for _, name in ipairs(MODIFIER_ORDER) do
    if wanted[name] then
      ordered[#ordered + 1] = name
    end
  end
  -- A bind without modifiers would hijack plain scrolling and typing.
  if #ordered == 0 then
    return nil, "at least one modifier is required"
  end
  return ordered
end

-- is_valid_key_name — check a Hyprland key name before it reaches hl.bind.
-- Args:    text string
-- Returns: true for names like I, 0, F5, bracketleft, code:34, mouse:274
local function is_valid_key_name(text)
  -- Bound the length first so the pattern checks stay trivially cheap.
  if #text > MAX_KEY_LENGTH then
    return false
  end
  -- Word characters only, or the numeric code:/mouse: forms; no "+" and no spaces.
  return text:match("^[%w_]+$") ~= nil
    or text:match("^code:%d+$") ~= nil
    or text:match("^mouse:%d+$") ~= nil
end

-- coerce_number — validate a float or int value against the entry's range.
-- Args:    entry schema entry; text trimmed raw value
-- Returns: number (floats rounded to 2 decimals, ints integral); or nil, error text
local function coerce_number(entry, text)
  -- Ints must be plain digits; floats go through the strict decimal parser.
  local number
  if entry.type == "int" then
    number = text:match("^[+-]?%d+$") and math.tointeger(tonumber(text)) or nil
  else
    number = parse_float(text)
  end
  -- Report the offending text (sanitised) for the warning.
  if number == nil then
    return nil, "'" .. util.printable_excerpt(text) .. "' is not a number"
  end
  -- Round floats to the canonical two decimals before the range check.
  if entry.type == "float" then
    number = util.round(number, 2)
  end
  if number < entry.min or number > entry.max then
    return nil, string.format("%s is outside %s", util.printable_excerpt(text), entry.constraint)
  end
  -- Valid and within range.
  return number
end

-- coerce — validate one raw config value against its schema entry.
-- Args:    entry schema entry; raw string (will be trimmed)
-- Returns: typed value (number, boolean, string or modifier array); or nil, error text
function M.coerce(entry, raw)
  -- Work on the trimmed text; non-strings cannot be valid config values.
  if type(raw) ~= "string" then
    return nil, "value must be text"
  end
  local text = util.trim(raw)
  if entry.type == "float" or entry.type == "int" then
    -- Numbers share one validator.
    return coerce_number(entry, text)
  elseif entry.type == "bool" then
    local flag = BOOLEAN_WORDS[text:lower()]
    if flag == nil then
      return nil, "'" .. util.printable_excerpt(text) .. "' is not on/off"
    end
    -- Canonical boolean.
    return flag
  elseif entry.type == "enum" then
    local choice = text:lower()
    if util.contains(entry.values, choice) then
      return choice
    end
    -- List the allowed values so the user can fix the config.
    return nil, "'" .. util.printable_excerpt(text) .. "' is not one of " .. entry.constraint
  elseif entry.type == "key" then
    -- An empty key means "bind disabled".
    if text == "" or is_valid_key_name(text) then
      return text
    end
    return nil, "'" .. util.printable_excerpt(text) .. "' is not a valid key name"
  elseif entry.type == "mods" then
    return normalize_modifiers(text)
  end
  -- A schema type this engine does not know is a contract break.
  return nil, "unsupported schema type '" .. entry.type .. "'"
end

-- parse — parse the text of a schema file.
-- Args:    text the complete schema file content
-- Returns: schema table {entries = ordered array, by_key = map}; or nil, error text
function M.parse(text)
  -- Entries keep file order (the UI and `config --porcelain` depend on it).
  local schema = { entries = {}, by_key = {} }
  local line_number = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    line_number = line_number + 1
    -- Skip blank lines and comments.
    local content = util.trim(line)
    if content ~= "" and content:sub(1, 1) ~= "#" then
      local fields = util.split(content, "|")
      if #fields < FIELD_COUNT then
        -- Name the line so a broken schema is easy to fix.
        return nil, string.format("schema line %d: expected %d fields", line_number, FIELD_COUNT)
      end
      local entry, build_error = build_entry(fields)
      if not entry then
        return nil, string.format("schema line %d: %s", line_number, build_error)
      end
      -- The default must itself satisfy the entry's own constraint.
      local default_value, default_error = M.coerce(entry, entry.default_raw)
      if default_value == nil then
        return nil, string.format("schema default of %s: %s", entry.key, default_error)
      end
      entry.default = default_value
      -- Keep file order for the UI and porcelain output.
      schema.entries[#schema.entries + 1] = entry
      schema.by_key[entry.key] = entry
    end
  end
  return schema
end

-- defaults — collect the default value of every schema key.
-- Args:    schema parsed schema
-- Returns: map KEY -> typed default value
function M.defaults(schema)
  -- Copy so callers can mutate the result freely.
  local values = {}
  for _, entry in ipairs(schema.entries) do
    values[entry.key] = entry.default
  end
  return values
end

return M
