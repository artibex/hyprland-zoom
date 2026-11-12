-- hyprland-bindings.lua — compatibility shim for 0.1 installs.
-- 0.1 users have `dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua")` in hyprland.lua.
-- The binds now live in the in-compositor engine, so this file only loads it.
-- New installs should load hyprland-zoom.lua directly (`zoomctl setup` migrates the line).

-- Installed location of the engine, used when nothing closer is found.
local DEFAULT_ENGINE_PATH = "/usr/share/hyprland-zoom/hyprland-zoom.lua"

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

-- engine_candidates — the places the engine entry file may live, best first.
-- Args:    none
-- Returns: array of paths
local function engine_candidates()
  local candidates = {}
  -- An explicit share directory (tests, checkouts) wins.
  local share_directory = os.getenv("ZOOMCTL_SHARE_DIR")
  if share_directory and share_directory ~= "" then
    candidates[#candidates + 1] = share_directory .. "/hyprland-zoom.lua"
  end
  -- Next to this shim: the installed layout, or ../src/lua in a repository checkout.
  local info = debug and debug.getinfo and debug.getinfo(1, "S")
  local own_directory = info and info.source:match("^@(.*)/[^/]*$")
  if own_directory then
    candidates[#candidates + 1] = own_directory .. "/hyprland-zoom.lua"
    -- Repository checkout layout: the engine sits in src/lua next to config/.
    candidates[#candidates + 1] = own_directory .. "/../src/lua/hyprland-zoom.lua"
  end
  candidates[#candidates + 1] = DEFAULT_ENGINE_PATH
  return candidates
end

-- load_engine — run the first engine entry file that exists.
-- Args:    none
-- Returns: true when an engine was loaded
local function load_engine()
  for _, path in ipairs(engine_candidates()) do
    if file_exists(path) then
      dofile(path)
      return true
    end
  end
  -- Nothing found: the caller reports it.
  return false
end

-- Never raise into Hyprland's config parser; tell the user instead.
if not load_engine() then
  print("[hyprland-zoom] hyprland-bindings.lua: engine hyprland-zoom.lua not found")
  pcall(function()
    hl.notification.create({ text = "hyprland-zoom: engine not found", duration = 8000 })
  end)
end
