#!/usr/bin/env bash
# engine.sh — forwarding to the in-compositor Lua engine (contract C3/C4, decision E1).
# Lua code is assembled ONLY from values that passed a validator, and every string literal
# is additionally restricted to a safe character set, so config text can never become code.

# zoomctl_lua_quote — render a string as a Lua double-quoted literal, or refuse.
# Args:    $1 text (validated value such as smart-invert, "SUPER + ALT", mouse:274)
# Returns: 0 safe; 1 contains a character outside [A-Za-z0-9_:. +-]; stdout: "text"
# Globals: none
zoomctl_lua_quote() {
  # No backslash, quote, brackets or newline: nothing can end the string early.
  local safe_text_pattern='^[A-Za-z0-9_:. +-]*$'
  # Defence in depth: validators already restrict the text, this guard fails closed.
  [[ "$1" =~ $safe_text_pattern ]] || return 1
  printf '"%s"\n' "$1"
}

# zoomctl_lua_call — build a HyprZoom API call from a function name and literal arguments.
# Args:    $1 function name (letters and underscores); $2.. already-rendered Lua literals
# Returns: 0 ok; 1 invalid function name; stdout: for example HyprZoom.zoom_in(3)
# Globals: none
zoomctl_lua_call() {
  local function_name="$1"
  shift
  # Function names come from this code base, but fail closed anyway.
  [[ "$function_name" =~ ^[a-z_]+$ ]] || return 1
  printf 'HyprZoom.%s(%s)\n' "$function_name" "$(zoomctl_join_by ', ' "$@")"
}

# zoomctl_lua_table_literal — render validated KEY=VALUE pairs as a Lua table of strings.
# Args:    $1.. canonical KEY=VALUE pairs (keys from the schema, values already validated)
# Returns: 0 ok; 1 a pair is malformed or unsafe; stdout: {KEY="value", ...}
# Globals: none
zoomctl_lua_table_literal() {
  local pair key quoted_value
  local -a entries=()
  # Values are strings in canonical config-file form, as the engine's own file parser sees them.
  for pair in "$@"; do
    key="${pair%%=*}"
    [[ "$key" =~ ^[A-Z_]+$ ]] || return 1
    quoted_value="$(zoomctl_lua_quote "${pair#*=}")" || return 1
    entries+=("$key=$quoted_value")
  done
  printf '{%s}\n' "$(zoomctl_join_by ', ' "${entries[@]}")"
}

# zoomctl_engine_forward — send one call to the engine, falling back when it is not there.
# Args:    $1 Lua call text (from zoomctl_lua_call); $2.. fallback command and arguments
# Returns: 0 done; 1 engine rejected the call, Hyprland unreachable, or the fallback failed
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_forward() {
  local lua_call="$1"
  local engine_answer
  shift
  # One hyprctl process is the whole cost of the normal path.
  engine_answer="$(zoomctl_hyprland_eval "$lua_call")" && return 0
  zoomctl_hyprland_probe
  # Only when the engine is absent does the bash fallback take over.
  case "$ZOOMCTL_PROBE" in
    engine) zoomctl_error "the engine rejected $lua_call: $engine_answer" ;;
    unreachable) zoomctl_error "Hyprland is not reachable (no running session?)" ;;
    *) "$@" ;;
  esac
}

# zoomctl_engine_require — print an error unless the Lua engine is loaded.
# Args:    $1 what needs it (for the message)
# Returns: 0 engine present; 1 absent; stderr: reason and the fix
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_require() {
  zoomctl_hyprland_probe
  # Each state gets its own hint, because the fixes differ.
  case "$ZOOMCTL_PROBE" in
    engine) return 0 ;;
    unreachable) zoomctl_error "$1 needs a running Hyprland session" ;;
    lua-no-engine) zoomctl_error "$1 needs the engine: run 'zoomctl setup', then reload Hyprland" ;;
    *) zoomctl_error "$1 needs Hyprland with the Lua config (0.55+); not available on hyprlang" ;;
  esac
}

