#!/usr/bin/env bash
# userconfig.sh — the only writer of the user config file (decision E4).
# The file holds canonical overrides only: no comments, schema order, atomic replacement.
# Every read-modify-write runs under one lock, so parallel `zoomctl set` calls (the settings
# window sends several) never lose each other's keys; the file helpers come from setup.sh.

# zoomctl_userconfig_lock_file — print the lock file that serialises user-config writers.
# Args:    none
# Returns: 0 always; stdout: path next to the user config
# Globals: reads the user-config path variables
zoomctl_userconfig_lock_file() {
  # Beside the config, so every process of the user finds the same lock (also via a symlink).
  printf '%s/.zoom.conf.lock\n' "$(dirname -- "$(zoomctl_user_config_file)")"
}

# zoomctl_userconfig_with_lock — run a command while holding the user-config lock.
# Args:    $1.. command and arguments (a function of this process works too)
# Returns: the command's status; 1 when the directory, lock or flock is unavailable
# Globals: reads the user-config path variables
zoomctl_userconfig_with_lock() {
  local config_dir
  config_dir="$(dirname -- "$(zoomctl_user_config_file)")"
  # A fresh account has no config directory yet, and the lock file needs one.
  mkdir -p -- "$config_dir" 2>/dev/null ||
    { zoomctl_error "cannot create the config directory $config_dir"; return 1; }
  zoomctl_run_locked "$(zoomctl_userconfig_lock_file)" "$@"
}

# zoomctl_userconfig_render — print override map entries as canonical KEY=VALUE lines.
# Args:    $1 name of an associative array (key -> canonical value)
# Returns: 0 written; 1 a write failed (full disk); stdout: lines in schema order
# Globals: reads ZOOMCTL_SCHEMA_KEYS
zoomctl_userconfig_render() {
  local -n render_map_ref="$1"
  local key render_status=0
  # Schema order keeps the file stable and diff-friendly.
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    [ -z "${render_map_ref[$key]+set}" ] && continue
    # A failing printf (full disk) must fail the whole render, not only its own line.
    printf '%s=%s\n' "$key" "${render_map_ref[$key]}" || render_status=1
  done
  return "$render_status"
}

