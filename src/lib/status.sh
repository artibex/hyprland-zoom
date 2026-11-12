#!/usr/bin/env bash
# status.sh — `zoomctl status` and its porcelain form (contract C6).
# With the engine loaded its own answer is passed through; otherwise the CLI computes what it
# can (config values, live zoom, saved state) and reports engine=legacy or engine=missing.

# zoomctl_status_effective_tracking — the tracking mode that really applies without the engine.
# Args:    $1 configured tracking mode
# Returns: 0 always; stdout: the effective mode (margin degrades to edge, see E5)
# Globals: none
zoomctl_status_effective_tracking() {
  # The fallback path has no margin implementation.
  [ "$1" = 'margin' ] && printf 'edge\n' || printf '%s\n' "$1"
}

# zoomctl_status_live_zoom — the current zoom as canonical text.
# Args:    none
# Returns: 0 always; stdout: for example 1.50 (live value, else state file, else 1.00)
# Globals: none
zoomctl_status_live_zoom() {
  local zoom_text
  # Hyprland first, then the C5 state file, finally the neutral zoom.
  zoom_text="$(zoomctl_hyprland_option_number cursor:zoom_factor)" ||
    zoom_text="$(zoomctl_state_read zoom)" || zoom_text='1.00'
  zoomctl_format_float "$zoom_text" || printf '1.00\n'
}

# zoomctl_status_engine_word — the C6 engine value when the engine itself is not answering.
# Args:    none
# Returns: 0 always; stdout: legacy (Hyprland reachable, fallback path) or missing
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_status_engine_word() {
  zoomctl_hyprland_probe
  # Without a reachable compositor there is nothing to fall back on.
  [ "$ZOOMCTL_PROBE" = 'unreachable' ] && printf 'missing\n' || printf 'legacy\n'
}

# zoomctl_status_fallback — print the C6 keys computed by the CLI alone.
# Args:    none
# Returns: 0 always; stdout: KEY=VALUE lines in C6 order
# Globals: reads ZOOMCTL_VALUE
zoomctl_status_fallback() {
  local plugin_state='missing' saved_zoom delay_ms
  zoomctl_config_load || return 1
  # The plugin is only reported here; margin tracking is the engine's business.
  zoomctl_hyprland_plugin_loaded hyprzoom && plugin_state='loaded'
  saved_zoom="$(zoomctl_state_saved_zoom)" || saved_zoom="${ZOOMCTL_VALUE[ZOOM_RESET]:-1.00}"
  # The live delay shows whether the engine or the bind file applied it.
  delay_ms="$(zoomctl_hyprland_option_number binds:scroll_event_delay)" ||
    delay_ms="${ZOOMCTL_VALUE[SCROLL_EVENT_DELAY_MS]:-0}"
  printf 'engine=%s\n' "$(zoomctl_status_engine_word)"
  # Package and compositor version identify the setup in bug reports.
  printf 'version=%s\n' "$ZOOMCTL_VERSION"
  printf 'hyprland=%s\n' "$(zoomctl_hyprland_version || printf 'unknown')"
  printf 'zoom=%s\n' "$(zoomctl_status_live_zoom)"
  # The toggle's remembered level, then the tracking configuration.
  printf 'saved_zoom=%s\n' "$saved_zoom"
  printf 'tracking=%s\n' "${ZOOMCTL_VALUE[ZOOM_TRACKING]}"
  printf 'tracking_effective=%s\n' \
    "$(zoomctl_status_effective_tracking "${ZOOMCTL_VALUE[ZOOM_TRACKING]}")"
  printf 'edge_margin=%s\n' "${ZOOMCTL_VALUE[ZOOM_EDGE_MARGIN]}"
  printf 'plugin=%s\n' "$plugin_state"
  # Filters need the engine, so none is ever active on the fallback path.
  printf 'filter=%s\nfilter_active=off\nfilter_shader=none\n' "${ZOOMCTL_VALUE[FILTER]}"
  printf 'scroll_event_delay_ms=%s\n' "$delay_ms"
}

# zoomctl_status_porcelain — print the C6 status keys, from the engine when it is loaded.
# Args:    none
# Returns: 0 always; stdout: KEY=VALUE lines
# Globals: none
zoomctl_status_porcelain() {
  # The engine knows the truth (effective tracking, shader path); ask it first.
  zoomctl_engine_status_lines || zoomctl_status_fallback
}

# zoomctl_status_human — print the status as an aligned, readable block.
# Args:    none
# Returns: 0 always; stdout: text
# Globals: none
zoomctl_status_human() {
  local line
  printf 'Hyprland zoom status\n'
  # Reuse the porcelain so both views can never disagree.
  while IFS= read -r line; do
    printf '  %-22s %s\n' "${line%%=*}" "${line#*=}"
  done < <(zoomctl_status_porcelain)
}
