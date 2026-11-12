-- engine_fixture.lua — build a fully wired engine on the fake host, for the api/entry suites.

-- Fake host and the module that installs the engine.
local stub_host = require("stub_host")
local api_module = require("hyprland-zoom.api")

-- The module table returned to callers.
local M = {}

-- Virtual paths inside the fake filesystem.
M.STATE_DIRECTORY = "/run/state"
M.USER_CONFIG = "/cfg/zoom.conf"
M.SYSTEM_CONFIG = "/cfg/system.conf"
local SHARE_DIRECTORY = "/share"

-- read_repository_file — read a file of the checkout from the real filesystem.
-- Args:    root string (repository root); relative string
-- Returns: file content
local function read_repository_file(root, relative)
  -- Binary mode keeps bytes exact.
  local handle = assert(io.open(root .. "/" .. relative, "rb"))
  local content = handle:read("a")
  handle:close()
  return content
end

-- load_shareable_files — copy the schema and shader templates into the fake filesystem.
-- Args:    host fake host; root string
-- Returns: layout table for the engine
local function load_shareable_files(host, root)
  host.files[SHARE_DIRECTORY .. "/settings.schema"] =
    read_repository_file(root, "config/settings.schema")
  host.dirs[SHARE_DIRECTORY .. "/shaders"] = true
  -- Every template the engine can ask for.
  local names = { "base", "cvd-common", "filter-invert", "filter-smart-invert",
    "filter-grayscale", "filter-grayscale-invert", "filter-high-contrast",
    "filter-protanopia", "filter-deuteranopia", "filter-tritanopia" }
  for _, name in ipairs(names) do
    host.files[SHARE_DIRECTORY .. "/shaders/" .. name .. ".glsl"] =
      read_repository_file(root, "src/shaders/" .. name .. ".glsl")
  end
  return { schema_path = SHARE_DIRECTORY .. "/settings.schema",
    shader_directory = SHARE_DIRECTORY .. "/shaders" }
end

-- M.new — create a host, an engine and return both.
-- Args:    root string (repository root); options table: user_config, system_config,
--          plugin_loaded, omarchy, instance, previous (host whose files survive a "reload"),
--          without_schema (boolean)
-- Returns: api table (HyprZoom), host table, layout table
function M.new(root, options)
  options = options or {}
  local host = stub_host.new({ plugin_loaded = options.plugin_loaded, omarchy = options.omarchy,
    env = { ZOOMCTL_STATE_DIR = M.STATE_DIRECTORY, ZOOMCTL_USER_CONFIG = M.USER_CONFIG,
      ZOOMCTL_SYSTEM_CONFIG = M.SYSTEM_CONFIG,
      HYPRLAND_INSTANCE_SIGNATURE = options.instance or "instance-1" } })
  -- A "compositor reload" keeps the filesystem but starts with fresh hl and Lua state.
  if options.previous then
    host.files, host.dirs = options.previous.files, options.previous.dirs
  end
  local layout = load_shareable_files(host, root)
  if options.without_schema then
    host.files[layout.schema_path] = nil
  end
  host.files[M.USER_CONFIG] = options.user_config or host.files[M.USER_CONFIG]
  host.files[M.SYSTEM_CONFIG] = options.system_config or host.files[M.SYSTEM_CONFIG]
  local api = api_module.install({}, host, layout)
  return api, host, layout
end

-- M.status_map — parse HyprZoom.status() into a table.
-- Args:    text string of key=value lines
-- Returns: map key -> value string
function M.status_map(text)
  -- Lines without "=" are ignored.
  local map = {}
  for key, value in text:gmatch("([%w_]+)=([^\n]*)") do
    map[key] = value
  end
  return map
end

return M
