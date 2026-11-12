#!/usr/bin/env bash
# testlib.sh — minimal assertion framework and sandbox for the zoomctl bash suites.
# A suite sources this file, calls test_init, runs assertions, then test_finish.
# The sandbox never touches the real user config, runtime dir or compositor: zoomctl runs with
# `env -i`, a fake hyprctl first on PATH, and every ZOOMCTL_* path inside a temp directory.

# Repository root (two levels above this file).
TEST_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# The CLI under test and its schema.
ZOOMCTL="$TEST_ROOT/src/zoomctl"
SCHEMA_FILE="$TEST_ROOT/config/settings.schema"
# Counters shared by all assertions of one suite.
TEST_PASS=0
TEST_FAIL=0

# test_init — create the sandbox and announce the suite.
# Args:    $1 suite name
# Returns: 0 always
# Globals: writes TEST_SANDBOX, TEST_ENV, FAKE_DIR, ZC_USER_CONFIG, ZC_SYSTEM_CONFIG, ZC_STATE_DIR
test_init() {
  # The sandbox lives under the scratch/temp dir and is removed on exit.
  TEST_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/zoomctl-test.XXXXXX")"
  trap 'rm -rf "$TEST_SANDBOX"' EXIT
  FAKE_DIR="$TEST_SANDBOX/fake"
  ZC_USER_CONFIG="$TEST_SANDBOX/config/zoomctl/zoom.conf"
  ZC_SYSTEM_CONFIG="$TEST_SANDBOX/etc/zoomctl.conf"
  ZC_STATE_DIR="$TEST_SANDBOX/run/hyprland-zoom"
  mkdir -p "$FAKE_DIR" "$TEST_SANDBOX/bin" "$TEST_SANDBOX/home" "$TEST_SANDBOX/share" \
    "$TEST_SANDBOX/etc" "$TEST_SANDBOX/run"
  ln -s "$TEST_ROOT/tests/fixtures/fake-hyprctl" "$TEST_SANDBOX/bin/hyprctl"
  test_build_env
  printf '== %s\n' "$1"
}

# test_build_env — define the clean environment zoomctl runs in.
# Args:    none
# Returns: 0 always
# Globals: writes TEST_ENV (an `env -i` prefix as an array)
test_build_env() {
  # env -i drops HYPRLAND_INSTANCE_SIGNATURE and everything else from the live session.
  TEST_ENV=(env -i "PATH=$TEST_SANDBOX/bin:/usr/bin:/bin" "HOME=$TEST_SANDBOX/home"
    "XDG_RUNTIME_DIR=$TEST_SANDBOX/run" "XDG_CONFIG_HOME=$TEST_SANDBOX/config"
    "ZOOMCTL_USER_CONFIG=$ZC_USER_CONFIG" "ZOOMCTL_SYSTEM_CONFIG=$ZC_SYSTEM_CONFIG"
    "ZOOMCTL_STATE_DIR=$ZC_STATE_DIR" "ZOOMCTL_SHARE_DIR=$TEST_SANDBOX/share"
    "ZOOMCTL_TARGET_HOME=$TEST_SANDBOX/home" "FAKE_HYPRCTL_DIR=$FAKE_DIR"
    "LC_ALL=C" "TERM=dumb")
}

# test_extra_env — append VAR=VALUE pairs to the sandbox environment for later runs.
# Args:    $1.. VAR=VALUE pairs
# Returns: 0 always
# Globals: writes TEST_ENV
test_extra_env() {
  # env applies later assignments after earlier ones, so appending overrides.
  TEST_ENV+=("$@")
}

# load_zoomctl_libs — source every zoomctl library into the test process for in-process tests.
# Args:    none (call after test_init)
# Returns: 0 always
# Globals: exports the sandbox ZOOMCTL_* variables inside this test process only
load_zoomctl_libs() {
  local library
  # The suite process is private, so exporting here cannot leak into any shared shell.
  export ZOOMCTL_USER_CONFIG="$ZC_USER_CONFIG" ZOOMCTL_SYSTEM_CONFIG="$ZC_SYSTEM_CONFIG"
  # Safety: the fake hyprctl shadows the real one and the live instance signature is dropped.
  export PATH="$TEST_SANDBOX/bin:$PATH" FAKE_HYPRCTL_DIR="$FAKE_DIR"
  unset HYPRLAND_INSTANCE_SIGNATURE
  export ZOOMCTL_STATE_DIR="$ZC_STATE_DIR" ZOOMCTL_SHARE_DIR="$TEST_SANDBOX/share"
  export ZOOMCTL_SCRIPT_DIR="$TEST_ROOT/src" XDG_RUNTIME_DIR="$TEST_SANDBOX/run"
  for library in common math validate schema config userconfig template state hyprland \
    engine legacy setup status doctor cmd_zoom cmd_config cmd_info; do
    # shellcheck source=/dev/null
    source "$TEST_ROOT/src/lib/$library.sh"
  done
}

