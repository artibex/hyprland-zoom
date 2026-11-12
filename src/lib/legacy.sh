#!/usr/bin/env bash
# legacy.sh — bash fallback when the Lua engine is absent (decision E8, best effort).
# Used on hyprlang Hyprland and on a Lua config without the engine. Every read-modify-write
# runs under flock(1) on the state directory, so concurrent `zoomctl in` never lose a step
# (the 0.1 race: 20 parallel notches lost 17-19 steps).
# Color filters are NOT available here: they need the engine's generated shaders.

# zoomctl_legacy_tracking_flags — translate a tracking mode to Hyprland's two camera options.
# Args:    $1 tracking mode (centered|edge|margin|follow)
# Returns: 0 always; stdout: "<zoom_rigid> <zoom_detached_camera>" as true/false words
# Globals: none
zoomctl_legacy_tracking_flags() {
  # Mapping verified in the spike (Q7); margin needs the plugin, so it degrades to edge.
  case "$1" in
    centered) printf 'true false\n' ;;
    follow) printf 'false false\n' ;;
    # Edge and margin both use the detached camera (no plugin on this path).
    *) printf 'false true\n' ;;
  esac
}

# zoomctl_legacy_option_pairs — list "option value" lines for everything the fallback applies.
# Args:    $1 zoom factor (canonical) or empty to leave the zoom alone
# Returns: 0 always; stdout: lines like "cursor:zoom_rigid true"
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_option_pairs() {
  local rigid detached disable_antialiasing='false'
  read -r rigid detached <<< "$(zoomctl_legacy_tracking_flags "${ZOOMCTL_VALUE[ZOOM_TRACKING]}")"
  # Crisp magnification switches antialiasing off.
  [ "${ZOOMCTL_VALUE[ZOOM_SMOOTH_IMAGES]}" = 'off' ] && disable_antialiasing='true'
  [ -z "$1" ] || printf 'cursor:zoom_factor %s\n' "$1"
  printf 'cursor:zoom_rigid %s\n' "$rigid"
  # The camera flags come from the tracking-mode table of the spike (Q7).
  printf 'cursor:zoom_detached_camera %s\n' "$detached"
  printf 'cursor:zoom_disable_aa %s\n' "$disable_antialiasing"
  printf 'binds:scroll_event_delay %s\n' "${ZOOMCTL_VALUE[SCROLL_EVENT_DELAY_MS]}"
}

# zoomctl_legacy_lua_config — render the option pairs as one hl.config table (Lua config).
# Args:    $1 zoom factor or empty
# Returns: 0 always; stdout: Lua statement; every value is a validated number or true/false
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_lua_config() {
  local option_name option_value
  local -a cursor_entries=() binds_entries=()
  # Group the options by their Hyprland category as hl.config expects.
  while read -r option_name option_value; do
    case "$option_name" in
      cursor:*) cursor_entries+=("${option_name#cursor:} = $option_value") ;;
      # Everything else belongs to the binds category.
      binds:*) binds_entries+=("${option_name#binds:} = $option_value") ;;
    esac
  done < <(zoomctl_legacy_option_pairs "$1")
  printf 'hl.config({ cursor = { %s }, binds = { %s } })\n' \
    "$(zoomctl_join_by ', ' "${cursor_entries[@]}")" \
    "$(zoomctl_join_by ', ' "${binds_entries[@]}")"
}

# zoomctl_legacy_keyword_batch — render the option pairs as one hyprctl --batch command string.
# Args:    $1 zoom factor or empty
# Returns: 0 always; stdout: "keyword a b ; keyword c d ..."
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_keyword_batch() {
  local option_name option_value
  local -a keywords=()
  # One `keyword` command per option, joined for a single hyprctl process.
  while read -r option_name option_value; do
    keywords+=("keyword $option_name $option_value")
  done < <(zoomctl_legacy_option_pairs "$1")
  # One string for `hyprctl --batch`.
  zoomctl_join_by ' ; ' "${keywords[@]}"
}

# zoomctl_legacy_apply — push the zoom and the fixed options to Hyprland.
# Args:    $1 zoom factor (canonical) or empty to apply only the options
# Returns: 0 applied; 1 Hyprland rejected it
# Globals: reads ZOOMCTL_VALUE, ZOOMCTL_PROBE
zoomctl_legacy_apply() {
  zoomctl_hyprland_probe
  # A Lua config without the engine still understands hl.config through eval.
  if [ "$ZOOMCTL_PROBE" = 'lua-no-engine' ]; then
    zoomctl_hyprland_eval "$(zoomctl_legacy_lua_config "$1")" >/dev/null && return 0
    zoomctl_error "Hyprland rejected the zoom settings"
    # The status of the error report above is the function's result.
    return
  fi
  # hyprlang accepts keywords; one batch keeps it to a single process.
  if ! hyprctl --batch "$(zoomctl_legacy_keyword_batch "$1")" >/dev/null 2>&1; then
    zoomctl_error "Hyprland rejected the zoom settings"
  fi
}

# zoomctl_legacy_current_centi — read the live zoom as hundredths (state file as fallback).
# Args:    none
# Returns: 0 always; stdout: integer hundredths (100 when nothing is known)
# Globals: none
zoomctl_legacy_current_centi() {
  # The shared live-zoom chain (Hyprland, state file, 1.00) feeds the fixed-point math.
  zoomctl_float_to_centi "$(zoomctl_hyprland_live_zoom)" || printf '100\n'
}

