-- test_schema.lua — unit tests for schema parsing and value coercion (contract C1).

-- Framework and the module under test.
local T = require("framework")
local schema_module = require("hyprland-zoom.schema")

-- read_real_schema — load and parse the repository's own settings.schema.
-- Args:    none
-- Returns: parsed schema table
local function read_real_schema()
  -- The shipped schema must always parse; this doubles as a contract check.
  local handle = assert(io.open(T.repository_root .. "/config/settings.schema", "rb"))
  local text = handle:read("a")
  handle:close()
  return assert(schema_module.parse(text))
end

T.suite("schema")

T.case("the shipped schema parses and exposes known keys with typed defaults", function()
  -- Spot-check one key per type.
  local schema = read_real_schema()
  T.eq(schema.by_key.ZOOM_STEP.default, 0.10)
  T.eq(schema.by_key.ZOOM_STEP_MODE.default, "multiply")
  T.eq(schema.by_key.ZOOM_SMOOTH_IMAGES.default, true)
  T.eq(schema.by_key.SCROLL_EVENT_DELAY_MS.default, 0)
  T.eq(schema.by_key.BIND_MODIFIERS.default, { "SUPER", "ALT" })
  T.eq(schema.by_key.BIND_KEY_IN.default, "I")
  T.eq(schema.by_key.FILTER.values[2], "smart-invert")
end)

T.case("entries keep file order and carry group and label", function()
  -- The first key is ZOOM_STEP; the last is SCROLL_EVENT_DELAY_MS.
  local schema = read_real_schema()
  T.eq(schema.entries[1].key, "ZOOM_STEP")
  T.eq(schema.entries[#schema.entries].key, "SCROLL_EVENT_DELAY_MS")
  T.eq(schema.by_key.ZOOM_STEP.group, "zoom")
  T.eq(schema.by_key.ZOOM_STEP.label, "Zoom step")
end)

T.case("help text may contain the field separator", function()
  -- A pipe inside the help must not truncate or break the entry.
  local schema = assert(schema_module.parse("K|int|1|0..5|zoom|Label|help | more"))
  T.eq(schema.by_key.K.help, "help | more")
end)

T.case("malformed lines are reported with their line number", function()
  -- Too few fields.
  local schema, problem = schema_module.parse("# c\nK|int|1")
  T.eq(schema, nil)
  T.contains(problem, "line 2")
  -- A default outside its own range.
  local _, default_problem = schema_module.parse("K|int|9|0..5|zoom|L|h")
  T.contains(default_problem, "schema default of K")
end)

T.case("float coercion rounds to two decimals and enforces the range", function()
  -- In range, rounded; out of range; garbage (hex, exponent, nan are refused).
  local entry = read_real_schema().by_key.ZOOM_STEP
  T.eq(schema_module.coerce(entry, " 0.123 "), 0.12)
  T.eq(schema_module.coerce(entry, "2"), 2.0)
  T.eq(schema_module.coerce(entry, "2.01"), nil)
  T.eq(schema_module.coerce(entry, "0x10"), nil)
  T.eq(schema_module.coerce(entry, "1e1"), nil)
  T.eq(schema_module.coerce(entry, "nan"), nil)
  T.eq(schema_module.coerce(entry, ""), nil)
end)

T.case("negative ranges work (brightness)", function()
  -- FILTER_BRIGHTNESS allows -0.50..0.50.
  local entry = read_real_schema().by_key.FILTER_BRIGHTNESS
  T.eq(schema_module.coerce(entry, "-0.25"), -0.25)
  T.eq(schema_module.coerce(entry, "-0.51"), nil)
end)

T.case("int coercion accepts only plain digits inside the range", function()
  -- 300 is the upper bound of the scroll delay.
  local entry = read_real_schema().by_key.SCROLL_EVENT_DELAY_MS
  T.eq(schema_module.coerce(entry, "300"), 300)
  T.eq(schema_module.coerce(entry, "301"), nil)
  T.eq(schema_module.coerce(entry, "1.5"), nil)
  T.eq(math.type(schema_module.coerce(entry, "5")), "integer")
end)

T.case("bool accepts canonical spellings and aliases only", function()
  -- All documented aliases, case-insensitive.
  local entry = read_real_schema().by_key.ZOOM_SMOOTH_IMAGES
  for _, word in ipairs({ "on", "1", "true", "YES", "True" }) do
    T.eq(schema_module.coerce(entry, word), true, word)
  end
  for _, word in ipairs({ "off", "0", "false", "no" }) do
    T.eq(schema_module.coerce(entry, word), false, word)
  end
  T.eq(schema_module.coerce(entry, "maybe"), nil)
end)

T.case("enum is case-insensitive and rejects unknown names", function()
  -- Injection-looking text is simply not in the list.
  local entry = read_real_schema().by_key.FILTER
  T.eq(schema_module.coerce(entry, "Grayscale"), "grayscale")
  T.eq(schema_module.coerce(entry, "grayscale'); os.execute('x"), nil)
end)

T.case("key names are validated before they can reach hl.bind", function()
  -- Valid names, the disabled (empty) form and several malicious ones.
  local entry = read_real_schema().by_key.BIND_KEY_IN
  for _, name in ipairs({ "I", "0", "F5", "bracketleft", "code:34", "mouse:274", "" }) do
    T.eq(schema_module.coerce(entry, name), name, "'" .. name .. "'")
  end
  for _, name in ipairs({ "A + B", "a\nb", 'a"b', "x;y", string.rep("k", 40), "SUPER+I" }) do
    T.eq(schema_module.coerce(entry, name), nil, name)
  end
end)

T.case("modifiers are canonicalised, deduplicated and never empty", function()
  -- Order is SUPER, CTRL, ALT, SHIFT regardless of input order; aliases map.
  local entry = read_real_schema().by_key.BIND_MODIFIERS
  T.eq(schema_module.coerce(entry, "alt + super"), { "SUPER", "ALT" })
  T.eq(schema_module.coerce(entry, "Control + WIN + win"), { "SUPER", "CTRL" })
  T.eq(schema_module.coerce(entry, ""), nil)
  T.eq(schema_module.coerce(entry, "HYPER"), nil)
end)

T.case("non-string input is refused instead of raising", function()
  -- Overrides from Lua callers may carry any type.
  local entry = read_real_schema().by_key.ZOOM_STEP
  T.eq(schema_module.coerce(entry, 5), nil)
  T.eq(schema_module.coerce(entry, nil), nil)
end)

T.case("defaults returns a fresh map of all keys", function()
  -- Mutating the copy must not change the schema.
  local schema = read_real_schema()
  local values = schema_module.defaults(schema)
  values.ZOOM_STEP = 5
  T.eq(schema.by_key.ZOOM_STEP.default, 0.10)
  T.eq(values.FILTER, "smart-invert")
end)