# run_zoomctl — run the CLI in the sandbox and capture stdout, stderr and the status.
# Args:    $1.. zoomctl arguments
# Returns: 0 always; sets ZC_OUT, ZC_ERR, ZC_STATUS
# Globals: reads TEST_ENV, ZOOMCTL
run_zoomctl() {
  local error_file="$TEST_SANDBOX/stderr"
  # stdin is /dev/null so a stray prompt can never hang a suite.
  ZC_OUT="$("${TEST_ENV[@]}" "$ZOOMCTL" "$@" 2>"$error_file" </dev/null)"
  ZC_STATUS=$?
  ZC_ERR="$(<"$error_file")"
}

# set_fake_mode — put the fake compositor into a mode.
# Args:    $1 engine|lua-no-engine|hyprlang|unreachable
# Returns: 0 always
# Globals: writes the fake state dir
set_fake_mode() {
  printf '%s\n' "$1" > "$FAKE_DIR/mode"
}

# fake_calls — print every recorded hyprctl call, one per line.
# Args:    none
# Returns: 0 always; stdout: calls.log content (empty when nothing was called)
# Globals: reads the fake state dir
fake_calls() {
  [ -r "$FAKE_DIR/calls.log" ] && cat -- "$FAKE_DIR/calls.log"
  return 0
}

# reset_sandbox — forget config, state and recorded calls between scenarios.
# Args:    none
# Returns: 0 always
# Globals: removes files in the sandbox
reset_sandbox() {
  # The share and bin directories stay; everything a scenario can change goes.
  rm -rf "$TEST_SANDBOX/config" "$TEST_SANDBOX/etc/zoomctl.conf" "$TEST_SANDBOX/run"/* \
    "$FAKE_DIR"/* "$TEST_SANDBOX/home/.config"
}

# pass — record a passing assertion.
# Args:    $1 label
# Returns: 0 always
# Globals: writes TEST_PASS
pass() {
  TEST_PASS=$((TEST_PASS + 1))
  printf 'PASS %s\n' "$1"
}

# fail — record a failing assertion with details.
# Args:    $1 label; $2 detail text (optional)
# Returns: 0 always
# Globals: writes TEST_FAIL
fail() {
  TEST_FAIL=$((TEST_FAIL + 1))
  printf 'FAIL %s\n' "$1"
  [ -z "${2:-}" ] || printf '     %s\n' "$2"
}

# assert_eq — compare two strings.
# Args:    $1 expected; $2 actual; $3 label
# Returns: 0 always
# Globals: none
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1] got [$2]"; fi
}

# assert_status — check the exit status of the last run_zoomctl.
# Args:    $1 expected status; $2 label
# Returns: 0 always
# Globals: reads ZC_STATUS
assert_status() {
  assert_eq "$1" "$ZC_STATUS" "$2 (exit status)"
}

# assert_contains — check that a text contains a fixed substring.
# Args:    $1 text; $2 substring; $3 label
# Returns: 0 always
# Globals: none
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing [$2] in [$1]"; fi
}

# assert_not_contains — check that a text lacks a fixed substring.
# Args:    $1 text; $2 substring; $3 label
# Returns: 0 always
# Globals: none
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected [$2] in [$1]"; fi
}

# assert_file_content — compare a file with the expected text exactly.
# Args:    $1 file; $2 expected content (without the final newline); $3 label
# Returns: 0 always
# Globals: none
assert_file_content() {
  local actual='<missing file>'
  [ -e "$1" ] && actual="$(<"$1")"
  assert_eq "$2" "$actual" "$3"
}

# assert_no_file — check that a path does not exist.
# Args:    $1 path; $2 label
# Returns: 0 always
# Globals: none
assert_no_file() {
  if [ ! -e "$1" ]; then pass "$2"; else fail "$2" "unexpected file exists"; fi
}

# assert_file_exists — check that a path exists.
# Args:    $1 path; $2 label
# Returns: 0 always
# Globals: none
assert_file_exists() {
  if [ -e "$1" ]; then pass "$2"; else fail "$2" "file missing"; fi
}

# test_finish — print the summary and exit non-zero when anything failed.
# Args:    none
# Returns: exits 0 (all passed) or 1
# Globals: reads TEST_PASS, TEST_FAIL
test_finish() {
  printf 'SUMMARY %d passed, %d failed\n' "$TEST_PASS" "$TEST_FAIL"
  [ "$TEST_FAIL" -eq 0 ]
  exit
}
