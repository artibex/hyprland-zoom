-- state.lua — runtime state files (contract C5): zoom level, filter flag, user's own shader.
-- Hyprland reloads reset the Lua state; this module lets the engine survive a reload (E10).

-- The module table returned to callers.
local M = {}

-- Helpers shared by all engine modules.
local util = require("hyprland-zoom.util")

-- Name of the key=value state file inside the state directory.
local STATE_FILE_NAME = "state"
-- Name of the file remembering the user's own screen shader.
local PREVIOUS_SHADER_FILE_NAME = "previous_screen_shader"
-- Highest zoom Hyprland supports; persisted values above it are treated as corrupt.
local MAX_PERSISTED_ZOOM = 10

-- M.directory — decide where runtime state lives.
-- Args:    host platform adapter
-- Returns: directory path, or nil when neither ZOOMCTL_STATE_DIR nor XDG_RUNTIME_DIR is set
function M.directory(host)
  -- Explicit override wins (tests, unusual setups).
  local override = host.getenv("ZOOMCTL_STATE_DIR")
  if override and override ~= "" then
    return override
  end
  -- Default: a private subdirectory of the per-user runtime directory.
  local runtime_directory = host.getenv("XDG_RUNTIME_DIR")
  if runtime_directory and runtime_directory ~= "" then
    return util.join_path(runtime_directory, "hyprland-zoom")
  end
  return nil
end

-- parse_zoom — accept a persisted zoom value only when it is sane.
-- Args:    text string
-- Returns: number in [1, 10]; or nil
local function parse_zoom(text)
  -- Plain decimals only; anything else is a corrupt or foreign file.
  local number = text:match("^%d+%.?%d*$") and tonumber(text) or nil
  if number and number >= 1 and number <= MAX_PERSISTED_ZOOM then
    return number
  end
  return nil
end

-- M.read_legacy_saved_zoom — read the 0.1 `last_zoom` file once.
-- Args:    host platform adapter
-- Returns: number, or nil when absent or invalid
function M.read_legacy_saved_zoom(host)
  -- The 0.1 file lived next to the new directory in the runtime dir.
  local runtime_directory = host.getenv("XDG_RUNTIME_DIR")
  if not runtime_directory or runtime_directory == "" then
    return nil
  end
  local text = host.read_file(runtime_directory .. "/zoomctl/last_zoom")
  return text and parse_zoom(util.trim(text)) or nil
end

-- M.read — load the persisted runtime state.
-- Args:    host platform adapter; directory state directory
-- Returns: table with any of zoom, saved_zoom (numbers), filter_active (boolean), filter (string)
function M.read(host, directory)
  local values = {}
  local text = host.read_file(util.join_path(directory, STATE_FILE_NAME))
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    -- Each line is KEY=VALUE; unknown keys are ignored for forward compatibility.
    local key, value = util.trim(line):match("^([%w_]+)=(.*)$")
    if key == "zoom" or key == "saved_zoom" then
      values[key] = parse_zoom(util.trim(value))
    elseif key == "filter_active" then
      values.filter_active = (value == "on")
    elseif key == "filter" and value:match("^[%a%-]+$") then
      values.filter = value
    end
  end
  -- Migrate the 0.1 saved zoom when the new file has none.
  values.saved_zoom = values.saved_zoom or M.read_legacy_saved_zoom(host)
  return values
end

-- M.write — persist the runtime state.
-- Args:    host platform adapter; directory state directory; values table as from M.read
-- Returns: true; or nil, error text when the file could not be written
function M.write(host, directory, values)
  -- Fixed key order keeps the file diff-friendly and easy to read in a shell.
  local lines = {}
  if values.zoom then
    lines[#lines + 1] = string.format("zoom=%.6f", values.zoom)
  end
  if values.saved_zoom then
    lines[#lines + 1] = string.format("saved_zoom=%.6f", values.saved_zoom)
  end
  lines[#lines + 1] = "filter_active=" .. (values.filter_active and "on" or "off")
  if values.filter then
    lines[#lines + 1] = "filter=" .. values.filter
  end
  -- One trailing newline keeps the file a well-formed text file for shell readers.
  local content = table.concat(lines, "\n") .. "\n"
  return host.write_file(util.join_path(directory, STATE_FILE_NAME), content)
end

-- M.read_previous_shader — read the user's own screen shader path saved earlier.
-- Args:    host platform adapter; directory state directory
-- Returns: path string ("" means "the user had none"); nil when nothing is saved
function M.read_previous_shader(host, directory)
  -- The file holds one line without a newline.
  local text = host.read_file(util.join_path(directory, PREVIOUS_SHADER_FILE_NAME))
  return text and util.trim(text) or nil
end

-- M.write_previous_shader — save the user's own screen shader path.
-- Args:    host platform adapter; directory state directory; shader_path string ("" for none)
-- Returns: true; or nil, error text
function M.write_previous_shader(host, directory, shader_path)
  -- Written verbatim so zoomctl doctor and a crashed session can still restore it.
  return host.write_file(util.join_path(directory, PREVIOUS_SHADER_FILE_NAME), shader_path)
end

return M
