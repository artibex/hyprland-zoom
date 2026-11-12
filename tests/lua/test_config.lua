-- test_config.lua — config layering, 0.1 compatibility, validation and preview overrides.

-- Framework, fake host and the modules under test.
local T = require("framework")
local stub_host = require("stub_host")
local schema_module = require("hyprland-zoom.schema")
local config = require("hyprland-zoom.config")

-- load_schema — parse the shipped schema once per call (cheap, keeps cases independent).
-- Args:    none
-- Returns: parsed schema
local function load_schema()
  -- Read the repository's schema file.
  local handle = assert(io.open(T.repository_root .. "/config/settings.schema", "rb"))
  local text = handle:read("a")
  handle:close()
  return assert(schema_module.parse(text))
end

-- host_with_files — a fake host whose system/user config files hold the given text.
-- Args:    system_text string or nil; user_text string or nil
-- Returns: host table
local function host_with_files(system_text, user_text)
  -- Explicit paths keep the tests independent of HOME and XDG_CONFIG_HOME.
  local host = stub_host.new({ env = {
    ZOOMCTL_SYSTEM_CONFIG = "/etc/zoomctl.conf", ZOOMCTL_USER_CONFIG = "/home/test/zoom.conf" } })
  host.files["/etc/zoomctl.conf"] = system_text
  host.files["/home/test/zoom.conf"] = user_text
  return host
end

T.suite("config")

T.case("without any file the schema defaults apply", function()
  -- No files at all: pure defaults and no warnings.
  local schema = load_schema()
  local settings, warnings = config.load(host_with_files(nil, nil), schema)
  T.eq(settings.ZOOM_STEP, 0.10)
  T.eq(settings.ZOOM_TRACKING, "centered")
  T.eq(warnings, {})
end)

T.case("user overrides system overrides default", function()
  -- ZOOM_STEP set in both layers: user wins; ZOOM_MAX only in system.
  local host = host_with_files("ZOOM_STEP=0.30\nZOOM_MAX=5", "ZOOM_STEP=0.20\n")
  local settings = config.load(host, load_schema())
  T.eq(settings.ZOOM_STEP, 0.20)
  T.eq(settings.ZOOM_MAX, 5.0)
end)

T.case("comments, blanks, spaces and quotes are tolerated", function()
  -- All forms the contract allows for KEY=VALUE lines.
  local host = host_with_files(nil, "# comment\n\n  ZOOM_STEP =  0.25  \nFILTER=\"grayscale\"\r\n")
  local settings, warnings = config.load(host, load_schema())
  T.eq(settings.ZOOM_STEP, 0.25)
  T.eq(settings.FILTER, "grayscale")
  T.eq(warnings, {})
end)

