#!/usr/bin/env bash
# hyprland.sh — thin wrappers around hyprctl: probing the compositor, eval/repl, options.
# Every Hyprland call goes through hyprctl on PATH, so tests can put a fake one in front.

# Result of the last zoomctl_hyprland_probe: engine|lua-no-engine|hyprlang|unreachable.
ZOOMCTL_PROBE=''

# zoomctl_hyprland_probe — find out what answers behind hyprctl (cached per process).
# Args:    none
# Returns: 0 always; no stdout; sets ZOOMCTL_PROBE to engine|lua-no-engine|hyprlang|unreachable
# Globals: reads/writes ZOOMCTL_PROBE
# Notes:   engine = HyprZoom loaded; lua-no-engine = Lua config without it; unreachable = no hyprctl
zoomctl_hyprland_probe() {
  local answer
  [ -z "$ZOOMCTL_PROBE" ] || return 0
  # Without hyprctl nothing can be reached.
  command -v hyprctl >/dev/null 2>&1 || { ZOOMCTL_PROBE='unreachable'; return 0; }
  # A failing hyprctl means no instance; legacy Hyprland prints a refusal with status 0.
  answer="$(hyprctl repl 'return type(HyprZoom)' 2>/dev/null)" || {
    ZOOMCTL_PROBE='unreachable'
    return 0
  }
  # The reply tells the three compositor states apart.
  case "$answer" in
    table) ZOOMCTL_PROBE='engine' ;;
    nil) ZOOMCTL_PROBE='lua-no-engine' ;;
    # Legacy Hyprland refuses eval with a text message instead of answering nil.
    *) ZOOMCTL_PROBE='hyprlang' ;;
  esac
}

# zoomctl_hyprland_eval — run Lua code in the compositor and report whether it succeeded.
# Args:    $1 Lua code (built only from validated values, see engine.sh)
# Returns: 0 hyprctl answered "ok"; 1 anything else; stdout: hyprctl's text on failure
# Globals: none
zoomctl_hyprland_eval() {
  local answer
  # hyprctl exits 0 on a legacy config, so the "ok" answer is the only success signal.
  answer="$(hyprctl eval "$1" 2>&1)"
  [ "$answer" = 'ok' ] && return 0
  # Hand the error text to the caller, which decides whether to show it.
  printf '%s\n' "$answer"
  return 1
}

# zoomctl_hyprland_option_number — read a numeric Hyprland option.
# Args:    $1 option name such as cursor:zoom_factor
# Returns: 0 found; 1 unavailable; stdout: the number as hyprctl prints it
# Globals: none
zoomctl_hyprland_option_number() {
  local answer number
  command -v hyprctl >/dev/null 2>&1 || return 1
  # An unknown option or a missing instance makes hyprctl fail.
  answer="$(hyprctl -j getoption "$1" 2>/dev/null)" || return 1
  # The JSON carries the value under "float" or "int" depending on the option type.
  number="$(printf '%s\n' "$answer" | sed -n 's/.*"\(float\|int\)": *\(-\?[0-9.]\+\).*/\2/p')"
  [ -n "$number" ] || return 1
  printf '%s\n' "$number"
}

# zoomctl_hyprland_version — print the running Hyprland version.
# Args:    none
# Returns: 0 found; 1 unavailable; stdout: for example 0.56.2
# Globals: none
zoomctl_hyprland_version() {
  # The shared wiring block owns the parsing (the pacman hook needs it too).
  zoomctl_hyprctl_version_text
}

# zoomctl_hyprland_live_zoom — the current zoom as canonical text, wherever it can be read.
# Args:    none
# Returns: 0 always; stdout: for example 1.50 (live value, else state file, else 1.00)
# Globals: none
zoomctl_hyprland_live_zoom() {
  local zoom_text
  # Hyprland is the source of truth; the C5 state file only covers a missing hyprctl answer.
  zoom_text="$(zoomctl_hyprland_option_number cursor:zoom_factor)" ||
    zoom_text="$(zoomctl_state_read zoom)" || zoom_text='1.00'
  zoomctl_format_float "$zoom_text" || printf '1.00\n'
}

# zoomctl_hyprland_plugin_loaded — test whether a Hyprland plugin is loaded.
# Args:    $1 plugin name
# Returns: 0 loaded; 1 not loaded or Hyprland unreachable
# Globals: none
zoomctl_hyprland_plugin_loaded() {
  command -v hyprctl >/dev/null 2>&1 || return 1
  # `hyprctl plugin list` names every loaded plugin.
  hyprctl plugin list 2>/dev/null | grep -qi -- "$1"
}
