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

# zoomctl_status_engine_word — the C6 engine value when the engine itself is not answering.
# Args:    none
# Returns: 0 always; stdout: missing (Lua config, engine not loaded), legacy (hyprlang
#          config, bash fallback) or unreachable (no compositor answering)
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_status_engine_word() {
  zoomctl_hyprland_probe
  # The probe already distinguishes the three cases; only the words differ.
  case "$ZOOMCTL_PROBE" in
    unreachable) printf 'unreachable\n' ;;  # no Hyprland session to talk to
    lua-no-engine) printf 'missing\n' ;;    # `zoomctl setup` + reload would load it
    *) printf 'legacy\n' ;;                 # hyprlang config: the bash fallback acts
  esac
}

# zoomctl_status_plugin_word — report whether the optional hyprzoom plugin is loaded.
# Args:    none
# Returns: 0 always; stdout: loaded | missing
# Globals: none
zoomctl_status_plugin_word() {
  # The plugin is only reported here; margin tracking is the engine's business.
  if zoomctl_hyprland_plugin_loaded hyprzoom; then printf 'loaded\n'; else printf 'missing\n'; fi
}

# zoomctl_status_saved_zoom — the toggle's remembered level, else the reset zoom.
# Args:    none (config must be loaded)
# Returns: 0 always; stdout: zoom factor text
# Globals: reads ZOOMCTL_VALUE
zoomctl_status_saved_zoom() {
  # The reset zoom is always numeric, so the settings window can parse the value.
  zoomctl_state_saved_zoom || printf '%s\n' "${ZOOMCTL_VALUE[ZOOM_RESET]:-1.00}"
}

# zoomctl_status_scroll_delay — the live scroll_event_delay, else the configured one.
# Args:    none (config must be loaded)
# Returns: 0 always; stdout: milliseconds
# Globals: reads ZOOMCTL_VALUE
zoomctl_status_scroll_delay() {
  # The live delay shows whether the engine or the bind file applied it.
  zoomctl_hyprland_option_number binds:scroll_event_delay ||
    printf '%s\n' "${ZOOMCTL_VALUE[SCROLL_EVENT_DELAY_MS]:-0}"
}

# zoomctl_status_fallback — print the C6 keys computed by the CLI alone.
# Args:    none
# Returns: 0 printed; 1 the configuration could not be loaded (message on stderr)
# Globals: reads ZOOMCTL_VALUE
zoomctl_status_fallback() {
  zoomctl_config_load || return 1
  printf 'engine=%s\n' "$(zoomctl_status_engine_word)"
  # Package and compositor version identify the setup in bug reports.
  printf 'version=%s\n' "$(zoomctl_version)"
  printf 'hyprland=%s\n' "$(zoomctl_hyprland_version || printf 'unknown')"
  printf 'zoom=%s\n' "$(zoomctl_hyprland_live_zoom)"
  # The toggle's remembered level, then the tracking configuration.
  printf 'saved_zoom=%s\n' "$(zoomctl_status_saved_zoom)"
  printf 'tracking=%s\n' "${ZOOMCTL_VALUE[ZOOM_TRACKING]}"
  printf 'tracking_effective=%s\n' \
    "$(zoomctl_status_effective_tracking "${ZOOMCTL_VALUE[ZOOM_TRACKING]}")"
  # The margin width only matters for margin tracking but is always reported.
  printf 'edge_margin=%s\n' "${ZOOMCTL_VALUE[ZOOM_EDGE_MARGIN]}"
  printf 'plugin=%s\n' "$(zoomctl_status_plugin_word)"
  # Filters need the engine, so none is ever active on the fallback path.
  printf 'filter=%s\nfilter_active=off\nfilter_shader=none\n' "${ZOOMCTL_VALUE[FILTER]}"
  printf 'scroll_event_delay_ms=%s\n' "$(zoomctl_status_scroll_delay)"
}

# zoomctl_status_porcelain — print the C6 status keys, from the engine when it is loaded.
# Args:    none
# Returns: 0 printed; 1 neither the engine nor the fallback could answer (message on stderr)
# Globals: none
zoomctl_status_porcelain() {
  # The engine knows the truth (effective tracking, shader path); ask it first.
  zoomctl_engine_status_lines || zoomctl_status_fallback
}

# zoomctl_status_human — print the status as an aligned, readable block.
# Args:    none
# Returns: 0 printed; 1 the status could not be read (message on stderr)
# Globals: none
zoomctl_status_human() {
  local line porcelain_text
  # A failing status must fail this command too, so it is read before any heading is printed.
  porcelain_text="$(zoomctl_status_porcelain)" || return 1
  printf 'Hyprland zoom status\n'
  # Reuse the porcelain so both views can never disagree.
  while IFS= read -r line; do
    printf '  %-22s %s\n' "${line%%=*}" "${line#*=}"
  done <<< "$porcelain_text"
}
