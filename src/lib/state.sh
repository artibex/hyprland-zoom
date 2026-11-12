#!/usr/bin/env bash
# state.sh — runtime state directory and file (contract C5) plus the flock helper.
# The directory is 0700 under XDG_RUNTIME_DIR; the engine and the legacy path share the format.

# Seconds a zoom action waits for the legacy lock before giving up.
ZOOMCTL_LOCK_TIMEOUT_SECONDS=5

# zoomctl_state_dir — print the runtime state directory.
# Args:    none
# Returns: 0 always; stdout: path
# Globals: reads ZOOMCTL_STATE_DIR, XDG_RUNTIME_DIR
zoomctl_state_dir() {
  # Tests set ZOOMCTL_STATE_DIR; otherwise the per-user runtime dir is used.
  printf '%s\n' "${ZOOMCTL_STATE_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hyprland-zoom}"
}

# zoomctl_state_ensure_dir — create the state directory with mode 0700.
# Args:    none
# Returns: 0 ready; 1 cannot create it
# Globals: none
zoomctl_state_ensure_dir() {
  local state_directory
  state_directory="$(zoomctl_state_dir)"
  # Other users must not read or tamper with the zoom state.
  mkdir -p -- "$state_directory" || return 1
  chmod 700 -- "$state_directory" 2>/dev/null || true
}

# zoomctl_state_read — read one key of the state file.
# Args:    $1 key (zoom|saved_zoom|filter_active)
# Returns: 0 found; 1 missing; stdout: the value
# Globals: none
zoomctl_state_read() {
  local state_file line
  state_file="$(zoomctl_state_dir)/state"
  # No state file yet means nothing is stored.
  [ -r "$state_file" ] || return 1
  # The first matching line answers; the writer keeps one line per key.
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${line%%=*}" = "$1" ] && { printf '%s\n' "${line#*=}"; return 0; }
  done < "$state_file"
  return 1
}

# zoomctl_state_copy_without — print the state file lines whose key differs from the given one.
# Args:    $1 key to leave out
# Returns: 0 always; stdout: the remaining KEY=VALUE lines
# Globals: none
zoomctl_state_copy_without() {
  local state_file line
  state_file="$(zoomctl_state_dir)/state"
  # An absent file has no other keys to carry over.
  [ -r "$state_file" ] || return 0
  # Pass every other key through untouched.
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${line%%=*}" = "$1" ] || printf '%s\n' "$line"
  done < "$state_file"
}

# zoomctl_state_write — set one key of the state file, keeping the others.
# Args:    $1 key; $2 value (a plain token without newline)
# Returns: 0 written; 1 cannot write
# Globals: none
zoomctl_state_write() {
  local state_directory draft_file
  state_directory="$(zoomctl_state_dir)"
  # The runtime directory is gone after a reboot, so make sure it exists.
  zoomctl_state_ensure_dir || return 1
  draft_file="$(mktemp "$state_directory/.state.XXXXXX")" || return 1
  # The old keys first, then the new value.
  { zoomctl_state_copy_without "$1"; printf '%s=%s\n' "$1" "$2"; } > "$draft_file"
  # Same-directory rename keeps the replacement atomic for the engine reading it.
  mv -f -- "$draft_file" "$state_directory/state" || { rm -f -- "$draft_file"; return 1; }
}

# zoomctl_state_delete — remove one key from the state file.
# Args:    $1 key
# Returns: 0 always
# Globals: none
zoomctl_state_delete() {
  local state_directory draft_file
  state_directory="$(zoomctl_state_dir)"
  # Nothing stored means nothing to delete.
  [ -r "$state_directory/state" ] || return 0
  draft_file="$(mktemp "$state_directory/.state.XXXXXX")" || return 0
  # Copy everything except the key, then replace the file atomically.
  zoomctl_state_copy_without "$1" > "$draft_file"
  mv -f -- "$draft_file" "$state_directory/state"
}

# zoomctl_state_saved_zoom — read the toggle's remembered zoom, with the 0.1 file as fallback.
# Args:    none
# Returns: 0 found; 1 none; stdout: zoom factor
# Globals: reads XDG_RUNTIME_DIR
zoomctl_state_saved_zoom() {
  local legacy_file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/zoomctl/last_zoom"
  local remembered
  # The current state file wins.
  zoomctl_state_read saved_zoom && return 0
  # The 0.1 file is honoured when it holds a valid number.
  [ -r "$legacy_file" ] || return 1
  remembered="$(tr -d '[:space:]' < "$legacy_file")"
  zoomctl_is_float "$remembered" || return 1
  # Only a valid number gets here; anything else was ignored above.
  printf '%s\n' "$remembered"
}

# zoomctl_state_with_lock — run a command while holding the state lock (flock).
# Args:    $1.. command and arguments (a function of this process works too)
# Returns: the command's status; 1 when the lock cannot be taken in time
# Globals: reads ZOOMCTL_LOCK_TIMEOUT_SECONDS
zoomctl_state_with_lock() {
  local lock_file
  zoomctl_state_ensure_dir || return 1
  # The lock file lives beside the state so one directory holds everything.
  lock_file="$(zoomctl_state_dir)/lock"
  # The subshell owns fd 9; the lock vanishes with it, even when the command fails.
  (
    flock --timeout "$ZOOMCTL_LOCK_TIMEOUT_SECONDS" 9 || exit 1
    "$@"
  ) 9>"$lock_file"
}
