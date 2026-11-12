-- stub_host.lua — an in-memory fake of Hyprland's `hl` API and the platform adapter (host).
-- It records every config/bind/unbind/animation call so suites can assert on them.

-- The module table returned to callers.
local M = {}

-- Config keys the fake accepts; anything else raises like the real `hl.config` does.
local KNOWN_CONFIG_KEYS = {
  ["cursor.zoom_factor"] = 1.0,
  ["cursor.zoom_disable_aa"] = false,
  ["cursor.zoom_rigid"] = false,
  ["cursor.zoom_detached_camera"] = true,
  ["binds.scroll_event_delay"] = 300,
  ["decoration.screen_shader"] = "",
}

-- float32_round — mimic Hyprland storing numbers as 32-bit floats.
-- Args:    value number
-- Returns: the value after a float32 round trip
local function float32_round(value)
  -- Pack and unpack through the native single-precision format.
  return (string.unpack("f", string.pack("f", value)))
end

-- normalize_chord — make a bind string comparable the way Hyprland does.
-- Args:    keys string such as "SUPER + ALT + mouse_up"
-- Returns: lower-case string without spaces
local function normalize_chord(keys)
  -- Hyprland's removeKeybind(string) ignores case and spaces.
  local compact = keys:gsub(" ", "")
  return compact:lower()
end

-- flatten_config — turn a nested config table into dotted-key pairs.
-- Args:    nested table such as {cursor = {zoom_factor = 2}}; prefix string
-- Returns: map "cursor.zoom_factor" -> 2
local function flatten_config(nested, prefix, flat)
  -- Walk recursively; leaves are anything that is not a table.
  flat = flat or {}
  for key, value in pairs(nested) do
    local dotted = prefix and (prefix .. "." .. key) or key
    if type(value) == "table" then
      flatten_config(value, dotted, flat)
    else
      flat[dotted] = value
    end
  end
  return flat
end

