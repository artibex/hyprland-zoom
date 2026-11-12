#!/usr/bin/env bash
# doctor.sh — `zoomctl doctor`: human-readable health checks (contract C4).
# Each check prints "[ok|info|warn|FAIL] text" lines and returns 1 only for a real failure.

# Oldest Hyprland release with the Lua config manager the engine needs.
ZOOMCTL_MIN_HYPRLAND_MAJOR=0
ZOOMCTL_MIN_HYPRLAND_MINOR=55

# zoomctl_doctor_line — print one check result line.
# Args:    $1 level (ok|info|warn|FAIL); $2 text
# Returns: 0 always; stdout: the formatted line
# Globals: none
zoomctl_doctor_line() {
  # Fixed-width level tag keeps the output scannable.
  printf '[%-4s] %s\n' "$1" "$2"
}

# zoomctl_modifier_mask — compute Hyprland's modifier bit mask for a canonical modifier list.
# Args:    $1 modifiers like "SUPER + ALT"
# Returns: 0 always; stdout: the mask (SUPER 64, ALT 8, CTRL 4, SHIFT 1)
# Globals: none
zoomctl_modifier_mask() {
  local mask=0 pair
  # Each modifier named in the text contributes its bit (name:bit pairs).
  for pair in SUPER:64 ALT:8 CTRL:4 SHIFT:1; do
    if [[ "$1" == *"${pair%%:*}"* ]]; then mask=$((mask + ${pair#*:})); fi
  done
  printf '%s\n' "$mask"
}

# zoomctl_doctor_hyprland — check that a compositor answers and is new enough.
# Args:    none
# Returns: 0 reachable; 1 not reachable
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_doctor_hyprland() {
  local version major minor
  zoomctl_hyprland_probe
  # Nothing else can be checked without a compositor.
  if [ "$ZOOMCTL_PROBE" = 'unreachable' ]; then
    zoomctl_doctor_line FAIL "Hyprland is not reachable (hyprctl missing or no running session)"
    return 1
  fi
  # A missing version is odd but not fatal.
  version="$(zoomctl_hyprland_version)" || {
    zoomctl_doctor_line warn "Hyprland version unknown"
    return 0
  }
  # Only the first two version components matter for the 0.55 threshold.
  IFS=. read -r major minor _ <<< "$version"
  if (( major > ZOOMCTL_MIN_HYPRLAND_MAJOR || minor >= ZOOMCTL_MIN_HYPRLAND_MINOR )); then
    # A new enough release ships the Lua config manager.
    zoomctl_doctor_line ok "Hyprland $version"
  else
    zoomctl_doctor_line warn "Hyprland $version is older than 0.55: legacy fallback only"
  fi
}

# zoomctl_doctor_engine — report the config manager and whether the engine is loaded.
# Args:    none
# Returns: 0 fine or not applicable; 1 Lua config without the engine
# Globals: reads ZOOMCTL_PROBE
zoomctl_doctor_engine() {
  # Each probe state has its own explanation and fix.
  case "$ZOOMCTL_PROBE" in
    engine) zoomctl_doctor_line ok "Lua config, engine loaded" ;;
    lua-no-engine)
      zoomctl_doctor_line FAIL \
        "Lua config, but the engine is not loaded: run 'zoomctl setup', reload Hyprland"
      # A missing engine is the one failure users can fix themselves.
      return 1 ;;
    hyprlang) zoomctl_doctor_line warn "legacy hyprlang config: no filters or live preview" ;;
  esac
  return 0
}

