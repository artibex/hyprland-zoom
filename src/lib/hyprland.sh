#!/usr/bin/env bash

zoomctl_hyprland_require() {
  command -v hyprctl >/dev/null 2>&1 || {
    printf 'zoomctl: hyprctl is not available, run this inside a Hyprland session\n' >&2
    return 1
  }
}

zoomctl_hyprland_get_zoom() {
  local raw_output
  local zoom_value

  zoomctl_hyprland_require || return 1

  raw_output="$(hyprctl -j getoption cursor:zoom_factor 2>/dev/null || true)"
  zoom_value="$(printf '%s\n' "$raw_output" | sed -n 's/.*"float":[[:space:]]*\([-0-9.][0-9.]*\).*/\1/p' | head -n 1)"

  if [ -z "$zoom_value" ]; then
    raw_output="$(hyprctl getoption cursor:zoom_factor 2>/dev/null || true)"
    zoom_value="$(printf '%s\n' "$raw_output" | sed -n 's/.*float[^0-9-]*\([-0-9.][0-9.]*\).*/\1/p' | head -n 1)"
  fi

  [ -n "$zoom_value" ] || return 1
  printf '%s\n' "$zoom_value"
}

zoomctl_hyprland_set_zoom() {
  local zoom_value

  zoomctl_hyprland_require || return 1
  zoom_value="$(zoomctl_format_float "$1")"

  # Hyprland 0.55+ moved to a Lua-based config parser: `hyprctl keyword` is
  # rejected for these options ("keyword can't work with non-legacy parsers.
  # Use eval.") and silently does nothing, so set the option through the Lua
  # config API. On older Hyprland `hyprctl eval` does not exist yet, so fall
  # back to `hyprctl keyword` there. The exit code of the last command
  # executed propagates, so a genuine failure is never masked.
  hyprctl eval "hl.config({ cursor = { zoom_factor = $zoom_value } })" >/dev/null 2>&1 \
    || hyprctl keyword cursor:zoom_factor "$zoom_value" >/dev/null
}

zoomctl_hyprland_active_monitor_geometry() {
  zoomctl_hyprland_require || return 1

  hyprctl monitors 2>/dev/null | awk '
    /^Monitor / { geometry = "" }
    / at / && geometry == "" { geometry = $0 }
    /focused:[[:space:]]*yes/ { if (geometry != "") answer = geometry }
    END { if (answer != "") print answer }
  '
}

zoomctl_hyprland_parse_geometry() {
  local geometry="$1"
  local dimensions
  local coordinates

  dimensions="$(printf '%s\n' "$geometry" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\)x\([0-9][0-9]*\)@.*$/\1 \2/p')"
  coordinates="$(printf '%s\n' "$geometry" | sed -n 's/.* at \(-\?[0-9][0-9]*\)\([x,]\)\(-\?[0-9][0-9]*\).*/\1 \3/p')"

  [ -n "$dimensions" ] && [ -n "$coordinates" ] || return 1
  printf '%s %s\n' "$dimensions" "$coordinates"
}

# Pins the mouse cursor to the middle of the active monitor. Hyprland's
# cursor zoom always magnifies the area around the cursor, so keeping the
# cursor at the screen center keeps the magnified view centered too.
zoomctl_hyprland_center_cursor() {
  local geometry
  local parsed_geometry
  local monitor_width
  local monitor_height
  local monitor_x
  local monitor_y
  local target_x
  local target_y

  [ "${ZOOMCTL_CENTER_CURSOR:-0}" = '1' ] || return 0

  geometry="$(zoomctl_hyprland_active_monitor_geometry)" || return 0
  parsed_geometry="$(zoomctl_hyprland_parse_geometry "$geometry")" || return 0

  read -r monitor_width monitor_height monitor_x monitor_y <<EOF
$parsed_geometry
EOF

  # hyprctl dispatch movecursor takes an ABSOLUTE position, not a delta.
  target_x="$(awk -v monitor_x="$monitor_x" -v monitor_width="$monitor_width" 'BEGIN { printf "%.0f\n", monitor_x + (monitor_width / 2) }')"
  target_y="$(awk -v monitor_y="$monitor_y" -v monitor_height="$monitor_height" 'BEGIN { printf "%.0f\n", monitor_y + (monitor_height / 2) }')"

  # Hyprland 0.55+ (Lua config parser) rejects `hyprctl dispatch movecursor`
  # ("dispatch in lua is a shorthand for hl.dispatch(...)"), so use the Lua
  # dispatcher; fall back to the legacy dispatch on older Hyprland. Best-effort
  # by design: a failed recentre must never fail the zoom action itself.
  hyprctl eval "hl.dispatch(hl.dsp.cursor.move({ x = $target_x, y = $target_y }))" >/dev/null 2>&1 \
    || hyprctl dispatch movecursor "$target_x" "$target_y" >/dev/null 2>&1 || true
}