# zoomctl_legacy_next_centi — step a zoom value by N notches in the configured model (E12).
# Args:    $1 current hundredths; $2 step hundredths; $3 mode (multiply|add);
#          $4 direction (in|out); $5 notches
# Returns: 0 always; stdout: new hundredths (not yet clamped)
# Globals: none
zoomctl_legacy_next_centi() {
  local current="$1" step="$2" mode="$3" direction="$4" notches="$5"
  local notch_index next
  # One iteration per notch keeps the rounding identical to repeated key presses.
  for ((notch_index = 0; notch_index < notches; notch_index++)); do
    # Multiply: x * (1 + step) or x / (1 + step), rounded to hundredths.
    if [ "$mode" = 'multiply' ] && [ "$direction" = 'in' ]; then
      next=$(((current * (100 + step) + 50) / 100))
    elif [ "$mode" = 'multiply' ]; then
      # Zooming out divides, so in followed by out returns to the same level.
      next=$(((current * 100 + (100 + step) / 2) / (100 + step)))
    elif [ "$direction" = 'in' ]; then
      next=$((current + step))
    else
      # Additive model: out subtracts the same fixed amount.
      next=$((current - step))
    fi
    # Rounding must never swallow a whole notch.
    [ "$direction" = 'in' ] && (( next <= current )) && next=$((current + 1))
    [ "$direction" = 'out' ] && (( next >= current )) && next=$((current - 1))
    current="$next"
  done
  # The caller clamps the result to the configured bounds.
  printf '%s\n' "$current"
}

# zoomctl_legacy_store — clamp, apply and remember a new zoom (lock must be held).
# Args:    $1 target hundredths
# Returns: 0 applied; 1 Hyprland rejected it
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_store() {
  local clamped zoom_text
  # The configured bounds apply to every path that changes the zoom.
  clamped="$(zoomctl_clamp_centi "$1" \
    "$(zoomctl_float_to_centi "${ZOOMCTL_VALUE[ZOOM_MIN]}")" \
    "$(zoomctl_float_to_centi "${ZOOMCTL_VALUE[ZOOM_MAX]}")")"
  zoom_text="$(zoomctl_centi_to_float "$clamped")"
  zoomctl_legacy_apply "$zoom_text" || return 1
  # The state file keeps the C5 view in sync for status and a later engine start.
  zoomctl_state_write zoom "$zoom_text"
}

# zoomctl_legacy_step_locked — zoom in or out by N notches (lock must be held).
# Args:    $1 direction (in|out); $2 notches
# Returns: 0 applied; 1 failed
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_step_locked() {
  local step_centi next_centi
  zoomctl_config_load || return 1
  # The step is converted once; all arithmetic runs in hundredths.
  step_centi="$(zoomctl_float_to_centi "${ZOOMCTL_VALUE[ZOOM_STEP]}")"
  # Read, compute and write happen inside one lock: that is the race fix.
  next_centi="$(zoomctl_legacy_next_centi "$(zoomctl_legacy_current_centi)" "$step_centi" \
    "${ZOOMCTL_VALUE[ZOOM_STEP_MODE]}" "$1" "$2")"
  zoomctl_legacy_store "$next_centi"
}

# zoomctl_legacy_set_locked — jump to an absolute zoom (lock must be held).
# Args:    $1 zoom factor (validated float text)
# Returns: 0 applied; 1 failed
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_set_locked() {
  zoomctl_config_load || return 1
  zoomctl_legacy_store "$(zoomctl_float_to_centi "$1")"
}

# zoomctl_legacy_reset_locked — return to the reset zoom and forget the saved level.
# Args:    none
# Returns: 0 applied; 1 failed
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_reset_locked() {
  zoomctl_config_load || return 1
  zoomctl_legacy_store "$(zoomctl_float_to_centi "${ZOOMCTL_VALUE[ZOOM_RESET]}")" || return 1
  # A reset forgets the level the toggle would otherwise restore.
  zoomctl_state_delete saved_zoom
}

# zoomctl_legacy_toggle_locked — switch between the reset zoom and the last zoom level.
# Args:    none
# Returns: 0 applied or nothing to restore; 1 failed
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_toggle_locked() {
  local current_centi reset_centi saved_zoom
  zoomctl_config_load || return 1
  # Both levels are compared as integer hundredths.
  current_centi="$(zoomctl_legacy_current_centi)"
  reset_centi="$(zoomctl_float_to_centi "${ZOOMCTL_VALUE[ZOOM_RESET]}")"
  # Zoomed in: remember the level and go back to the reset zoom.
  if (( current_centi > reset_centi )); then
    zoomctl_state_write saved_zoom "$(zoomctl_centi_to_float "$current_centi")" || return 1
    zoomctl_legacy_store "$reset_centi"
    # Done: the saved level comes back with the next toggle.
    return
  fi
  # At the reset zoom: restore the remembered level when there is one.
  saved_zoom="$(zoomctl_state_saved_zoom)" || return 0
  zoomctl_legacy_store "$(zoomctl_float_to_centi "$saved_zoom")"
}

# zoomctl_legacy_apply_settings_locked — re-apply the configured options, zoom unchanged.
# Args:    none
# Returns: 0 applied; 1 failed
# Globals: reads ZOOMCTL_VALUE
zoomctl_legacy_apply_settings_locked() {
  zoomctl_config_load || return 1
  zoomctl_legacy_apply ''
}

# zoomctl_legacy_run — run one legacy action under the state lock.
# Args:    $1 action (step|set|reset|toggle|apply_settings); $2.. its arguments
# Returns: the action's status
# Globals: none
zoomctl_legacy_run() {
  local action="$1"
  shift
  # The locked variant of each action holds the whole read-modify-write.
  zoomctl_state_with_lock "zoomctl_legacy_${action}_locked" "$@"
}
