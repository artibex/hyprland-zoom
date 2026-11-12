-- util.lua — small pure helpers shared by every hyprland-zoom engine module.
-- Nothing here touches Hyprland, the filesystem or the environment.

-- The module table returned to callers.
local M = {}

-- Seed of the 64-bit FNV-1a hash (offset basis, wraps into a signed integer).
local FNV_OFFSET_BASIS = 0xcbf29ce484222325
-- Multiplier of the 64-bit FNV-1a hash.
local FNV_PRIME = 0x100000001b3

-- trim — strip leading and trailing whitespace from a string.
-- Args:    text string
-- Returns: the trimmed string
function M.trim(text)
  -- Drop leading whitespace first; gsub's count is discarded by the local.
  local without_leading = text:gsub("^%s+", "")
  -- Then drop trailing whitespace the same way.
  local trimmed = without_leading:gsub("%s+$", "")
  return trimmed
end

-- split — cut a string at every occurrence of a single-character separator.
-- Args:    text string; separator one-character string (taken literally)
-- Returns: array of the parts, "" kept for adjacent separators
function M.split(text, separator)
  -- Collect the parts in order; `start` is where the next part begins.
  local parts = {}
  local start = 1
  while true do
    -- Plain find (4th argument) keeps magic characters like "+" literal.
    local found = text:find(separator, start, true)
    if not found then
      break
    end
    -- Store the text before the separator and continue behind it.
    parts[#parts + 1] = text:sub(start, found - 1)
    start = found + #separator
  end
  -- The remainder after the last separator is the final part.
  parts[#parts + 1] = text:sub(start)
  return parts
end

-- round — round a number to a fixed count of decimal places.
-- Args:    value number; decimals integer >= 0
-- Returns: the rounded number (half away from zero)
function M.round(value, decimals)
  -- Scale up so the digit to keep becomes the units digit.
  local scale = 10 ^ decimals
  -- Round half away from zero so -0.5 and 0.5 are symmetric.
  local scaled = value * scale
  local rounded = scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
  return rounded / scale
end

-- clamp — limit a number to an inclusive range.
-- Args:    value number; lowest number; highest number
-- Returns: value, or the nearest bound when it lies outside
function M.clamp(value, lowest, highest)
  -- Check the lower bound first, then the upper one.
  if value < lowest then
    return lowest
  end
  if value > highest then
    return highest
  end
  return value
end

-- is_near — compare two numbers with a tolerance.
-- Args:    first number; second number; tolerance number (default 1e-6)
-- Returns: true when the numbers differ by at most the tolerance
function M.is_near(first, second, tolerance)
  -- Fall back to a tolerance far below float32 precision at zoom scale.
  return math.abs(first - second) <= (tolerance or 1e-6)
end

-- join_path — join a directory and a file name with exactly one slash.
-- Args:    directory string; name string
-- Returns: the joined path
function M.join_path(directory, name)
  -- Remove trailing slashes so "dir/" and "dir" give the same result.
  local clean_directory = directory:gsub("/+$", "")
  return clean_directory .. "/" .. name
end

-- fnv1a_hex — hash a string with 64-bit FNV-1a and render 12 hex digits.
-- Args:    text string
-- Returns: 12 lowercase hex characters (stable across runs and machines)
-- Notes:   Not cryptographic; it only names generated shader files by content.
function M.fnv1a_hex(text)
  -- Start from the standard offset basis.
  local hash = FNV_OFFSET_BASIS
  for index = 1, #text do
    -- XOR in the next byte, then multiply; integer overflow wraps in Lua 5.4+.
    hash = (hash ~ text:byte(index)) * FNV_PRIME
  end
  -- Keep the first 12 digits: 48 bits is plenty to tell shader files apart.
  return string.format("%016x", hash):sub(1, 12)
end

-- sorted_keys — list the keys of a table in sorted order.
-- Args:    map table with string keys
-- Returns: array of keys sorted ascending
function M.sorted_keys(map)
  -- Gather first, sort afterwards because pairs() order is undefined.
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- contains — test whether an array holds a value.
-- Args:    list array; wanted any value compared with ==
-- Returns: true when the value is present
function M.contains(list, wanted)
  -- Linear scan is fine for the tiny enum lists used here.
  for _, item in ipairs(list) do
    if item == wanted then
      return true
    end
  end
  return false
end

-- printable_excerpt — make an untrusted string safe to show in a message.
-- Args:    text any value; limit integer (default 40)
-- Returns: at most `limit` characters with everything outside [%w_.:+-] as "?"
function M.printable_excerpt(text, limit)
  -- Coerce first so numbers, nil and tables cannot raise inside error paths.
  local as_text = tostring(text)
  -- Replace control and exotic characters so logs and notifications stay clean.
  local cleaned = as_text:gsub("[^%w_%.:+%- ]", "?")
  return cleaned:sub(1, limit or 40)
end

-- to_raw_value — render a Lua value in the text form the config layer accepts.
-- Args:    value boolean, number or string
-- Returns: "on"/"off" for booleans, plain digits for numbers, strings unchanged
function M.to_raw_value(value)
  -- Booleans use the canonical schema spelling.
  if type(value) == "boolean" then
    return value and "on" or "off"
  end
  -- Integers print without a fraction, floats with four decimals.
  if math.type(value) == "integer" then
    return string.format("%d", value)
  end
  if type(value) == "number" then
    return string.format("%.4f", value)
  end
  return tostring(value)
end

return M