# zoomctl_doctor_include — check that the user's Hyprland config loads the engine.
# Args:    none
# Returns: 0 fine or only a warning; 1 hyprland.lua exists without the include
# Globals: reads the target-home variables
zoomctl_doctor_include() {
  local lua_config conf_config
  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 0
  # The legacy conf lives next to hyprland.lua.
  conf_config="$(zoomctl_hyprland_config_file)"
  # Prefer the Lua file, as Hyprland does.
  if [ -f "$lua_config" ]; then
    if zoomctl_file_has_line_where "$lua_config" zoomctl_is_engine_include_line; then
      zoomctl_doctor_line ok "engine include present in $lua_config"
    # A leftover 0.1 line still works through the shim but should be migrated.
    elif zoomctl_file_has_line_where "$lua_config" zoomctl_is_legacy_lua_include_line; then
      zoomctl_doctor_line warn "0.1 include in $lua_config: run 'zoomctl setup' to migrate it"
    else
      # A Lua config without the include never loads the engine.
      zoomctl_doctor_line FAIL "no engine include in $lua_config: run 'zoomctl setup'"
      return 1
    fi
  elif zoomctl_file_has_line_where "$conf_config" zoomctl_is_conf_include_line; then
    # Without hyprland.lua the legacy conf carries the include.
    zoomctl_doctor_line ok "binds include present in $conf_config"
  else
    zoomctl_doctor_line warn "no Hyprland config with a hyprland-zoom include: run 'zoomctl setup'"
  fi
}

# zoomctl_doctor_config — load the configuration and surface every warning.
# Args:    none
# Returns: 0 always (problems are warnings: bad values fall back by design)
# Globals: none
zoomctl_doctor_config() {
  local problems line
  problems="$(zoomctl_config_load 2>&1 >/dev/null)"
  # Everything the loader complained about becomes one warning line.
  if [ -z "$problems" ]; then
    zoomctl_doctor_line ok "configuration is valid ($(zoomctl_user_config_file))"
    return 0
  fi
  # Every complaint of the loader becomes its own warning line.
  while IFS= read -r line; do
    zoomctl_doctor_line warn "$line"
  done <<< "$problems"
}

# zoomctl_doctor_plugin — report the optional hyprzoom plugin.
# Args:    none
# Returns: 0 always
# Globals: none
zoomctl_doctor_plugin() {
  # The plugin is optional, so absence is information, not a problem.
  if zoomctl_hyprland_plugin_loaded hyprzoom; then
    zoomctl_doctor_line ok "hyprzoom plugin loaded (margin tracking available)"
  else
    zoomctl_doctor_line info "hyprzoom plugin not loaded (optional; margin mode falls back to edge)"
  fi
}

# zoomctl_doctor_duplicate_binds — list keys bound more than once under the zoom modifiers.
# Args:    $1 modifier mask; $2 space separated key names (case-insensitive)
# Returns: 0 always; stdout: lines "<key>: <description>, <description>" per clashing key
# Globals: none
zoomctl_doctor_duplicate_binds() {
  local awk_program
  # The awk program sits in a heredoc so it reads as a small script of its own.
  awk_program="$(cat <<'AWK'
# flush — count the finished bind block when it matches the modifier mask and a wanted key.
function flush() {
  if (bind_mask == mask && (tolower(bind_key) in wanted)) {
    count[bind_key]++
    names[bind_key] = names[bind_key] (count[bind_key] > 1 ? ", " : "") bind_desc
  }
  bind_mask = ""; bind_key = ""; bind_desc = "(no description)"
}
BEGIN { n = split(tolower(keys), list, " "); for (i = 1; i <= n; i++) wanted[list[i]] = 1 }
/^bind/ { flush() }
/^\tmodmask:/ { bind_mask = $2 }
/^\tkey:/ { bind_key = $2 }
/^\tdescription: ./ { sub(/^\tdescription: /, ""); bind_desc = $0 }
END { flush(); for (k in count) if (count[k] > 1) print k ": " names[k] }
AWK
)"
  # `hyprctl binds` prints blocks of tab-indented fields separated by blank lines.
  hyprctl binds 2>/dev/null | awk -v mask="$1" -v keys="$2" "$awk_program"
}

