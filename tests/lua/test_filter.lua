-- test_filter.lua — shader generation, content-hash naming, apply/restore of screen shaders.

-- Framework, fake host and the modules under test.
local T = require("framework")
local stub_host = require("stub_host")
local schema_module = require("hyprland-zoom.schema")
local filter = require("hyprland-zoom.filter")

-- Where the fake host sees the templates and the state directory.
local SHADER_DIRECTORY = "/share/shaders"
local STATE_DIRECTORY = "/run/state"

-- read_repository_file — read a file from the repository checkout.
-- Args:    relative path string
-- Returns: file content
local function read_repository_file(relative)
  -- Binary mode keeps the bytes exactly as stored.
  local handle = assert(io.open(T.repository_root .. "/" .. relative, "rb"))
  local text = handle:read("a")
  handle:close()
  return text
end

-- load_schema — parse the shipped schema.
-- Args:    none
-- Returns: parsed schema
local function load_schema()
  -- The enum list of FILTER drives which templates must exist.
  return assert(schema_module.parse(read_repository_file("config/settings.schema")))
end

-- filter_names — the filter names defined by the schema.
-- Args:    none
-- Returns: array of names
local function filter_names()
  -- Single source of truth (E3): never hard-code the list in a test.
  return load_schema().by_key.FILTER.values
end

