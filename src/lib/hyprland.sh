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
  hyprctl keyword cursor:zoom_factor "$zoom_value" >/dev/null
}

zoomctl_hyprland_cursor_position() {
  local raw_output
  local normalized_output

  zoomctl_hyprland_require || return 1
  raw_output="$(hyprctl cursorpos 2>/dev/null || true)"
  normalized_output="$(printf '%s\n' "$raw_output" | sed 's/[^0-9.+-]/ /g')"

  set -- $normalized_output
  [ $# -ge 2 ] || return 1

  printf '%s %s\n' "$1" "$2"
}

zoomctl_hyprland_active_monitor_geometry() {
  zoomctl_hyprland_require || return 1

  hyprctl monitors 2>/dev/null | awk '
    function flush_block() {
      if (focused && geometry != "") {
        print geometry
        exit
      }
      focused = 0
      geometry = ""
      monitor_open = 0
    }

    /^Monitor / {
      if (monitor_open) {
        flush_block()
      }
      monitor_open = 1
      focused = 0
      geometry = ""
      next
    }

    monitor_open && /focused:[[:space:]]*yes/ {
      focused = 1
      next
    }

    monitor_open && / at / {
      geometry = $0
      next
    }

    NF == 0 {
      flush_block()
    }

    END {
      if (focused && geometry != "") {
        print geometry
      }
    }
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

zoomctl_hyprland_center_cursor() {
  local cursor_position
  local geometry
  local parsed_geometry
  local cursor_x
  local cursor_y
  local monitor_width
  local monitor_height
  local monitor_x
  local monitor_y
  local target_x
  local target_y
  local delta_x
  local delta_y

  [ "${ZOOMCTL_CENTER_CURSOR:-0}" = '1' ] || return 0

  cursor_position="$(zoomctl_hyprland_cursor_position)" || return 0
  geometry="$(zoomctl_hyprland_active_monitor_geometry)" || return 0
  parsed_geometry="$(zoomctl_hyprland_parse_geometry "$geometry")" || return 0

  read -r cursor_x cursor_y <<EOF
$cursor_position
EOF

  read -r monitor_width monitor_height monitor_x monitor_y <<EOF
$parsed_geometry
EOF

  delta_x="$(awk -v monitor_x="$monitor_x" -v monitor_width="$monitor_width" -v cursor_x="$cursor_x" 'BEGIN { printf "%.0f\n", (monitor_x + (monitor_width / 2)) - cursor_x }')"
  delta_y="$(awk -v monitor_y="$monitor_y" -v monitor_height="$monitor_height" -v cursor_y="$cursor_y" 'BEGIN { printf "%.0f\n", (monitor_y + (monitor_height / 2)) - cursor_y }')"

  hyprctl dispatch movecursor "$delta_x" "$delta_y" >/dev/null 2>&1 || true
}