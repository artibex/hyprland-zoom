#!/usr/bin/env bash
# userconfig.sh — the only writer of the user config file (decision E4).
# The file holds canonical overrides only: no comments, schema order, atomic replacement.

# zoomctl_userconfig_write — atomically replace the user config with the given overrides.
# Args:    $1 name of an associative array (key -> canonical value); empty array removes the file
# Returns: 0 written; 1 the file could not be written; stdout: none
# Globals: reads ZOOMCTL_SCHEMA_KEYS
zoomctl_userconfig_write() {
  local -n override_map_ref="$1"
  local config_file config_dir draft_file key file_mode
  # The single writer resolves the path through the shared helper.
  config_file="$(zoomctl_user_config_file)"
  config_dir="$(dirname -- "$config_file")"
  # No overrides left means no file, so `get` and the UI see pure defaults.
  if [ "${#override_map_ref[@]}" -eq 0 ]; then
    rm -f -- "$config_file"
    return 0
  fi
  # A fresh account has no config directory yet.
  mkdir -p -- "$config_dir" || return 1
  # The draft lives in the target directory so the final rename is atomic.
  draft_file="$(mktemp "$config_dir/.zoom.conf.XXXXXX")" || return 1
  # Schema order keeps the file stable and diff-friendly.
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    [ -n "${override_map_ref[$key]+set}" ] && printf '%s=%s\n' "$key" "${override_map_ref[$key]}"
  done > "$draft_file"
  # Keep the mode of an existing file; a new file is world-readable like other dotfiles.
  file_mode="$(stat -c '%a' -- "$config_file" 2>/dev/null || printf '644')"
  chmod "$file_mode" "$draft_file"
  mv -f -- "$draft_file" "$config_file" || { rm -f -- "$draft_file"; return 1; }
}

# zoomctl_userconfig_load_overrides — read the user file into a canonical override map.
# Args:    $1 name of an associative array that receives the overrides
# Returns: 0 always; stderr: warnings for entries that are dropped
# Globals: reads the schema tables
zoomctl_userconfig_load_overrides() {
  # Reading through the layer parser applies 0.1 compat and drops invalid entries.
  zoomctl_config_read_layer "$(zoomctl_user_config_file)" "$1"
}

# zoomctl_userconfig_check_bounds — reject an override set that breaks MIN <= RESET <= MAX.
# Args:    $1 name of the override map; config must be loaded with "base"
# Returns: 0 fine; 1 violated; stderr: the rule with the values
# Globals: reads ZOOMCTL_VALUE
zoomctl_userconfig_check_bounds() {
  local bounds_problem
  # The check runs against system defaults plus the candidate overrides.
  bounds_problem="$(zoomctl_config_layer_bounds_check "$1")" && return 0
  zoomctl_error "$bounds_problem"
}

# zoomctl_userconfig_set — store one validated override.
# Args:    $1 canonical key; $2 canonical value (already validated)
# Returns: 0 stored; 1 rule violated or write failed
# Globals: writes the user config file
zoomctl_userconfig_set() {
  local -A override_values=()
  zoomctl_config_load base || return 1
  # The existing overrides are loaded and canonicalised first.
  zoomctl_userconfig_load_overrides override_values
  override_values[$1]="$2"
  zoomctl_userconfig_check_bounds override_values || return 1
  # The atomic rename leaves the old file intact when the write fails.
  zoomctl_userconfig_write override_values || zoomctl_error "cannot write the user config"
}

# zoomctl_userconfig_unset — drop one override so the lower layers apply again.
# Args:    $1 canonical key
# Returns: 0 removed or nothing to remove; 1 rule violated or write failed
# Globals: writes the user config file
zoomctl_userconfig_unset() {
  local -A override_values=()
  zoomctl_config_load base || return 1
  # The existing overrides are loaded and canonicalised first.
  zoomctl_userconfig_load_overrides override_values
  # Nothing to do when the key was never overridden.
  [ -n "${override_values[$1]+set}" ] || return 0
  unset "override_values[$1]"
  zoomctl_userconfig_check_bounds override_values || return 1
  # A failed write keeps the old file thanks to the atomic rename.
  zoomctl_userconfig_write override_values || zoomctl_error "cannot write the user config"
}

# zoomctl_userconfig_reset — delete every user override.
# Args:    none
# Returns: 0 always
# Globals: removes the user config file
zoomctl_userconfig_reset() {
  # An empty override map removes the file through the single writer.
  local -A no_overrides=()
  zoomctl_userconfig_write no_overrides
}

# zoomctl_userconfig_translate_input — map a 0.1 setting name and value to the 0.2 meaning.
# Args:    $1 name as typed; $2 value as typed
# Returns: 0 ok; 1 invalid 0.1 value; stdout: the value to validate for the resolved key
# Globals: none
zoomctl_userconfig_translate_input() {
  local normalised="${1,,}"
  # center-cursor on/off became the tracking modes centered/edge.
  case "${normalised//_/-}" in
    center-cursor|center|cursor) zoomctl_config_legacy_tracking "$2" ;;
    *) printf '%s\n' "$2" ;;
  esac
}
