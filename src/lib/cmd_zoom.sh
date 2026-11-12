#!/usr/bin/env bash
# cmd_zoom.sh — the zoom-action commands: in, out, zoom, toggle, reset, filter, tracking, preview.
# Each command validates its arguments, then forwards to the engine (C4) or falls back to
# the flock-serialised bash path (E8). Exit codes: 0 ok, 1 error, 2 usage.

# Highest notch count one call accepts; keeps a typo from spinning the loop.
ZOOMCTL_MAX_NOTCHES=100

# zoomctl_parse_notches — validate an optional notch count.
# Args:    $1 count text (an empty string is invalid, the caller supplies the default 1)
# Returns: 0 valid; 2 not a whole number from 1 to ZOOMCTL_MAX_NOTCHES; stdout: the count
# Globals: reads ZOOMCTL_MAX_NOTCHES
zoomctl_parse_notches() {
  local notches="$1"
  # Digits only, so the value is safe inside Lua code and bash arithmetic.
  if [[ "$notches" =~ ^[0-9]{1,3}$ ]]; then
    notches=$((10#$notches))
    (( notches >= 1 && notches <= ZOOMCTL_MAX_NOTCHES )) && { printf '%s\n' "$notches"; return 0; }
  fi
  # Anything else, including an empty string, is a usage mistake.
  zoomctl_usage_error "notches must be a whole number from 1 to $ZOOMCTL_MAX_NOTCHES"
}

# zoomctl_command_step — shared body of `in` and `out`.
# Args:    $1 direction (in|out); $2 optional notch count
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_step() {
  local direction="$1"
  local notches
  # Only the optional notch count may follow the direction.
  [ "$#" -le 2 ] || { zoomctl_usage_error "$direction takes at most one argument"; return 2; }
  notches="$(zoomctl_parse_notches "${2-1}")" || return 2
  # zoom_in / zoom_out in the engine; the fallback steps by the same notch count.
  zoomctl_engine_forward "$(zoomctl_lua_call "zoom_$direction" "$notches")" \
    zoomctl_legacy_run step "$direction" "$notches"
}

# zoomctl_command_in — zoom in by N notches.
# Args:    $1 optional notch count
# Returns: see zoomctl_command_step
# Globals: none
zoomctl_command_in() {
  zoomctl_command_step in "$@"
}

# zoomctl_command_out — zoom out by N notches.
# Args:    $1 optional notch count
# Returns: see zoomctl_command_step
# Globals: none
zoomctl_command_out() {
  zoomctl_command_step out "$@"
}

# zoomctl_command_zoom — jump to an absolute zoom factor.
# Args:    $1 factor (1.00-10.00)
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_zoom() {
  local factor
  [ "$#" -eq 1 ] || { zoomctl_usage_error "zoom needs exactly one factor"; return 2; }
  # The schema supplies the allowed zoom range.
  zoomctl_schema_load || return 1
  # The schema's zoom range (1..10) bounds absolute factors too.
  factor="$(zoomctl_schema_validate ZOOM_MAX "$1")" || {
    zoomctl_error "'$1' is not a zoom factor ($(zoomctl_schema_allowed_text ZOOM_MAX))"
    return 1
  }
  # Engine and fallback both clamp the factor to the configured bounds.
  zoomctl_engine_forward "$(zoomctl_lua_call set_zoom "$factor")" \
    zoomctl_legacy_run set "$factor"
}

# zoomctl_command_toggle — switch between the reset zoom and the last zoom level.
# Args:    none
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_toggle() {
  [ "$#" -eq 0 ] || { zoomctl_usage_error "toggle takes no arguments"; return 2; }
  zoomctl_engine_forward "$(zoomctl_lua_call toggle)" zoomctl_legacy_run toggle
}

# zoomctl_command_reset — go back to the reset zoom.
# Args:    none
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_reset() {
  [ "$#" -eq 0 ] || { zoomctl_usage_error "reset takes no arguments"; return 2; }
  zoomctl_engine_forward "$(zoomctl_lua_call reset)" zoomctl_legacy_run reset
}

# zoomctl_legacy_filter_unsupported — explain that filters need the engine.
# Args:    none
# Returns: 1 always; stderr: the explanation
# Globals: none
zoomctl_legacy_filter_unsupported() {
  zoomctl_error "colour filters are not supported on the legacy config; they need the Lua engine"
}

# zoomctl_parse_filter_name — validate a filter name against the schema enum.
# Args:    $1 filter name
# Returns: 0 known; 1 unknown (message on stderr); stdout: the canonical name
# Globals: reads the schema tables
zoomctl_parse_filter_name() {
  # The error lists the valid names so a typo is fixed at once.
  zoomctl_schema_validate FILTER "$1" ||
    zoomctl_error "unknown filter '$1' ($(zoomctl_schema_allowed_text FILTER))"
}

# zoomctl_parse_filter_action — validate the argument of `filter`.
# Args:    $1 on|off|toggle|<filter name> (default toggle)
# Returns: 0 valid; 1 unknown; stdout: the canonical action word
# Globals: reads the schema tables
zoomctl_parse_filter_action() {
  local action="${1:-toggle}"
  zoomctl_schema_load || return 1
  # Switch words first, then the filter names of the schema enum.
  case "${action,,}" in
    on|off|toggle) printf '%s\n' "${action,,}" ;;
    *) zoomctl_parse_filter_name "$action" ;;
  esac
}

# zoomctl_command_filter — switch the colour filter on, off, or to a named filter.
# Args:    $1 optional on|off|toggle|<filter name>
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_filter() {
  local action
  [ "$#" -le 1 ] || { zoomctl_usage_error "filter takes at most one argument"; return 2; }
  # The word is validated against the schema before it can reach Lua.
  action="$(zoomctl_parse_filter_action "${1:-}")" || return 1
  # The action word is a whitelisted token, rendered as a safe Lua string.
  zoomctl_engine_forward "$(zoomctl_lua_call filter "$(zoomctl_lua_quote "$action")")" \
    zoomctl_legacy_filter_unsupported
}

# zoomctl_command_tracking — choose how the zoomed view follows the pointer.
# Args:    $1 centered|edge|margin|follow
# Returns: 0 saved; 1 invalid; 2 usage error
# Globals: none
zoomctl_command_tracking() {
  [ "$#" -eq 1 ] || { zoomctl_usage_error "tracking needs one mode"; return 2; }
  # Tracking is a persisted setting, so it goes through the single config writer.
  zoomctl_command_set ZOOM_TRACKING "$1"
}

# zoomctl_command_preview — apply settings live without saving, or end the preview.
# Args:    $1.. KEY=VALUE pairs, or --end
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_preview() {
  zoomctl_schema_load || return 1
  # --end must stand alone; anything else is a list of pairs.
  if [ "${1:-}" = '--end' ]; then
    [ "$#" -eq 1 ] || { zoomctl_usage_error "preview --end takes no further arguments"; return 2; }
    zoomctl_engine_preview_end
    # Nothing follows --end; hand back the status of the call above.
    return
  fi
  zoomctl_engine_preview "$@"
}
