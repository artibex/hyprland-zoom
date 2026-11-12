#!/usr/bin/env bash
# build.sh — builds plugin/hyprzoom.so and checks the result (CI-able in an Arch container).
# Needs: g++, make, pkg-config and the `hyprland` package (headers + hyprland.pc).
# Usage: tests/plugin/build.sh
# Exit:  0 built and exports verified; 1 build failed or an export is missing; 77 headers absent
#        (the conventional "skipped" code, so CI can tell it from a failure).
set -euo pipefail

# Repository root, resolved from this script so it works from any directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# check_exports — asserts the .so exports the three entry points Hyprland dlsym()s.
# Args:    $1 path of the built .so
# Returns: 0 all present; 1 one missing (message on stderr)
# Globals: none
check_exports() {
  local shared_object="$1" symbol exports
  # Capture first: `nm | grep -q` would trip pipefail when grep exits early and nm gets SIGPIPE.
  exports="$(nm -D --defined-only "$shared_object")"
  # pluginAPIVersion/pluginInit/pluginExit are the contract Hyprland dlsym()s.
  for symbol in pluginAPIVersion pluginInit pluginExit; do
    # An absent entry point makes Hyprland refuse to load the plugin, so fail the build early.
    if ! grep -q " T $symbol\$" <<<"$exports"; then
      echo "build.sh: $shared_object does not export $symbol" >&2
      return 1
    fi
  done
}

# check_version — asserts the .so carries the version of the repository's VERSION file.
# Args:    $1 path of the built .so
# Returns: 0 the version marker matches; 1 it is missing or different (message on stderr)
# Globals: reads repo_root
check_version() {
  local shared_object="$1" expected
  expected="$(tr -d '[:space:]' < "$repo_root/VERSION")"
  # The marker is a C string in .rodata (see main.cpp); -a lets grep read the binary as text.
  if ! grep -aqF "hyprzoom-version=$expected" "$shared_object"; then
    echo "build.sh: $shared_object does not carry version $expected" >&2
    return 1
  fi
}

# main — builds from scratch and verifies the artefact.
# Args:    none
# Returns: see the header
# Globals: reads repo_root
main() {
  # Without the headers a build is impossible; report "skipped" instead of a misleading failure.
  if ! pkg-config --exists hyprland; then
    echo "build.sh: SKIP, pkg-config cannot find 'hyprland' (install the hyprland package)" >&2
    return 77
  fi
  # A clean build proves the Makefile lists every source and header.
  make -C "$repo_root/plugin" clean >/dev/null
  make -C "$repo_root/plugin"
  # The entry points are verified on the real artefact, not assumed from the source.
  check_exports "$repo_root/plugin/hyprzoom.so"
  # The version must come from VERSION (-DHYPRZOOM_VERSION in the Makefile), not a literal.
  check_version "$repo_root/plugin/hyprzoom.so"
  # Final line doubles as a human-readable success marker in CI logs.
  echo "build.sh: OK $(stat -c %s "$repo_root/plugin/hyprzoom.so") bytes"
}

main "$@"
