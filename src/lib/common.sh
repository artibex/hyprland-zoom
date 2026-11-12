#!/usr/bin/env bash
# common.sh — constants and tiny helpers shared by every zoomctl library.
# Sourced first by src/zoomctl; depends on no other library.

# Package version shown by `zoomctl version` and the status porcelain (C6).
ZOOMCTL_VERSION='0.2.0'

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
  printf '%s' "${@/#/$separator}"
  printf '\n'
}
