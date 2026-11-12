#!/usr/bin/env bash
# cmd_config.sh — the configuration commands: set, get, unset, reset-config, config, edit-config.
# `set`, `unset` and `reset-config` are the only paths that write the user file (decision E4);
# each validates first, writes atomically, then asks the engine to reload.

# zoomctl_resolve_setting — turn a typed name into a canonical key or an error message.
# Args:    $1 name as typed
# Returns: 0 known; 1 unknown (message on stderr); stdout: canonical key
# Globals: reads the schema tables
zoomctl_resolve_setting() {
  # Aliases, case and underscore/hyphen spelling are all handled by the schema lookup.
  zoomctl_schema_resolve_key "$1" ||
    zoomctl_error "unknown setting '$1' (list them with 'zoomctl config')"
}

# zoomctl_check_setting_value — validate a typed value for a key and explain a rejection.
# Args:    $1 canonical key; $2 value as typed
# Returns: 0 valid; 1 invalid (message on stderr); stdout: canonical value
# Globals: reads the schema tables
zoomctl_check_setting_value() {
  # The error names the accepted values so the user can fix the command at once.
  zoomctl_schema_validate "$1" "$2" ||
    zoomctl_error "'$2' is not valid for $1: expected $(zoomctl_schema_allowed_text "$1")"
}

# zoomctl_collect_setting_pairs — resolve and validate every KEY VALUE pair of a `set` call.
# Args:    $1 name of an array that receives canonical KEY VALUE items; $2.. KEY VALUE as typed
# Returns: 0 all valid; 1 one pair is invalid (message on stderr, nothing collected for use)
# Globals: reads the schema tables
zoomctl_collect_setting_pairs() {
  # The caller's array receives the canonical pairs.
  local -n collected_ref="$1"
  local canonical_key typed_value canonical_value
  shift
  # Nothing is written before every pair passed, so a bad pair leaves all settings alone.
  while [ "$#" -gt 1 ]; do
    canonical_key="$(zoomctl_resolve_setting "$1")" || return 1
    # 0.1 names such as center-cursor carry their old value syntax.
    typed_value="$(zoomctl_userconfig_translate_input "$1" "$2")" ||
      { zoomctl_error "'$2' is not valid for $1: expected on or off"; return 1; }
    canonical_value="$(zoomctl_check_setting_value "$canonical_key" "$typed_value")" || return 1
    # Both halves passed their validators, so the pair may be stored.
    collected_ref+=("$canonical_key" "$canonical_value")
    shift 2
  done
}

# zoomctl_command_set — validate, store and apply one or several settings in one step.
# Args:    $1 key or alias; $2 value (empty allowed for key-type settings); further KEY VALUE pairs
# Returns: 0 saved; 1 invalid or write failed; 2 usage error; stdout: KEY=VALUE per stored pair
# Globals: writes the user config file
zoomctl_command_set() {
  local -a stored_pairs=()
  # Pairs only: an odd argument count is a typo and must not guess which value is missing.
  if [ "$#" -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
    zoomctl_usage_error "set needs a key and a value (further pairs are allowed)"
    return 2
  fi
  # The schema tables drive key resolution and validation below.
  zoomctl_schema_load || return 1
  zoomctl_collect_setting_pairs stored_pairs "$@" || return 1
  # Validated, so it is safe to persist: one locked write for all pairs, then one reload.
  zoomctl_userconfig_set "${stored_pairs[@]}" || return 1
  printf '%s=%s\n' "${stored_pairs[@]}"
  zoomctl_engine_reload
}

# zoomctl_command_get — print the effective value of one setting.
# Args:    $1 key or alias
# Returns: 0 found; 1 unknown; 2 usage error; stdout: the value
# Globals: none
zoomctl_command_get() {
  local canonical_key
  [ "$#" -eq 1 ] || { zoomctl_usage_error "get needs exactly one key"; return 2; }
  # Defaults, system and user layers are merged before the lookup.
  zoomctl_config_load || return 1
  canonical_key="$(zoomctl_resolve_setting "$1")" || return 1
  printf '%s\n' "${ZOOMCTL_VALUE[$canonical_key]}"
}

# zoomctl_command_unset — remove the user's override of one setting.
# Args:    $1 key or alias
# Returns: 0 done; 1 failed; 2 usage error
# Globals: writes the user config file
zoomctl_command_unset() {
  local canonical_key
  [ "$#" -eq 1 ] || { zoomctl_usage_error "unset needs exactly one key"; return 2; }
  # The schema tables resolve the typed name to its canonical key.
  zoomctl_schema_load || return 1
  canonical_key="$(zoomctl_resolve_setting "$1")" || return 1
  zoomctl_userconfig_unset "$canonical_key" || return 1
  # Tell the user what changed; the reload below reports whether it applied.
  printf 'zoomctl: %s override removed\n' "$canonical_key"
  zoomctl_engine_reload
}

# zoomctl_command_reset_config — delete every user override.
# Args:    none
# Returns: 0 done; 1 the file could not be removed; 2 usage error
# Globals: removes the user config file
zoomctl_command_reset_config() {
  [ "$#" -eq 0 ] || { zoomctl_usage_error "reset-config takes no arguments"; return 2; }
  zoomctl_schema_load || return 1
  # Removing the user file through the single writer undoes every override; say so only on success.
  zoomctl_userconfig_reset || return 1
  printf 'zoomctl: all user overrides removed\n'
  zoomctl_engine_reload
}

# zoomctl_command_config — show the effective configuration in one of four forms.
# Args:    $1 optional --porcelain | --template | --legacy-bindings
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_config() {
  [ "$#" -le 1 ] || { zoomctl_usage_error "config takes at most one option"; return 2; }
  zoomctl_config_load || return 1
  # One arm per output form; each renders from the already loaded tables.
  case "${1:-}" in
    '') zoomctl_config_render_human ;;
    --porcelain) zoomctl_config_porcelain ;;
    # The generated-file forms render from the schema, never from typed copies.
    --template) zoomctl_template_render ;;
    --legacy-bindings) zoomctl_legacy_bindings_render ;;
    *) zoomctl_usage_error "unknown option '$1' for config" ;;
  esac
}

# zoomctl_command_edit_config — open the user config in $EDITOR.
# Args:    none
# Returns: does not return on success (exec); 1 when no editor can be started
# Globals: reads EDITOR
zoomctl_command_edit_config() {
  # EDITOR may carry arguments ("code -w"), so it is split into words below.
  local config_file
  local -a editor_words
  config_file="$(zoomctl_user_config_file)"
  # An unset or empty EDITOR falls back to vi.
  read -ra editor_words <<< "${EDITOR:-vi}"
  command -v "${editor_words[0]:-vi}" >/dev/null 2>&1 ||
    { zoomctl_error "editor '${editor_words[0]:-vi}' not found (set EDITOR)"; return 1; }
  # A fresh account has no config directory yet; create it so the editor can save.
  mkdir -p -- "$(dirname -- "$config_file")" || return 1
  # The editor gets the caller's locale back (zoomctl itself runs byte-wise).
  zoomctl_restore_locale
  # Hand-edited files are validated on the next load (invalid lines are reported, not fatal).
  exec "${editor_words[@]}" "$config_file"
}