# zoomctl_userconfig_write — atomically replace the user config with the given overrides.
# Args:    $1 name of an associative array (key -> canonical value); empty array removes the file
# Returns: 0 written; 1 the file could not be written or removed (message on stderr)
# Globals: reads ZOOMCTL_SCHEMA_KEYS
zoomctl_userconfig_write() {
  # The caller's map holds the canonical overrides to write.
  local -n override_map_ref="$1"
  local config_file draft_file
  config_file="$(zoomctl_user_config_file)"
  # No overrides left means no file, so `get` and the UI see pure defaults.
  if [ "${#override_map_ref[@]}" -eq 0 ]; then
    rm -f -- "$config_file" && return 0
    # A failed removal (read-only directory) must never be reported as success.
    zoomctl_error "cannot remove $config_file"
    return 1
  fi
  # The draft sits next to the real file (a dotfile symlink is resolved), so the rename is atomic.
  draft_file="$(zoomctl_new_draft "$config_file")" || return 1
  zoomctl_userconfig_render override_map_ref > "$draft_file" ||
    { rm -f -- "$draft_file"; zoomctl_error "cannot write the draft of $config_file"; return 1; }
  # The replace keeps an existing mode and symlink; a new file is world-readable, never writable.
  zoomctl_replace_file "$draft_file" "$config_file" 644 || { rm -f -- "$draft_file"; return 1; }
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

# zoomctl_userconfig_backup_if_lossy — keep a copy of a hand-edited file before the first rewrite.
# Args:    $1 canonical text of the overrides as currently loaded
# Returns: 0 nothing to lose or backup saved; 1 the backup failed (the edit must not go on)
# Globals: reads the user-config path variables
# Notes:   comments, unknown keys, 0.1 keys and invalid values all make the file differ from
#          its canonical rendering and would vanish silently otherwise.
zoomctl_userconfig_backup_if_lossy() {
  local config_file existing_text
  config_file="$(zoomctl_user_config_file)"
  # No file yet means nothing to lose.
  [ -f "$config_file" ] || return 0
  existing_text="$(<"$config_file")" ||
    { zoomctl_error "cannot read $config_file"; return 1; }
  # A file that already equals its canonical form loses nothing, so no backup clutter.
  [ "$existing_text" = "$1" ] && return 0
  zoomctl_userconfig_backup_note "$config_file"
}

# zoomctl_userconfig_backup_note — back up the file and say why.
# Args:    $1 user config file
# Returns: 0 backup saved; 1 backup failed
# Globals: none
zoomctl_userconfig_backup_note() {
  # The label gives the file the name zoom.conf.bak-<timestamp>-<random>.
  zoomctl_backup_file "$1" bak || return 1
  zoomctl_warn "$1 had comments or entries zoomctl does not write; the copy above keeps them"
}

# zoomctl_userconfig_apply_pairs — put KEY VALUE pairs into an override map.
# Args:    $1 name of the map; $2.. KEY VALUE pairs (already validated)
# Returns: 0 always
# Globals: writes the map
zoomctl_userconfig_apply_pairs() {
  local -n target_map_ref="$1"
  shift
  # Later pairs of the same key win, like repeated assignments in a config file.
  while [ "$#" -gt 1 ]; do
    target_map_ref[$1]="$2"
    shift 2
  done
}

# zoomctl_userconfig_update_locked — load, change, verify and write the overrides (lock held).
# Args:    $1 action (set|unset); $2.. KEY VALUE pairs for set, one KEY for unset
# Returns: 0 stored or nothing to do; 1 rule violated or write failed (file untouched)
# Globals: writes the user config file
zoomctl_userconfig_update_locked() {
  # The action, then the arguments that belong to it.
  local action="$1" before_text
  # The overrides as loaded, then as changed.
  local -A override_values=()
  shift
  zoomctl_config_load base || return 1
  # The existing overrides are loaded and canonicalised first.
  zoomctl_userconfig_load_overrides override_values
  before_text="$(zoomctl_userconfig_render override_values)"
  # set puts the pairs in; unset takes one key out.
  if [ "$action" = 'set' ]; then
    zoomctl_userconfig_apply_pairs override_values "$@"
  else
    # Nothing to do when the key was never overridden.
    [ -n "${override_values[$1]+set}" ] || return 0
    unset "override_values[$1]"
  fi
  zoomctl_userconfig_check_bounds override_values || return 1
  # Hand-edited content is saved once before the canonical rewrite drops it.
  zoomctl_userconfig_backup_if_lossy "$before_text" || return 1
  zoomctl_userconfig_write override_values
}

# zoomctl_userconfig_set — store validated overrides, all or nothing, in one write.
# Args:    $1.. canonical KEY VALUE pairs (already validated)
# Returns: 0 stored; 1 rule violated or write failed
# Globals: writes the user config file
zoomctl_userconfig_set() {
  # Lock, load, change, verify, write: parallel callers queue instead of losing updates.
  zoomctl_userconfig_with_lock zoomctl_userconfig_update_locked set "$@"
}

# zoomctl_userconfig_unset — drop one override so the lower layers apply again.
# Args:    $1 canonical key
# Returns: 0 removed or nothing to remove; 1 rule violated or write failed
# Globals: writes the user config file
zoomctl_userconfig_unset() {
  # Without a config file there is nothing to remove, and no directory is created for a lock.
  [ -e "$(zoomctl_user_config_file)" ] || return 0
  zoomctl_userconfig_with_lock zoomctl_userconfig_update_locked unset "$1"
}

# zoomctl_userconfig_reset_locked — back up a hand-edited file, then delete it (lock held).
# Args:    none
# Returns: 0 removed; 1 backup or removal failed
# Globals: removes the user config file
zoomctl_userconfig_reset_locked() {
  local -A override_values=()
  zoomctl_schema_load || return 1
  # What the file holds now decides whether a backup is needed.
  zoomctl_userconfig_load_overrides override_values
  # The same safety net as for a rewrite: comments and unknown keys are saved first.
  zoomctl_userconfig_backup_if_lossy "$(zoomctl_userconfig_render override_values)" || return 1
  # An empty override map removes the file through the single writer.
  override_values=()
  zoomctl_userconfig_write override_values
}

# zoomctl_userconfig_reset — delete every user override.
# Args:    none
# Returns: 0 removed or nothing to remove; 1 failed (message on stderr)
# Globals: removes the user config file
zoomctl_userconfig_reset() {
  # Without a config file there is nothing to remove.
  [ -e "$(zoomctl_user_config_file)" ] || return 0
  zoomctl_userconfig_with_lock zoomctl_userconfig_reset_locked
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
