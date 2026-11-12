-- filter.lua — colour filters (E7): generate a GLSL screen shader from templates and apply it.
-- Constants are baked into the shader text (screen shaders get no config uniforms); the file name
-- carries a content hash so Hyprland reloads the shader whenever any setting changes.

-- The module table returned to callers.
local M = {}

-- Helpers shared by all engine modules and the state-file reader/writer.
local util = require("hyprland-zoom.util")
local state = require("hyprland-zoom.state")

-- Required first line of every generated shader (Hyprland refuses anything else, silently).
local SHADER_VERSION_LINE = "#version 300 es"
-- Safety cap for generated text; the real shaders are a few kilobytes.
local MAX_SHADER_BYTES = 65536
-- File name pattern of generated shaders inside the state directory.
local SHADER_FILE_PATTERN = "^filter%-%x+%.frag$"
-- Zoom values above 1 + this count as "zoomed" for FILTER_ONLY_WHEN_ZOOMED.
local ZOOMED_THRESHOLD = 1e-3

-- read_template — load one template file from the shader directory.
-- Args:    host platform adapter; shader_directory string; name template name (a-z and "-")
-- Returns: file text; or nil, error text
local function read_template(host, shader_directory, name)
  -- Names come from the schema enum or from our own templates; still validate the shape.
  if not name:match("^[%l%-]+$") then
    return nil, "invalid template name"
  end
  local text = host.read_file(util.join_path(shader_directory, name .. ".glsl"))
  if not text then
    return nil, "missing shader template " .. name .. ".glsl"
  end
  return text
end

-- expand_includes — replace `@INCLUDE name@` markers with the named template.
-- Args:    host platform adapter; shader_directory string; text template text
-- Returns: expanded text; or nil, error text
local function expand_includes(host, shader_directory, text)
  local failure
  -- gsub's callback runs once per marker; remember the first failure instead of raising.
  local expanded = text:gsub("@INCLUDE ([%l%-]+)@", function(name)
    local included, problem = read_template(host, shader_directory, name)
    failure = failure or problem
    return included or ""
  end)
  if failure then
    return nil, failure
  end
  return expanded
end

-- format_constant — render a setting as a GLSL float literal.
-- Args:    value number
-- Returns: text such as "0.5000"; or nil when the value is not a finite number
local function format_constant(value)
  -- NaN and infinities have no place in a shader; settings are validated, but be strict anyway.
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return string.format("%.4f", value)
end

-- M.validate — check generated shader text before it is written or applied.
-- Args:    text shader source
-- Returns: true; or nil, error text
function M.validate(text)
  -- Hyprland silently ignores shaders that do not start with the version line.
  if text:sub(1, #SHADER_VERSION_LINE + 1) ~= SHADER_VERSION_LINE .. "\n" then
    return nil, "shader must start with '" .. SHADER_VERSION_LINE .. "'"
  end
  -- Leftover markers mean a placeholder was not substituted.
  if text:find("@", 1, true) then
    return nil, "unresolved placeholder in shader"
  end
  -- Plain printable ASCII keeps the compiler (and our hash) predictable.
  if text:find("[^\n\t\32-\126]") then
    return nil, "shader contains non-ASCII or control characters"
  end
  if #text > MAX_SHADER_BYTES or not text:find("void main()", 1, true) then
    return nil, "shader has an unexpected size or no main()"
  end
  return true
end

-- load_filter_source — read the skeleton and the (include-expanded) body of one filter.
-- Args:    host platform adapter; shader_directory string; filter_name string
-- Returns: skeleton text, body text; or nil, error text
local function load_filter_source(host, shader_directory, filter_name)
  -- Either template may be missing in a broken install; report the first problem.
  local base, base_problem = read_template(host, shader_directory, "base")
  local body, body_problem = read_template(host, shader_directory, "filter-" .. filter_name)
  if not base or not body then
    return nil, base_problem or body_problem
  end
  local expanded_body, include_problem = expand_includes(host, shader_directory, body)
  if not expanded_body then
    return nil, include_problem
  end
  return base, expanded_body
end

-- bake_constants — substitute the numeric settings into the skeleton.
-- Args:    skeleton string with @INTENSITY@ etc.; settings effective settings
-- Returns: text with the constants filled in; or nil, error text
local function bake_constants(skeleton, settings)
  -- Each value is a validated number rendered by format_constant; never user text.
  -- An ordered list (not a map) so a nil literal is still visited and reported.
  local constants = {
    { "INTENSITY", format_constant(settings.FILTER_INTENSITY) },
    { "CONTRAST", format_constant(settings.FILTER_CONTRAST) },
    { "BRIGHTNESS", format_constant(settings.FILTER_BRIGHTNESS) },
    { "SATURATION", format_constant(settings.FILTER_SATURATION) },
  }
  local text = skeleton
  for _, constant in ipairs(constants) do
    local name, literal = constant[1], constant[2]
    if not literal then
      return nil, "filter setting " .. name:lower() .. " is not a number"
    end
    text = text:gsub("@" .. name .. "@", literal)
  end
  return text
end

-- M.generate — build the shader text for a filter and the baked-in adjustments.
-- Args:    host platform adapter; shader_directory string; filter_name string;
--          settings effective settings (FILTER_INTENSITY/CONTRAST/BRIGHTNESS/SATURATION)
-- Returns: shader text; or nil, error text
function M.generate(host, shader_directory, filter_name, settings)
  local base, body = load_filter_source(host, shader_directory, filter_name)
  if not base then
    return nil, body
  end
  local text, constants_problem = bake_constants(base, settings)
  if not text then
    return nil, constants_problem
  end
  -- Function replacements keep "%" in template text literal.
  text = text:gsub("@FILTER_NAME@", function() return filter_name end)
  text = text:gsub("@FILTER_BODY@", function() return body end)
  local valid, problem = M.validate(text)
  if not valid then
    return nil, problem
  end
  return text
end

-- M.file_name — name a shader file after its content.
-- Args:    text shader source
-- Returns: "filter-<12 hex>.frag"
function M.file_name(text)
  -- Content-addressed: any setting change yields a new path, which makes Hyprland reload.
  return "filter-" .. util.fnv1a_hex(text) .. ".frag"
end

-- M.is_wanted — decide whether the filter should be visible right now (pure).
-- Args:    settings effective settings (FILTER_ONLY_WHEN_ZOOMED); active boolean; zoom number
-- Returns: true when the screen shader should be applied
function M.is_wanted(settings, active, zoom)
  -- Switched off wins; otherwise the zoomed-only option compares against the unzoomed 1.0.
  if not active then
    return false
  end
  return not settings.FILTER_ONLY_WHEN_ZOOMED or zoom > 1 + ZOOMED_THRESHOLD
end

-- is_generated_path — recognise one of our own shader paths.
-- Args:    path string; directory state directory
-- Returns: true when the path is a generated shader inside the state directory
local function is_generated_path(path, directory)
  -- Directory prefix and file name pattern must both match.
  local prefix = util.join_path(directory, "")
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1):match(SHADER_FILE_PATTERN) ~= nil
end