-- new_host — fake host with all shader templates loaded and directories created.
-- Args:    options table passed to stub_host.new
-- Returns: host table
local function new_host(options)
  local host = stub_host.new(options)
  host.ensure_dir(SHADER_DIRECTORY)
  host.ensure_dir(STATE_DIRECTORY)
  -- Every filter template plus the skeleton and the shared CVD include.
  local names = { "base", "cvd-common" }
  for _, name in ipairs(filter_names()) do
    names[#names + 1] = "filter-" .. name
  end
  for _, name in ipairs(names) do
    host.files[SHADER_DIRECTORY .. "/" .. name .. ".glsl"] =
      read_repository_file("src/shaders/" .. name .. ".glsl")
  end
  return host
end

-- default_settings — settings with the schema defaults for the filter keys.
-- Args:    overrides table (optional)
-- Returns: settings table
local function default_settings(overrides)
  -- Defaults come from the schema, not from literals.
  local settings = schema_module.defaults(load_schema())
  for key, value in pairs(overrides or {}) do
    settings[key] = value
  end
  return settings
end

-- context_for — build the context table filter.sync expects.
-- Args:    settings table; wanted boolean; store table; name string (default smart-invert)
-- Returns: context table
local function context_for(settings, wanted, store, name)
  -- Mirrors what the api module passes.
  return { settings = settings, filter_name = name or "smart-invert", wanted = wanted,
    shader_directory = SHADER_DIRECTORY, state_directory = STATE_DIRECTORY, store = store }
end

T.suite("filter")

T.case("every schema filter has a template and generates a valid shader", function()
  -- Catches a schema enum value without a template (and vice versa a broken template).
  local host = new_host()
  for _, name in ipairs(filter_names()) do
    local text, problem = filter.generate(host, SHADER_DIRECTORY, name, default_settings())
    T.truthy(text, name .. ": " .. tostring(problem))
    T.eq(text:sub(1, 16), "#version 300 es\n", name)
    T.truthy(filter.validate(text), name)
  end
end)

T.case("constants are baked in and placeholders are gone", function()
  -- Distinctive values must appear as four-decimal literals.
  local host = new_host()
  local settings = default_settings({ FILTER_INTENSITY = 0.5, FILTER_CONTRAST = 1.75,
    FILTER_BRIGHTNESS = -0.25, FILTER_SATURATION = 0.2 })
  local text = filter.generate(host, SHADER_DIRECTORY, "grayscale", settings)
  T.contains(text, "const float FILTER_INTENSITY = 0.5000;")
  T.contains(text, "const float FILTER_CONTRAST = 1.7500;")
  T.contains(text, "const float FILTER_BRIGHTNESS = -0.2500;")
  T.contains(text, "const float FILTER_SATURATION = 0.2000;")
  T.truthy(not text:find("@", 1, true))
  T.contains(text, 'colour filter "grayscale"')
end)

T.case("CVD filters pull in the shared include exactly once", function()
  -- The daltonize helper must be present and not duplicated.
  local host = new_host()
  local text = filter.generate(host, SHADER_DIRECTORY, "protanopia", default_settings())
  local _, count = text:gsub("vec3 daltonize%(", "")
  T.eq(count, 1)
end)

T.case("a non-numeric or non-finite setting cannot reach the shader text", function()
  -- Injection attempt through a setting value and a NaN.
  local host = new_host()
  local injected = default_settings({ FILTER_INTENSITY = "1.0); evil(" })
  local text, problem = filter.generate(host, SHADER_DIRECTORY, "invert", injected)
  T.eq(text, nil)
  T.contains(problem, "not a number")
  local not_a_number, nan_problem = filter.generate(host, SHADER_DIRECTORY, "invert",
    default_settings({ FILTER_CONTRAST = 0 / 0 }))
  T.eq(not_a_number, nil)
  T.contains(nan_problem, "not a number")
end)

T.case("a missing template is reported, an odd filter name is refused", function()
  -- Broken install and a path-traversal-looking name.
  local host = new_host()
  host.files[SHADER_DIRECTORY .. "/filter-invert.glsl"] = nil
  local _, missing = filter.generate(host, SHADER_DIRECTORY, "invert", default_settings())
  T.contains(missing, "filter-invert.glsl")
  local _, odd = filter.generate(host, SHADER_DIRECTORY, "../etc/passwd", default_settings())
  T.contains(odd, "invalid template name")
end)

T.case("validate rejects missing version line, placeholders, control characters", function()
  -- Each rule on its own.
  T.truthy(filter.validate("#version 300 es\nvoid main() {}\n"))
  T.eq((filter.validate("// c\n#version 300 es\nvoid main() {}\n")), nil)
  T.eq((filter.validate("#version 300 es\nvoid main() {} @X@\n")), nil)
  T.eq((filter.validate("#version 300 es\nvoid main() {} \27\n")), nil)
  T.eq((filter.validate("#version 300 es\nno entry point\n")), nil)
end)

T.case("file names follow the content hash", function()
  -- Same settings: same name; any constant change: new name.
  local host = new_host()
  local first = filter.generate(host, SHADER_DIRECTORY, "invert", default_settings())
  local again = filter.generate(host, SHADER_DIRECTORY, "invert", default_settings())
  local changed = filter.generate(host, SHADER_DIRECTORY, "invert",
    default_settings({ FILTER_CONTRAST = 1.5 }))
  T.eq(filter.file_name(first), filter.file_name(again))
  T.truthy(filter.file_name(first) ~= filter.file_name(changed))
  T.truthy(filter.file_name(first):match("^filter%-%x+%.frag$"))
end)

T.case("is_wanted honours the active flag and the zoomed-only option at the 1.0 boundary", function()
  -- Off wins; zoomed-only needs a zoom above 1.0.
  local plain = default_settings()
  local zoomed_only = default_settings({ FILTER_ONLY_WHEN_ZOOMED = true })
  T.eq(filter.is_wanted(plain, false, 5), false)
  T.eq(filter.is_wanted(plain, true, 1.0), true)
  T.eq(filter.is_wanted(zoomed_only, true, 1.0), false)
  T.eq(filter.is_wanted(zoomed_only, true, 1.0004), false)
  T.eq(filter.is_wanted(zoomed_only, true, 1.1), true)
end)

T.case("sync on writes the shader and points decoration.screen_shader at it", function()
  -- The file exists, the option holds its path and the store remembers it.
  local host, store = new_host(), {}
  local result = filter.sync(host, context_for(default_settings(), true, store))
  T.eq(result.applied, true)
  T.truthy(host.files[result.path])
  T.eq(host.record.config["decoration.screen_shader"], result.path)
  T.eq(store.shader_path, result.path)
end)

T.case("sync off restores the empty shader and deletes the generated file", function()
  -- Turn on, then off: option back to "" and no file left.
  local host, store = new_host(), {}
  local on = filter.sync(host, context_for(default_settings(), true, store))
  local off = filter.sync(host, context_for(default_settings(), false, store))
  T.eq(off.applied, false)
  T.eq(host.record.config["decoration.screen_shader"], "")
  T.eq(host.files[on.path], nil)
  T.eq(store.shader_path, nil)
end)

T.case("the user's own screen shader is remembered and restored", function()
  -- A pre-existing user shader survives an on/off cycle.
  local host, store = new_host(), {}
  host.record.config["decoration.screen_shader"] = "/home/me/night.frag"
  filter.sync(host, context_for(default_settings(), true, store))
  T.eq(host.files[STATE_DIRECTORY .. "/previous_screen_shader"], "/home/me/night.frag")
  filter.sync(host, context_for(default_settings(), false, store))
  T.eq(host.record.config["decoration.screen_shader"], "/home/me/night.frag")
end)

T.case("switching off without ever switching on leaves the user's shader alone", function()
  -- No config call may touch the shader option.
  local host, store = new_host(), {}
  host.record.config["decoration.screen_shader"] = "/home/me/night.frag"
  filter.sync(host, context_for(default_settings(), false, store))
  T.eq(host.record.config["decoration.screen_shader"], "/home/me/night.frag")
  T.eq(#host.record.config_calls, 0)
end)

T.case("a new Lua state recovers the user's shader from the state file", function()
  -- Simulates HyprZoom.reload() after a lost store: our shader is active, memory empty.
  local host = new_host()
  host.files[STATE_DIRECTORY .. "/previous_screen_shader"] = "/home/me/night.frag"
  local active = STATE_DIRECTORY .. "/filter-0123456789ab.frag"
  host.record.config["decoration.screen_shader"] = active
  local store = {}
  filter.sync(host, context_for(default_settings(), false, store))
  T.eq(host.record.config["decoration.screen_shader"], "/home/me/night.frag")
end)

T.case("changing a setting swaps to a new file and removes the old one", function()
  -- Different constants give a different hash; the stale file must go.
  local host, store = new_host(), {}
  local first = filter.sync(host, context_for(default_settings(), true, store))
  local second = filter.sync(host, context_for(default_settings({ FILTER_CONTRAST = 2.0 }),
    true, store))
  T.truthy(first.path ~= second.path)
  T.eq(host.files[first.path], nil)
  T.truthy(host.files[second.path])
  T.eq(host.record.config["decoration.screen_shader"], second.path)
end)

T.case("an unchanged filter is not re-applied", function()
  -- Calling sync twice with identical settings must set the option once.
  local host, store = new_host(), {}
  filter.sync(host, context_for(default_settings(), true, store))
  local calls_after_first = #host.record.config_calls
  filter.sync(host, context_for(default_settings(), true, store))
  T.eq(#host.record.config_calls, calls_after_first)
end)

T.case("a failing template leaves the screen untouched and reports the problem", function()
  -- Missing base template: no option change, a problem string.
  local host, store = new_host(), {}
  host.files[SHADER_DIRECTORY .. "/base.glsl"] = nil
  local result = filter.sync(host, context_for(default_settings(), true, store))
  T.eq(result.applied, false)
  T.contains(result.problem, "base.glsl")
  T.eq(host.record.config["decoration.screen_shader"], "")
end)

T.case("remove_stale_files deletes only generated shaders other than the kept one", function()
  -- Neighbouring files with other names must survive.
  local host = new_host()
  host.files[STATE_DIRECTORY .. "/filter-aaaaaaaaaaaa.frag"] = "x"
  host.files[STATE_DIRECTORY .. "/filter-bbbbbbbbbbbb.frag"] = "x"
  host.files[STATE_DIRECTORY .. "/state"] = "zoom=2\n"
  host.files[STATE_DIRECTORY .. "/filter-notes.txt"] = "x"
  filter.remove_stale_files(host, STATE_DIRECTORY, STATE_DIRECTORY .. "/filter-bbbbbbbbbbbb.frag")
  T.eq(host.files[STATE_DIRECTORY .. "/filter-aaaaaaaaaaaa.frag"], nil)
  T.truthy(host.files[STATE_DIRECTORY .. "/filter-bbbbbbbbbbbb.frag"])
  T.truthy(host.files[STATE_DIRECTORY .. "/state"])
  T.truthy(host.files[STATE_DIRECTORY .. "/filter-notes.txt"])
end)

T.case("every generated shader compiles with glslangValidator (when installed)", function()
  -- Real GLSL ES 3.00 compile check; the nested Hyprland test proves the pixels.
  local sandbox = os.getenv("ZOOMCTL_TEST_SANDBOX") or "/tmp"
  if not os.execute("command -v glslangValidator > /dev/null 2>&1") then
    print("NOTE glslangValidator not installed; compile check skipped")
    return
  end
  local host = new_host()
  for _, name in ipairs(filter_names()) do
    local text = assert(filter.generate(host, SHADER_DIRECTORY, name, default_settings()))
    local path = sandbox .. "/shader-" .. name .. ".frag"
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
    T.truthy(os.execute("glslangValidator -S frag '" .. path .. "' > /dev/null"),
      name .. " does not compile")
  end
end)
