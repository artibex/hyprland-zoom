-- host.lua — the platform adapter: the only module that touches files, processes and globals.
-- Every other module receives this table as `host`, so tests can substitute an in-memory fake.

-- The module table returned to callers.
local M = {}

-- Prefix of every log line, so the lines are easy to find in Hyprland's log.
local LOG_PREFIX = "[hyprland-zoom] "
-- How long a notification stays on screen (milliseconds).
local NOTIFICATION_MS = 6000

-- M.shell_quote — quote a string for safe use as one shell word.
-- Args:    text string
-- Returns: single-quoted string with embedded single quotes escaped
function M.shell_quote(text)
  -- Close the quote, add an escaped quote, reopen: the classic '\'' idiom.
  local escaped = text:gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

-- read_file — read a whole file.
-- Args:    path string
-- Returns: content string; nil when the file cannot be opened
local function read_file(path)
  -- Binary mode keeps bytes untouched on every platform.
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("a")
  -- Always release the descriptor, also when reading failed.
  handle:close()
  return content
end

-- write_file — write a file atomically (temp file, then rename).
-- Args:    path string; text string
-- Returns: true; or nil, error text
local function write_file(path, text)
  -- A reader (zoomctl, a status bar) must never see a half-written file.
  local temporary_path = path .. ".tmp"
  local handle, open_problem = io.open(temporary_path, "wb")
  if not handle then
    return nil, open_problem
  end
  -- Remember the write result before closing.
  local written, write_problem = handle:write(text)
  handle:close()
  if not written then
    os.remove(temporary_path)
    -- Report the failure; the caller decides how loud to be.
    return nil, write_problem
  end
  return os.rename(temporary_path, path)
end

-- list_dir — list the entries of a directory.
-- Args:    path string
-- Returns: array of names (empty when the directory is missing)
-- Notes:   Spawns `ls`; call it at load time only, never from a bind callback.
local function list_dir(path)
  local names = {}
  local pipe = io.popen("ls -1A -- " .. M.shell_quote(path) .. " 2>/dev/null")
  if not pipe then
    return names
  end
  for name in pipe:lines() do
    names[#names + 1] = name
  end
  pipe:close()
  return names
end

-- ensure_dir — create a private (0700) directory if it does not exist.
-- Args:    path string
-- Returns: true when the command succeeded
-- Notes:   Spawns `mkdir`; load time only.
local function ensure_dir(path)
  -- -p makes this idempotent; the mode applies to the final component only.
  local created = os.execute("mkdir -p -m 0700 -- " .. M.shell_quote(path))
  return created == true or created == 0
end

-- M.system — build the real adapter.
-- Args:    environment the Lua global table (provides hl and the Omarchy helper `o`)
-- Returns: host table (see tests/lua/stub_host.lua for the full interface)
function M.system(environment)
  local hl = environment.hl
  local host = { hl = hl, read_file = read_file, write_file = write_file, list_dir = list_dir,
    ensure_dir = ensure_dir, getenv = os.getenv, now = os.time, remove_file = os.remove }

  -- log — print a prefixed line; Hyprland routes it to its log (and to `hyprctl repl` output).
  -- Args:    message string
  -- Returns: nothing
  function host.log(message)
    print(LOG_PREFIX .. message)
  end

  -- notify — show an on-screen notice; failures are ignored (nothing else could report them).
  -- Args:    text string
  -- Returns: nothing
  function host.notify(text)
    pcall(hl.notification.create, { text = text, duration = NOTIFICATION_MS })
  end

  -- omarchy_present — detect Omarchy by its global helper `o` with a `bind` function.
  -- Args:    none
  -- Returns: true when Omarchy's helper is loaded
  function host.omarchy_present()
    return type(environment.o) == "table" and type(environment.o.bind) == "function"
  end

  -- after — run a function once after a delay, using a Hyprland timer.
  -- Args:    milliseconds number; callback function
  -- Returns: nothing
  function host.after(milliseconds, callback)
    pcall(hl.timer, callback, { timeout = milliseconds, type = "oneshot" })
  end
  return host
end

return M