T.case("unknown keys warn and are ignored", function()
  -- ZOOMCTL_STATE_DIR is not a schema key.
  local host = host_with_files(nil, "NOPE=1\nZOOM_STEP=0.2\n")
  local settings, warnings = config.load(host, load_schema())
  T.eq(settings.ZOOM_STEP, 0.20)
  T.eq(#warnings, 1)
  T.contains(warnings[1], "unknown key NOPE")
end)

T.case("an invalid user value falls back to the system value", function()
  -- Out-of-range user value: the system layer's 0.30 stays in force.
  local host = host_with_files("ZOOM_STEP=0.30", "ZOOM_STEP=9\n")
  local settings, warnings = config.load(host, load_schema())
  T.eq(settings.ZOOM_STEP, 0.30)
  T.contains(warnings[1], "user config: invalid ZOOM_STEP")
end)

T.case("an invalid value everywhere falls back to the default", function()
  -- Garbage in the only layer: default 0.10 and a warning.
  local settings, warnings = config.load(host_with_files(nil, "ZOOM_STEP=abc"), load_schema())
  T.eq(settings.ZOOM_STEP, 0.10)
  T.eq(#warnings, 1)
end)

T.case("0.1 file: CENTER_CURSOR=1 means centered and additive steps", function()
  -- The 0.1 format has no ZOOM_TRACKING and no ZOOM_STEP_MODE.
  local host = host_with_files(nil, "ZOOM_STEP=0.50\nZOOM_CENTER_CURSOR=1\n")
  local settings, warnings = config.load(host, load_schema())
  T.eq(settings.ZOOM_TRACKING, "centered")
  T.eq(settings.ZOOM_STEP_MODE, "add")
  T.eq(settings.ZOOM_STEP, 0.50)
  T.eq(warnings, {})
end)

T.case("0.1 file: CENTER_CURSOR=0 means edge", function()
  -- The shipped 0.1 default was 0.
  local host = host_with_files("ZOOM_CENTER_CURSOR=0\n", nil)
  local settings = config.load(host, load_schema())
  T.eq(settings.ZOOM_TRACKING, "edge")
  T.eq(settings.ZOOM_STEP_MODE, "add")
end)

T.case("explicit new keys win over the 0.1 implications", function()
  -- A layer that sets both CENTER_CURSOR and the new keys keeps the new keys.
  local text = "ZOOM_CENTER_CURSOR=1\nZOOM_TRACKING=follow\nZOOM_STEP_MODE=multiply\n"
  local settings = config.load(host_with_files(nil, text), load_schema())
  T.eq(settings.ZOOM_TRACKING, "follow")
  T.eq(settings.ZOOM_STEP_MODE, "multiply")
end)

T.case("the 0.1 implication is per layer and does not leak into later layers", function()
  -- Old system file (0.1) plus new user file: user layer has no legacy key.
  local host = host_with_files("ZOOM_CENTER_CURSOR=0\n", "ZOOM_STEP=0.15\n")
  local settings = config.load(host, load_schema())
  -- The system layer implied "add"; the user layer does not override it.
  T.eq(settings.ZOOM_STEP_MODE, "add")
  T.eq(settings.ZOOM_STEP, 0.15)
end)

T.case("inverted zoom range falls back to defaults with a warning", function()
  -- ZOOM_MIN above ZOOM_MAX cannot be honoured.
  local host = host_with_files(nil, "ZOOM_MIN=5\nZOOM_MAX=2\n")
  local settings, warnings = config.load(host, load_schema())
  T.eq(settings.ZOOM_MIN, 1.0)
  T.eq(settings.ZOOM_MAX, 10.0)
  T.contains(warnings[1], "ZOOM_MIN is above ZOOM_MAX")
end)

T.case("ZOOM_RESET outside the range is clamped", function()
  -- Reset 1.00 below a raised minimum of 2.
  local settings, warnings = config.load(host_with_files(nil, "ZOOM_MIN=2\n"), load_schema())
  T.eq(settings.ZOOM_RESET, 2.0)
  T.contains(warnings[1], "ZOOM_RESET")
end)

T.case("config paths honour overrides, XDG_CONFIG_HOME and HOME", function()
  -- Empty override values count as unset.
  local host = stub_host.new({ env = { ZOOMCTL_USER_CONFIG = "" } })
  local _, user_path = config.config_paths(host)
  T.eq(user_path, "/home/test/.config/zoomctl/zoom.conf")
  host.env.XDG_CONFIG_HOME = "/cfg"
  _, user_path = config.config_paths(host)
  T.eq(user_path, "/cfg/zoomctl/zoom.conf")
end)

T.case("overrides are validated and applied on a copy", function()
  -- A valid preview changes the copy only.
  local schema = load_schema()
  local settings = config.load(host_with_files(nil, nil), schema)
  local merged = config.with_overrides(schema, settings, { ZOOM_STEP = 0.5, FILTER_ACTIVE = true })
  T.eq(merged.ZOOM_STEP, 0.5)
  T.eq(merged.FILTER_ACTIVE, true)
  T.eq(settings.ZOOM_STEP, 0.10)
end)

T.case("an invalid override rejects the whole preview", function()
  -- Unknown key, bad value and an injection attempt.
  local schema = load_schema()
  local settings = config.load(host_with_files(nil, nil), schema)
  local _, unknown = config.with_overrides(schema, settings, { NOPE = 1 })
  T.contains(unknown, "unknown setting")
  local _, bad_value = config.with_overrides(schema, settings, { ZOOM_STEP = 99 })
  T.contains(bad_value, "invalid ZOOM_STEP")
  local merged = config.with_overrides(schema, settings, { FILTER = "x'); os.exit() --" })
  T.eq(merged, nil)
end)
