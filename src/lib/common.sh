#!/usr/bin/env bash
# common.sh — constants and tiny helpers shared by every zoomctl library.
# Sourced first by src/zoomctl; depends on no other library.

# Seconds a command waits for a lock (zoom state, user config) before giving up.
ZOOMCTL_LOCK_TIMEOUT_SECONDS=5

# zoomctl_warn — print a warning to stderr; never changes the exit status.
# Args:    $1 message
# Returns: 0 always; stderr: "zoomctl: <message>"
# Globals: none
zoomctl_warn() {
  # Warnings go to stderr so stdout stays machine readable.
  printf 'zoomctl: %s\n' "$1" >&2
}

# zoomctl_error — print an error to stderr and return the "error" exit code.
# Args:    $1 message
# Returns: 1 always; stderr: "zoomctl: <message>"
# Globals: none
zoomctl_error() {
  # Reuse the warning format so every message looks the same.
  zoomctl_warn "$1"
  return 1
}

# zoomctl_usage_error — print a usage mistake to stderr and return exit code 2.
# Args:    $1 message
# Returns: 2 always; stderr: message plus a pointer to `zoomctl help`
# Globals: none
zoomctl_usage_error() {
  # Same prefix as other messages, plus where to learn the syntax.
  zoomctl_warn "$1 (see 'zoomctl help')"
  return 2
}

# zoomctl_trim_var — strip leading and trailing whitespace from a variable in place.
# Args:    $1 name of the variable to trim
# Returns: 0 always; no stdout (avoids a subshell per config line)
# Globals: writes the variable named by $1
zoomctl_trim_var() {
  # A nameref edits the caller's variable without forking a subshell.
  local -n _zoomctl_trim_ref="$1"
  # Remove the leading run of whitespace.
  _zoomctl_trim_ref="${_zoomctl_trim_ref#"${_zoomctl_trim_ref%%[![:space:]]*}"}"
  # Remove the trailing run of whitespace.
  _zoomctl_trim_ref="${_zoomctl_trim_ref%"${_zoomctl_trim_ref##*[![:space:]]}"}"
}

# zoomctl_join_by — join the remaining arguments with a separator.
# Args:    $1 separator; $2.. items
# Returns: 0 always; stdout: the joined text (empty without items)
# Globals: none
zoomctl_join_by() {
  # Take the separator off the argument list.
  local separator="$1"
  shift
  # Print the first item bare, every further item behind the separator.
  [ "$#" -gt 0 ] || return 0
  printf '%s' "$1"
  shift
  # Every remaining item is printed with the separator in front.
  printf '%s' "${@/#/$separator}"
  printf '\n'
}

# zoomctl_run_locked — run a command while holding an exclusive flock on a lock file.
# Args:    $1 lock file; $2.. command and arguments (a function of this process works too)
# Returns: the command's status; 1 when flock is missing or the lock cannot be taken in time
# Globals: reads ZOOMCTL_LOCK_TIMEOUT_SECONDS
zoomctl_run_locked() {
  local lock_file="$1"
  shift
  # util-linux ships flock; without it writers cannot be serialised, so say exactly that.
  command -v flock >/dev/null 2>&1 ||
    { zoomctl_error "flock (util-linux) is missing; install it to run zoomctl"; return 1; }
  # The subshell owns fd 9, so the lock vanishes with it, even when the command fails.
  (
    # A failed open must be a clear message, not a bare shell redirection error.
    { exec 9>"$lock_file"; } 2>/dev/null ||
      { zoomctl_error "cannot create the lock file $lock_file"; exit 1; }
    # Waiting with a timeout turns a stuck holder into a clear error instead of a hang.
    flock --timeout "$ZOOMCTL_LOCK_TIMEOUT_SECONDS" 9 || {
      zoomctl_error "could not take the lock $lock_file within ${ZOOMCTL_LOCK_TIMEOUT_SECONDS}s"
      exit 1
    }
    # The caller's command runs while the lock is held.
    "$@"
  )
}

# zoomctl_version — print the package version from the VERSION file (single source).
# Args:    none
# Returns: 0 always; stdout: the version text, or "unknown" when no VERSION file is found
# Globals: reads ZOOMCTL_SHARE_DIR, ZOOMCTL_SCRIPT_DIR
zoomctl_version() {
  local candidate version_text
  # Installed copy first, then the repository root of a checkout.
  for candidate in "$(zoomctl_share_dir)/VERSION" "${ZOOMCTL_SCRIPT_DIR:-.}/../VERSION"; do
    [ -r "$candidate" ] || continue
    # The file holds one line.
    version_text=''
    read -r version_text < "$candidate" || [ -n "$version_text" ]
    # Surrounding blanks are not part of the version.
    zoomctl_trim_var version_text
    [ -n "$version_text" ] && { printf '%s\n' "$version_text"; return 0; }
  done
  printf 'unknown\n'
}

# zoomctl_restore_locale — give the caller's LC_ALL back before exec'ing another program.
# Args:    none
# Returns: 0 always
# Globals: reads ZOOMCTL_CALLER_LC_ALL, ZOOMCTL_CALLER_LC_ALL_SET; writes LC_ALL
zoomctl_restore_locale() {
  # The byte-wise locale is for zoomctl's own validators; an editor or a GTK window needs UTF-8.
  if [ -n "${ZOOMCTL_CALLER_LC_ALL_SET:-}" ]; then
    LC_ALL="$ZOOMCTL_CALLER_LC_ALL"
  else
    unset LC_ALL
  fi
}