-- read_active_shader — read decoration.screen_shader from Hyprland.
-- Args:    host platform adapter
-- Returns: path string ("" when unset)
local function read_active_shader(host)
  -- nil/unknown reads count as "no shader" so the engine never errors here.
  local read_ok, value = pcall(host.hl.get_config, "decoration.screen_shader")
  return (read_ok and type(value) == "string") and value or ""
end

-- remember_user_shader — keep the user's own screen shader for later restoration.
-- Args:    host platform adapter; context table (store, state_directory); current string
-- Returns: nothing
local function remember_user_shader(host, context, current)
  local store = context.store
  -- Anything that is not one of ours is the user's own choice (or nothing).
  if not is_generated_path(current, context.state_directory) then
    if store.previous_shader ~= current then
      store.previous_shader = current
      state.write_previous_shader(host, context.state_directory, current)
    end
    return
  end
  -- Ours is active but the memory is gone (new Lua state): recover from the state file.
  if store.previous_shader == nil then
    store.previous_shader = state.read_previous_shader(host, context.state_directory) or ""
  end
end

-- set_screen_shader — write decoration.screen_shader.
-- Args:    host platform adapter; path string ("" disables the shader)
-- Returns: true; or nil, error text
local function set_screen_shader(host, path)
  -- Protected so a failing option never breaks a bind callback.
  local applied, problem = pcall(host.hl.config, { decoration = { screen_shader = path } })
  if not applied then
    return nil, tostring(problem)
  end
  return true
end

-- restore_user_shader — switch our shader off and put the user's own back.
-- Args:    host platform adapter; context table; current string (active shader path)
-- Returns: result table {applied = false}
local function restore_user_shader(host, context, current)
  local store = context.store
  -- Only touch the option when our shader is what is active (or was, in this session).
  if store.shader_path or is_generated_path(current, context.state_directory) then
    local restored, problem = set_screen_shader(host, store.previous_shader or "")
    -- The file is garbage once nothing refers to it.
    if store.shader_path then
      host.remove_file(store.shader_path)
    end
    store.shader_path = nil
    if not restored then
      return { applied = false, problem = problem }
    end
  end
  return { applied = false }
end

-- ensure_shader_file — write the shader file unless the same content is already there.
-- Args:    host platform adapter; path string; text shader source
-- Returns: true; or nil, error text
local function ensure_shader_file(host, path, text)
  -- Same content gives the same name, so an existing file needs no rewrite.
  if host.read_file(path) then
    return true
  end
  return host.write_file(path, text)
end

-- M.sync — bring the screen shader in line with the wanted state.
-- Args:    host platform adapter; context table: settings, filter_name, wanted (boolean),
--          shader_directory, state_directory, store (persistent table)
-- Returns: result table {applied = boolean, path = string or nil, problem = string or nil}
function M.sync(host, context)
  local store = context.store
  local current = read_active_shader(host)
  remember_user_shader(host, context, current)
  if not context.wanted then
    return restore_user_shader(host, context, current)
  end
  -- Build the shader text; a failure leaves the previous screen state untouched.
  local text, problem = M.generate(host, context.shader_directory, context.filter_name,
    context.settings)
  if not text then
    return { applied = false, problem = problem }
  end
  local path = util.join_path(context.state_directory, M.file_name(text))
  local written, write_problem = ensure_shader_file(host, path, text)
  if not written then
    return { applied = false, problem = "cannot write shader: " .. tostring(write_problem) }
  end
  local applied, apply_problem = true, nil
  if current ~= path then
    applied, apply_problem = set_screen_shader(host, path)
  end
  -- Delete the superseded shader file only after the new one is in place.
  if store.shader_path and store.shader_path ~= path then
    host.remove_file(store.shader_path)
  end
  store.shader_path = path
  return { applied = applied == true, path = path, problem = apply_problem }
end

-- M.remove_stale_files — delete generated shaders left over from earlier sessions.
-- Args:    host platform adapter; state_directory string; keep_path string or nil
-- Returns: nothing
-- Notes:   Lists the directory, so call it at load time only, never from a bind callback.
function M.remove_stale_files(host, state_directory, keep_path)
  -- Only files matching our own naming pattern are ever removed.
  for _, name in ipairs(host.list_dir(state_directory)) do
    local path = util.join_path(state_directory, name)
    if name:match(SHADER_FILE_PATTERN) and path ~= keep_path then
      host.remove_file(path)
    end
  end
end

return M