# zoomctl_engine_status_lines — fetch the engine's own status (C6) when it is loaded.
# Args:    none
# Returns: 0 engine answered with status lines; 1 otherwise; stdout: KEY=VALUE lines
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_status_lines() {
  local answer
  zoomctl_hyprland_probe
  [ "$ZOOMCTL_PROBE" = 'engine' ] || return 1
  answer="$(hyprctl repl 'return HyprZoom.status()' 2>/dev/null)" || return 1
  # A well-formed answer starts with the engine key.
  [[ "$answer" == engine=* ]] || return 1
  printf '%s\n' "$answer"
}

# zoomctl_engine_preview — apply validated overrides live without writing any file.
# Args:    $1.. KEY=VALUE pairs (user input, aliases allowed)
# Returns: 0 applied; 1 invalid input or no engine; 2 no pairs given
# Globals: reads the schema tables
zoomctl_engine_preview() {
  local pair canonical_key canonical_value
  local -a checked_pairs=()
  [ "$#" -gt 0 ] || { zoomctl_usage_error "preview needs KEY=VALUE pairs or --end"; return 2; }
  # Every pair is resolved and validated before anything is sent.
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || { zoomctl_error "'$pair' is not KEY=VALUE"; return 1; }
    canonical_key="$(zoomctl_schema_resolve_key "${pair%%=*}")" ||
      { zoomctl_error "unknown setting '${pair%%=*}'"; return 1; }
    canonical_value="$(zoomctl_schema_validate "$canonical_key" "${pair#*=}")" ||
      { zoomctl_error "invalid value '${pair#*=}' for $canonical_key"; return 1; }
    checked_pairs+=("$canonical_key=$canonical_value")
  done
  zoomctl_engine_send_preview "${checked_pairs[@]}"
}

# zoomctl_engine_send_preview — deliver already-validated pairs to HyprZoom.preview.
# Args:    $1.. canonical KEY=VALUE pairs
# Returns: 0 applied; 1 no engine or rejected
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_send_preview() {
  local table_literal engine_answer
  zoomctl_engine_require 'live preview' || return 1
  table_literal="$(zoomctl_lua_table_literal "$@")" || return 1
  # The engine overlays the table on the saved config without writing it.
  engine_answer="$(zoomctl_hyprland_eval "$(zoomctl_lua_call preview "$table_literal")")" ||
    zoomctl_error "the engine rejected the preview: $engine_answer"
}

# zoomctl_engine_preview_end — drop the preview overrides and re-apply the saved config.
# Args:    none
# Returns: 0 done; 1 no engine or rejected
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_preview_end() {
  local engine_answer
  zoomctl_engine_require 'live preview' || return 1
  engine_answer="$(zoomctl_hyprland_eval "$(zoomctl_lua_call preview_end)")" ||
    zoomctl_error "the engine rejected preview --end: $engine_answer"
}

# zoomctl_engine_reload — make a running session pick up freshly saved settings.
# Args:    none
# Returns: 0 always (the settings are saved either way); stderr: what was and was not applied
# Globals: reads/writes ZOOMCTL_PROBE
zoomctl_engine_reload() {
  local engine_answer
  # The engine re-reads schema and config files itself.
  engine_answer="$(zoomctl_hyprland_eval "$(zoomctl_lua_call reload)")" && return 0
  zoomctl_hyprland_probe
  # Say plainly what could not be applied, but never fail a successful save.
  case "$ZOOMCTL_PROBE" in
    engine) zoomctl_warn "saved, but the engine rejected the reload: $engine_answer" ;;
    unreachable) zoomctl_warn "saved; Hyprland is not reachable, so nothing was applied live" ;;
    *)
      zoomctl_legacy_run apply_settings >/dev/null 2>&1
      zoomctl_warn "saved; the Lua engine is not loaded, only basic options were applied" ;;
  esac
  return 0
}
