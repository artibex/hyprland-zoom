#!/usr/bin/env bash
# run.sh — runs the hyprzoom plugin tests that need no running Hyprland.
#   1. camera_math_test + hook_target_test — pure logic, plain g++ (always runs)
#   2. native_equivalence_test — margin 0.05 == Hyprland 0.56.2 AND 0.57.2 code (needs hyprutils)
#   3. schema consistency      — plugin margin range matches config/settings.schema
#   4. manifest_test.py        — hyprpm.toml and the Makefile obey hyprpm's rules
#   5. API guard               — an unknown plugin API stops the build with a clear message
#   6. 0.57 header compile     — optional: HYPRZOOM_057_SOURCE=<extracted Hyprland 0.57 tarball>
#   7. build.sh                — the .so compiles against the installed Hyprland headers
# Usage: tests/plugin/run.sh [--no-build]
# Exit:  0 all green; 1 any failure; 77 the prerequisites (python3, g++, pkg-config) are missing
#        (the generic CI job has none of them). A single step that exits 77 is reported as SKIP.
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

# skip_without_prerequisites — leave with the "skipped" status when a needed tool is missing.
# Args:    none
# Returns: returns normally when g++, python3 and pkg-config exist; otherwise exits 77
# Globals: none
skip_without_prerequisites() {
  local tool missing=""
  # Collect every missing tool so the message is complete.
  for tool in g++ python3 pkg-config; do
    command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
  done
  # Nothing to run without them: a skip, not a failure (the plugin CI job installs them).
  if [[ -n "$missing" ]]; then
    echo "SKIP  plugin tests: missing tools:$missing"
    exit 77
  fi
}

# run_unit_tests — compiles and runs the Hyprland-free unit tests (camera maths, hook target).
# Args:    none
# Returns: 0 all passed; 1 any build error or failed test
# Globals: reads repo_root, build_dir
run_unit_tests() {
  local test_name
  # Each test is one source file with the same name as its binary.
  for test_name in camera_math_test hook_target_test; do
    # -Werror keeps the headers warning-free, which the plugin build also demands.
    g++ -std=c++20 -Wall -Wextra -Werror -O1 "$repo_root/tests/plugin/$test_name.cpp" \
      -o "$build_dir/$test_name" || return 1
    "$build_dir/$test_name" || return 1
  done
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

# run_api_guard_test — an unknown plugin API version must stop the build with the clear message.
# Args:    none
# Returns: 0 the guard fired with the expected text; 1 it did not; 77 no hyprland headers
# Globals: reads repo_root, build_dir
run_api_guard_test() {
  local wrapper="$build_dir/api-guard/hyprland/src/plugins" output
  # Without the headers there is nothing to compile against.
  pkg-config --exists hyprland || return 77
  mkdir -p "$wrapper"
  # A wrapper header announces a future plugin API on top of the real one (#include_next).
  printf '%s\n' '#include_next <hyprland/src/plugins/PluginAPI.hpp>' \
    '#undef HYPRLAND_API_VERSION' '#define HYPRLAND_API_VERSION "9.9"' \
    > "$wrapper/PluginAPI.hpp"
  # The compile must fail, and the failure must be our static_assert, not some other error.
  # shellcheck disable=SC2046  # pkg-config output is meant to be word-split into flags.
  if output="$(g++ -fsyntax-only -std=c++2c -DWLR_USE_UNSTABLE -DHYPRZOOM_VERSION='"0"' \
    -I"$build_dir/api-guard" $(pkg-config --cflags hyprland pixman-1 libdrm pangocairo libinput \
    libudev wayland-server xkbcommon) "$repo_root/plugin/main.cpp" 2>&1)"; then
    echo "the build accepted an unknown plugin API"
    return 1
  fi
  # The guard's own message proves the failure is the intended one.
  grep -q "hyprzoom supports Hyprland 0.56.x" <<< "$output"
}

# run_057_compile_check — optional compile against the headers of a Hyprland 0.57 source tree.
# Args:    none
# Returns: 0 compiles; 1 compile error; 77 HYPRZOOM_057_SOURCE not set or tools missing
# Globals: reads repo_root
run_057_compile_check() {
  # Without a source tree there is nothing to compile against: a visible SKIP.
  bash "$repo_root/tests/plugin/compile_against_source.sh" "${HYPRZOOM_057_SOURCE:-}"
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
  # Without the tools there is nothing to run (the generic CI job); say so with exit 77.
  skip_without_prerequisites
  # Pure maths first: fastest feedback, no dependencies beyond g++.
  run_step "unit tests (camera maths, hook target)" run_unit_tests
  run_step "native equivalence (margin 0.05)" run_equivalence_test
  # Keeps the C++ constants and the schema (single source of truth, E3) from drifting.
  run_step "edge-margin range matches settings.schema" run_schema_check
  # Python 3.11+ ships tomllib, so the manifest test needs no third-party parser.
  run_step "hyprpm.toml manifest" python3 "$repo_root/tests/plugin/manifest_test.py"
  # The compile-time guards: unknown API refused, and 0.57 headers compile (when available).
  run_step "build guard refuses an unknown plugin API" run_api_guard_test
  run_step "compiles against Hyprland 0.57 headers" run_057_compile_check
  # The build is the slow step (~10 s); build.sh itself exits 77 when the headers are missing.
  if [[ "${1:-}" != "--no-build" ]]; then
    run_step "plugin build" "$repo_root/tests/plugin/build.sh"
  fi
  # The overall verdict: success only when no step failed.
  [[ "$failures" -eq 0 ]]
}

main "$@"