# zoomctl_doctor_binds — warn when another bind shares a zoom shortcut (Omarchy group cycling etc.).
# Args:    none (config must be loaded)
# Returns: 0 always
# Globals: reads ZOOMCTL_VALUE
zoomctl_doctor_binds() {
  local mask keys clash
  [ "$ZOOMCTL_PROBE" = 'unreachable' ] && return 0
  # Hyprland reports binds by modifier bit mask, not by name.
  mask="$(zoomctl_modifier_mask "${ZOOMCTL_VALUE[BIND_MODIFIERS]}")"
  keys="mouse_up mouse_down mouse:274 ${ZOOMCTL_VALUE[BIND_KEY_IN]} ${ZOOMCTL_VALUE[BIND_KEY_OUT]}"
  keys+=" ${ZOOMCTL_VALUE[BIND_KEY_TOGGLE]} ${ZOOMCTL_VALUE[BIND_KEY_FILTER]}"
  # Every configured key is checked next to the wheel and middle-click binds.
  keys+=" ${ZOOMCTL_VALUE[BIND_KEY_SETTINGS]}"
  clash="$(zoomctl_doctor_duplicate_binds "$mask" "$keys")"
  # No duplicates under the zoom modifiers means no conflicts.
  if [ -z "$clash" ]; then
    zoomctl_doctor_line ok "no conflicting binds on ${ZOOMCTL_VALUE[BIND_MODIFIERS]}"
    return 0
  fi
  # One warning per clashing key keeps the output scannable.
  while IFS= read -r clash_line; do
    zoomctl_doctor_line warn "bound more than once: $clash_line"
  done <<< "$clash"
}

# zoomctl_doctor_scroll_delay — compare Hyprland's scroll_event_delay with the setting (E2).
# Args:    none (config must be loaded)
# Returns: 0 always
# Globals: reads ZOOMCTL_VALUE
zoomctl_doctor_scroll_delay() {
  local live_delay wanted_delay="${ZOOMCTL_VALUE[SCROLL_EVENT_DELAY_MS]}"
  live_delay="$(zoomctl_hyprland_option_number binds:scroll_event_delay)" || return 0
  # A different live value means fast scroll notches are still being dropped.
  if [ "$live_delay" = "$wanted_delay" ]; then
    zoomctl_doctor_line ok "scroll_event_delay is ${live_delay} ms"
  else
    zoomctl_doctor_line warn \
      "scroll_event_delay is $live_delay ms, expected $wanted_delay: fast scrolling loses notches"
  fi
}

# zoomctl_doctor_settings_app — check that the settings window can be started.
# Args:    none
# Returns: 0 always
# Globals: none
zoomctl_doctor_settings_app() {
  # The app is optional for the CLI, so a missing one is only a warning.
  if zoomctl_find_settings_app >/dev/null; then
    zoomctl_doctor_line ok "settings app found ($(zoomctl_find_settings_app))"
  else
    zoomctl_doctor_line warn "hyprland-zoom-settings not found ('zoomctl ui' will not work)"
  fi
}

# zoomctl_command_doctor — run every check and summarise.
# Args:    none
# Returns: 0 no failed check; 1 at least one failed; 2 usage error
# Globals: none
zoomctl_command_doctor() {
  local failures=0
  [ "$#" -eq 0 ] || { zoomctl_usage_error "doctor takes no arguments"; return 2; }
  # The binds and scroll checks read the effective settings.
  # Config warnings are reported by their own check below, not twice.
  zoomctl_config_load 2>/dev/null || return 1
  printf 'zoomctl %s\n' "$ZOOMCTL_VERSION"
  # Order: environment, engine, wiring, settings, extras.
  zoomctl_doctor_hyprland || failures=$((failures + 1))
  zoomctl_doctor_engine || failures=$((failures + 1))
  zoomctl_doctor_include || failures=$((failures + 1))
  # The remaining checks are informational and never fail the run.
  zoomctl_doctor_config
  zoomctl_doctor_plugin
  zoomctl_doctor_binds
  # The live scroll delay shows whether the engine applied decision E2.
  zoomctl_doctor_scroll_delay
  zoomctl_doctor_settings_app
  # The exit code lets scripts and bug reports rely on the verdict.
  (( failures == 0 )) && return 0
  printf '%s problem(s) need attention.\n' "$failures"
  return 1
}
