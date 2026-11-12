-- hyprland-zoom.lua — entry point of the in-compositor zoom engine (decision E1).
-- Load it from hyprland.lua AFTER the Omarchy defaults:
--   dofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")
-- It defines the single global `HyprZoom` (contract C3) and is safe to load repeatedly.

-- The one global this project defines; reused when the file is loaded again.
HyprZoom = HyprZoom or {}

-- Share directory used when neither the environment nor the script path tells otherwise.
local DEFAULT_SHARE_DIRECTORY = "/usr/share/hyprland-zoom"

-- file_exists — test whether a file can be opened for reading.
-- Args:    path string
-- Returns: true when it can
local function file_exists(path)
  -- Opening is the portable existence test in plain Lua.
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
  end
  return handle ~= nil
end

-- script_directory — directory of this very file, or nil when Lua cannot tell.
-- Args:    none
-- Returns: directory path string; nil when debug information is unavailable
local function script_directory()
  -- dofile records the path as "@/dir/file.lua" in the chunk's source name.
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local source = info and info.source or ""
  return source:match("^@(.*)/[^/]*$")
end

-- installed_layout — the layout of an installed package (or a ZOOMCTL_SHARE_DIR override).
-- Args:    share_directory string
-- Returns: layout table; nil when the engine modules are not below that directory
local function installed_layout(share_directory)
  -- Modules live in <share>/lua/hyprland-zoom/, next to schema and shaders.
  if not file_exists(share_directory .. "/lua/hyprland-zoom/api.lua") then
    return nil
  end
  return { modules_root = share_directory .. "/lua",
    schema_path = share_directory .. "/settings.schema",
    shader_directory = share_directory .. "/shaders" }
end

-- checkout_layout — the layout of a repository checkout (src/lua next to config/ and shaders).
-- Args:    entry_directory string (the directory of this file)
-- Returns: layout table; nil when this file is not inside a checkout
local function checkout_layout(entry_directory)
  -- Modules sit next to this file; schema and shaders are found relative to src/lua.
  if not file_exists(entry_directory .. "/hyprland-zoom/api.lua") then
    return nil
  end
  return { modules_root = entry_directory,
    schema_path = entry_directory .. "/../../config/settings.schema",
    shader_directory = entry_directory .. "/../shaders" }
end

-- resolve_layout — find modules, schema and shaders.
-- Args:    none
-- Returns: layout table {modules_root, schema_path, shader_directory}; nil when nothing is found
local function resolve_layout()
  -- Order: explicit override, the file's own location (installed, then checkout), default path.
  local override = os.getenv("ZOOMCTL_SHARE_DIR")
  local own_directory = script_directory()
  return (override and override ~= "" and installed_layout(override))
    or (own_directory and installed_layout(own_directory))
    or (own_directory and checkout_layout(own_directory))
    or installed_layout(DEFAULT_SHARE_DIRECTORY)
end

-- load_modules — require the engine modules with a temporary package.path.
-- Args:    modules_root string (directory containing hyprland-zoom/)
-- Returns: host module, api module
local function load_modules(modules_root)
  -- Forget cached copies so a re-run picks up edited files, then restore package.path.
  local previous_path = package.path
  for name in pairs(package.loaded) do
    if name:match("^hyprland%-zoom%.") then
      package.loaded[name] = nil
    end
  end
  package.path = modules_root .. "/?.lua;" .. previous_path
  local loaded, host_module, api_module = pcall(function()
    return require("hyprland-zoom.host"), require("hyprland-zoom.api")
  end)
  package.path = previous_path
  if not loaded then
    error(host_module, 0)
  end
  return host_module, api_module
end

-- start_engine — wire the real host to the API and run the engine.
-- Args:    layout table from resolve_layout
-- Returns: nothing
local function start_engine(layout)
  local host_module, api_module = load_modules(layout.modules_root)
  api_module.install(HyprZoom, host_module.system(_G), layout)
end

-- report_startup_failure — print to the log and show a notification, never raising.
-- Args:    log_text string; notification_text string
-- Returns: nothing
local function report_startup_failure(log_text, notification_text)
  -- The log line has the details; the notification only tells the user where to look.
  print("[hyprland-zoom] " .. log_text)
  pcall(function()
    hl.notification.create({ text = notification_text, duration = 8000 })
  end)
end

-- Entry: never raise into Hyprland's config parser; report through the log and a notification.
local entry_layout = resolve_layout()
if not entry_layout then
  report_startup_failure("engine files not found (set ZOOMCTL_SHARE_DIR or reinstall)",
    "hyprland-zoom: engine files not found")
else
  local started, problem = pcall(start_engine, entry_layout)
  if not started then
    report_startup_failure("engine failed to start: " .. tostring(problem),
      "hyprland-zoom: engine failed to start, see the Hyprland log")
  end
end
