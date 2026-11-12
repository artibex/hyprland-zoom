#!/usr/bin/env bash
# run.sh — single entry point for every test suite (bash suites, shellcheck, Lua runner).
# Usage: tests/run.sh [suite-name...]   (default: all). Exit status 0 only when all pass.
set -u

# Repository root and the suites in a stable order (fast, pure suites first).
REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_SUITES=(schema config forwarding legacy setup)

# run_suite — run one test command and report PASS/FAIL for the whole suite.
# Args:    $1 suite label; $2.. command and arguments
# Returns: 0 suite passed; 1 suite failed
# Globals: none
run_suite() {
  local label="$1"
  local output
  shift
  # Suite output is shown only when it fails, keeping the normal run readable.
  if output="$("$@" 2>&1)"; then
    printf 'ok    %-12s %s\n' "$label" "$(tail -n 1 <<< "$output")"
  else
    printf 'FAIL  %-12s\n%s\n' "$label" "$output"
    return 1
  fi
}

# run_lint — run shellcheck over the shell sources when it is installed.
# Args:    none
# Returns: 0 clean or skipped (with a visible SKIP line); 1 findings
# Globals: reads REPO_ROOT
run_lint() {
  # SC2034/SC2004 are false positives for tables shared between sourced files and assoc subscripts.
  # A missing shellcheck is reported loudly; CI installs it so the gate cannot silently vanish.
  if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'SKIP  %-12s shellcheck not installed\n' lint
    return 0
  fi
  run_suite lint shellcheck -x -e SC1090,SC1091,SC2034,SC2004 "$REPO_ROOT/src/zoomctl" \
    "$REPO_ROOT"/src/lib/*.sh "$REPO_ROOT/install/post_install.sh" "$REPO_ROOT"/tests/*.sh \
    "$REPO_ROOT"/tests/lib/*.sh "$REPO_ROOT/tests/fixtures/fake-hyprctl"
}

# run_lua_suites — run the engine's Lua unit tests (owned by the engine package).
# Args:    none
# Returns: 0 passed or runner not present yet (SKIP line); 1 failed
# Globals: reads REPO_ROOT
run_lua_suites() {
  # P1a provides tests/lua/run.sh; until it exists this prints an explicit SKIP.
  if [ ! -x "$REPO_ROOT/tests/lua/run.sh" ]; then
    printf 'SKIP  %-12s tests/lua/run.sh not present\n' lua
    return 0
  fi
  run_suite lua "$REPO_ROOT/tests/lua/run.sh"
}

# main — run the selected suites and summarise.
# Args:    optional suite names
# Returns: 0 all passed; 1 at least one failed
# Globals: reads BASH_SUITES, REPO_ROOT
main() {
  local failures=0 suite
  local -a selected=("$@")
  [ "${#selected[@]}" -gt 0 ] || selected=("${BASH_SUITES[@]}" lint lua)
  for suite in "${selected[@]}"; do
    # Lint and Lua have their own runners; everything else is tests/<name>.sh.
    case "$suite" in
      lint) run_lint || failures=$((failures + 1)) ;;
      lua) run_lua_suites || failures=$((failures + 1)) ;;
      *) run_suite "$suite" bash "$REPO_ROOT/tests/$suite.sh" || failures=$((failures + 1)) ;;
    esac
  done
  printf '%d suite(s) failed\n' "$failures"
  [ "$failures" -eq 0 ]
}

main "$@"