-- build_hl — create the fake `hl` table and the record it writes into.
-- Args:    record table receiving the call logs; options table (plugins, strict_binds)
-- Returns: the fake hl table
local function build_hl(record, options)
  -- Start from Hyprland's documented defaults.
  record.config = {}
  for key, value in pairs(KNOWN_CONFIG_KEYS) do
    record.config[key] = value
  end
  record.config_calls, record.bindings, record.unbinds = {}, {}, {}
  record.animations, record.window_rules, record.execs = {}, {}, {}
  record.notifications = {}

  local hl = { dsp = {}, notification = {} }

  -- hl.config: validate keys, store floats as float32, record the call.
  function hl.config(nested)
    local flat = flatten_config(nested)
    for key, value in pairs(flat) do
      -- Plugin keys are accepted before the plugin loads (verified on 0.56.2).
      local known = KNOWN_CONFIG_KEYS[key] ~= nil or key:match("^plugin%.hyprzoom%.") ~= nil
      if not known then
        error("unknown config key '" .. key .. "'", 2)
      end
      record.config[key] = (key == "cursor.zoom_factor") and float32_round(value) or value
    end
    record.config_calls[#record.config_calls + 1] = flat
  end

  -- hl.get_config: nil for unknown keys, like the real API.
  function hl.get_config(key)
    return record.config[key]
  end

  -- kill_chord: mark every bind on a chord dead (Hyprland removes them all).
  local function kill_chord(keys)
    for _, binding in ipairs(record.bindings) do
      if binding.chord == normalize_chord(keys) then
        binding.alive = false
      end
    end
  end

  -- hl.bind: record the bind and hand back a handle with remove/set_enabled.
  function hl.bind(keys, action, opts)
    local binding = { keys = keys, chord = normalize_chord(keys), action = action,
      opts = opts or {}, alive = true }
    record.bindings[#record.bindings + 1] = binding
    -- The handle mimics HL.Keybind: remove() deletes every bind on the chord.
    binding.handle = {
      remove = function()
        kill_chord(keys)
      end,
      set_enabled = function() end,
    }
    return binding.handle
  end

  -- hl.unbind: record the request, then kill the chord like the real API.
  function hl.unbind(keys)
    record.unbinds[#record.unbinds + 1] = keys
    kill_chord(keys)
  end

  -- Small recorders for the remaining calls the engine makes.
  function hl.animation(spec)
    record.animations[#record.animations + 1] = spec
  end
  function hl.window_rule(spec)
    record.window_rules[#record.window_rules + 1] = spec
  end
  function hl.exec_cmd(command)
    record.execs[#record.execs + 1] = command
  end
  function hl.dsp.exec_cmd(command)
    return { kind = "exec_cmd", command = command }
  end
  function hl.notification.create(spec)
    record.notifications[#record.notifications + 1] = spec
  end
  function hl.get_loaded_plugins()
    return options.plugin_loaded and { { name = "hyprzoom" } } or {}
  end
  function hl.version()
    return "0.56.2-stub"
  end
  return hl
end

-- build_file_system — attach an in-memory filesystem to the host table.
-- Args:    host table to extend
-- Returns: nothing
local function build_file_system(host)
  host.files, host.dirs = {}, {}

  -- Reading a missing file yields nil, exactly like the real adapter.
  function host.read_file(path)
    return host.files[path]
  end
  -- Writing needs an existing directory, which catches missing ensure_dir calls.
  function host.write_file(path, text)
    local directory = path:match("^(.*)/[^/]*$")
    if not host.dirs[directory] then
      return nil, "no such directory: " .. tostring(directory)
    end
    host.files[path] = text
    return true
  end
  function host.remove_file(path)
    host.files[path] = nil
    return true
  end
  function host.ensure_dir(path)
    host.dirs[path] = true
    return true
  end
  -- Names of direct children, like `ls` would print.
  function host.list_dir(path)
    local names = {}
    for file_path in pairs(host.files) do
      local name = file_path:match("^" .. path:gsub("%p", "%%%0") .. "/([^/]+)$")
      if name then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end
end

-- M.new — build a fresh fake host.
-- Args:    options table: env (overrides), plugin_loaded bool, omarchy bool
-- Returns: host table; host.record holds the hl call logs, host.fire(chord) runs a bind
function M.new(options)
  options = options or {}
  local host = { record = {}, logs = {}, omarchy = options.omarchy or false }
  -- Default environment: a runtime dir, no overrides for config paths.
  host.env = { HOME = "/home/test", XDG_RUNTIME_DIR = "/run/user/1000" }
  for name, value in pairs(options.env or {}) do
    host.env[name] = value
  end
  host.hl = build_hl(host.record, options)
  build_file_system(host)

  function host.getenv(name)
    return host.env[name]
  end
  function host.log(message)
    host.logs[#host.logs + 1] = message
  end
  function host.notify(text)
    host.record.notifications[#host.record.notifications + 1] = { text = text }
  end
  function host.omarchy_present()
    return host.omarchy
  end
  -- Fake clock (seconds) and timers: tests advance host.clock and call host.run_timers().
  host.clock, host.timers = 1000, {}
  function host.now()
    return host.clock
  end
  function host.after(milliseconds, callback)
    host.timers[#host.timers + 1] = { milliseconds = milliseconds, callback = callback }
  end
  function host.run_timers()
    local pending = host.timers
    host.timers = {}
    for _, timer in ipairs(pending) do
      timer.callback()
    end
  end
  -- fire: run the action of the live bind on a chord (as Hyprland would on a key press).
  function host.fire(keys)
    for index = #host.record.bindings, 1, -1 do
      local binding = host.record.bindings[index]
      if binding.alive and binding.chord == normalize_chord(keys) then
        binding.action()
        return true
      end
    end
    return false
  end
  return host
end

-- M.live_chords — list the chords that are currently bound (not removed).
-- Args:    host table from M.new
-- Returns: sorted array of the original key strings of live binds
function M.live_chords(host)
  -- Collect and sort for stable assertions.
  local chords = {}
  for _, binding in ipairs(host.record.bindings) do
    if binding.alive then
      chords[#chords + 1] = binding.keys
    end
  end
  table.sort(chords)
  return chords
end

return M
