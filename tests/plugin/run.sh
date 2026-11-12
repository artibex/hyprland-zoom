#!/usr/bin/env bash
# run.sh — runs the hyprzoom plugin tests that need no running Hyprland.
#   1. camera_math_test        — pure maths, plain g++ (always runs)
#   2. native_equivalence_test — margin 0.05 == Hyprland's code (needs hyprutils headers)
#   3. schema consistency      — plugin margin range matches config/settings.schema
#   4. manifest_test.py        — hyprpm.toml obeys hyprpm's parser rules
#   5. build.sh                — the .so compiles against the installed Hyprland headers
# Usage: tests/plugin/run.sh [--no-build]
# Exit:  0 all green; 1 any failure. A step that exits 77 is reported as SKIP, not failure.
set -euo pipefail

# Repository root, resolved from this script so it works from any directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Build products go to a private temp dir that is removed on exit.
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/hyprzoom-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
# Counts failed steps so every step runs even after a failure.
failures=0

# run_step — runs one named step, prints its verdict and counts failures.
# Args:    $1 step name; $2.. command to run
# Returns: 0 always (failures are counted, not propagated)
# Globals: writes failures
run_step() {
  local name="$1" status
  shift
  # Capture the status instead of letting `set -e` abort, so later steps still run.
  "$@" && status=0 || status=$?
  # 77 is the autotools convention for "skipped".
  case "$status" in
    # Green step.
    0) echo "PASS  $name" ;;
    # Precondition missing (e.g. no headers): neither pass nor fail.
    77) echo "SKIP  $name" ;;
    # Anything else is a failure; count it for the final exit code.
    *) echo "FAIL  $name"; failures=$((failures + 1)) ;;
  esac
}

# run_unit_test — compiles and runs the pure camera maths test.
# Args:    none
# Returns: exit status of the test binary
# Globals: reads repo_root, build_dir
run_unit_test() {
  # -Werror keeps the header warning-free, which the plugin build also demands.
  g++ -std=c++20 -Wall -Wextra -Werror -O1 \
    "$repo_root/tests/plugin/camera_math_test.cpp" -o "$build_dir/camera_math_test" || return 1
  "$build_dir/camera_math_test"
}

# run_equivalence_test — compares the maths with a transcription of Hyprland's own code.
# Args:    none
# Returns: 0 passed; 1 divergence or build error; 77 no hyprutils headers
# Globals: reads repo_root, build_dir
run_equivalence_test() {
  # The test needs hyprutils' CBox; without the headers there is nothing to compare against.
  pkg-config --exists hyprutils || return 77
  # shellcheck disable=SC2046  # pkg-config output is meant to be word-split into flags.
  g++ -std=c++23 -Wall -Wextra -O1 $(pkg-config --cflags hyprutils) \
    "$repo_root/tests/plugin/native_equivalence_test.cpp" -o "$build_dir/equivalence_test" \
    $(pkg-config --libs hyprutils) || return 1
  "$build_dir/equivalence_test"
}

# header_constant — prints the numeric value of a constexpr in plugin/camera_math.hpp.
# Args:    $1 constant name, e.g. kMinEdgeMargin
# Returns: 0 always; stdout: the number (empty when the constant does not exist)
# Globals: reads repo_root
header_constant() {
  sed -n "s/.*$1 = \\([0-9.]*\\);.*/\\1/p" "$repo_root/plugin/camera_math.hpp"
}

# run_schema_check — verifies plugin constants against the settings schema (E3: one source).
# Args:    none
# Returns: 0 consistent; 1 mismatch
# Globals: reads repo_root
run_schema_check() {
  local schema_range plugin_range min_margin max_margin
  # The schema line of the edge margin carries the allowed range as `min..max` in column 4.
  schema_range="$(grep '^ZOOM_EDGE_MARGIN|' "$repo_root/config/settings.schema" | cut -d'|' -f4)"
  # The same range from the plugin's compile-time constants, formatted like the schema.
  min_margin="$(header_constant kMinEdgeMargin)"
  max_margin="$(header_constant kMaxEdgeMargin)"
  # printf normalises 0.0/0.45 to the schema's two-decimal canonical form.
  plugin_range="$(printf '%.2f..%.2f' "$min_margin" "$max_margin")"
  [[ "$schema_range" == "$plugin_range" ]]
}

# main — runs all steps and sets the exit code.
# Args:    $1 optional --no-build to skip the Hyprland-header build
# Returns: 0 all green; 1 any failure
# Globals: reads repo_root; writes failures
main() {
  # Pure maths first: fastest feedback, no dependencies beyond g++.
  run_step "camera maths unit tests" run_unit_test
  run_step "native equivalence (margin 0.05)" run_equivalence_test
  # Keeps the C++ constants and the schema (single source of truth, E3) from drifting.
  run_step "edge-margin range matches settings.schema" run_schema_check
  # Python 3.11+ ships tomllib, so the manifest test needs no third-party parser.
  run_step "hyprpm.toml manifest" python3 "$repo_root/tests/plugin/manifest_test.py"
  # The build is the slow step (~10 s); build.sh itself exits 77 when the headers are missing.
  if [[ "${1:-}" != "--no-build" ]]; then
    run_step "plugin build" "$repo_root/tests/plugin/build.sh"
  fi
  # The overall verdict: success only when no step failed.
  [[ "$failures" -eq 0 ]]
}

main "$@"
