#!/usr/bin/env bash
# test-legacy.sh — suite: the bash fallback (E8): option strings, step math, toggle/reset/clamp,
# state file, and the flock race proof (with a mutation that must make the race visible).
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/test-lib.sh"
test_init legacy

# fake_zoom — print the zoom the fake compositor currently holds, two decimals.
# Args:    none
# Returns: 0 always; stdout: for example 1.10
# Globals: reads the fake state dir
fake_zoom() {
  printf '%.2f\n' "$(<"$FAKE_DIR/zoom")"
}

# use_add_mode — write a user config with the additive step model (easy to verify by hand).
# Args:    $1 step (default 0.10)
# Returns: 0 always
# Globals: writes the user config file
use_add_mode() {
  mkdir -p "$(dirname -- "$ZC_USER_CONFIG")"
  printf 'ZOOM_STEP=%s\nZOOM_STEP_MODE=add\n' "${1:-0.10}" > "$ZC_USER_CONFIG"
}

# parallel_in — start N concurrent `in` calls with the given CLI and return the final zoom.
# Args:    $1 path of the zoomctl script; $2 number of calls
# Returns: 0 always; stdout: the final fake zoom (two decimals)
# Globals: reads TEST_ENV
parallel_in() {
  local call_index
  rm -f "$FAKE_DIR/zoom"
  # Every call is a separate process, like 10 scroll notches arriving at once.
  for ((call_index = 0; call_index < $2; call_index++)); do
    "${TEST_ENV[@]}" FAKE_HYPRCTL_LATENCY=0.05 "$1" in >/dev/null 2>&1 </dev/null &
  done
  wait
  fake_zoom
}

# test_option_strings — what the fallback sends on each kind of Hyprland.
# Args:    none
# Returns: 0 always
# Globals: none
test_option_strings() {
  reset_sandbox
  set_fake_mode lua-no-engine
  run_zoomctl in
  assert_status 0 "legacy lua: in succeeds without the engine"
  assert_contains "$(fake_calls)" 'eval hl.config({ cursor = { zoom_factor = 1.10, zoom_rigid = true, zoom_detached_camera = false, zoom_disable_aa = false }, binds = { scroll_event_delay = 0 } })' \
    "legacy lua: one hl.config table with zoom, tracking flags and scroll delay"
  assert_eq "1.10" "$(fake_zoom)" "legacy lua: zoom applied"
  reset_sandbox
  set_fake_mode hyprlang
  run_zoomctl in
  assert_status 0 "legacy hyprlang: in succeeds"
  assert_contains "$(fake_calls)" '--batch keyword cursor:zoom_factor 1.10 ; keyword cursor:zoom_rigid true ; keyword cursor:zoom_detached_camera false ; keyword cursor:zoom_disable_aa false ; keyword binds:scroll_event_delay 0' \
    "legacy hyprlang: one --batch with keywords"
  run_zoomctl set tracking follow
  run_zoomctl set smooth-images off
  run_zoomctl in
  assert_contains "$(fake_calls)" 'keyword cursor:zoom_rigid false ; keyword cursor:zoom_detached_camera false ; keyword cursor:zoom_disable_aa true' \
    "legacy hyprlang: tracking follow and crisp images map to options"
}

# test_step_math — multiplicative and additive steps, clamping, rounding.
# Args:    none
# Returns: 0 always
# Globals: none
test_step_math() {
  reset_sandbox
  set_fake_mode hyprlang
  run_zoomctl in 3
  assert_eq "1.33" "$(fake_zoom)" "math: multiply 1.00 x1.1 x1.1 x1.1 = 1.33"
  run_zoomctl out
  assert_eq "1.21" "$(fake_zoom)" "math: multiply out divides by 1.1"
  run_zoomctl set step 0.01
  run_zoomctl in
  assert_eq "1.22" "$(fake_zoom)" "math: tiny step never stalls (at least one hundredth)"
  reset_sandbox
  set_fake_mode hyprlang
  use_add_mode 0.25
  run_zoomctl in 2
  assert_eq "1.50" "$(fake_zoom)" "math: add mode adds step per notch"
  run_zoomctl out 5
  assert_eq "1.00" "$(fake_zoom)" "math: zooming out stops at ZOOM_MIN"
  printf 'ZOOM_STEP=2.00\nZOOM_STEP_MODE=add\nZOOM_MAX=3\n' > "$ZC_USER_CONFIG"
  run_zoomctl in 4
  assert_eq "3.00" "$(fake_zoom)" "math: zooming in stops at ZOOM_MAX"
  run_zoomctl zoom 7
  assert_eq "3.00" "$(fake_zoom)" "math: absolute zoom is clamped to the configured bounds"
}

# test_toggle_reset_zoom — toggle remembers the level, reset forgets it, zoom jumps.
# Args:    none
# Returns: 0 always
# Globals: none
test_toggle_reset_zoom() {
  reset_sandbox
  set_fake_mode hyprlang
  run_zoomctl zoom 2.5
  assert_eq "2.50" "$(fake_zoom)" "toggle: zoom jumps to 2.50"
  run_zoomctl toggle
  assert_eq "1.00" "$(fake_zoom)" "toggle: zoomed in -> reset zoom"
  assert_eq $'saved_zoom=2.50\nzoom=1.00' "$(sort "$ZC_STATE_DIR/state")" \
    "toggle: saved level and zoom in the state file"
  run_zoomctl toggle
  assert_eq "2.50" "$(fake_zoom)" "toggle: at reset zoom -> last level"
  run_zoomctl reset
  assert_eq "1.00" "$(fake_zoom)" "reset: back to the reset zoom"
  run_zoomctl toggle
  assert_eq "1.00" "$(fake_zoom)" "reset: forgot the saved level, toggle has nothing to restore"
  assert_status 0 "toggle: nothing to restore is not an error"
}

# test_state_and_01_compat — state dir mode and the 0.1 last_zoom file.
# Args:    none
# Returns: 0 always
# Globals: none
test_state_and_01_compat() {
  reset_sandbox
  set_fake_mode hyprlang
  run_zoomctl in
  assert_eq "700" "$(stat -c '%a' "$ZC_STATE_DIR")" "state: directory is 0700"
  assert_eq "zoom=1.10" "$(<"$ZC_STATE_DIR/state")" "state: zoom persisted (C5 format)"
  reset_sandbox
  set_fake_mode hyprlang
  mkdir -p "$TEST_SANDBOX/run/zoomctl"
  printf '3.00\n' > "$TEST_SANDBOX/run/zoomctl/last_zoom"
  run_zoomctl toggle
  assert_eq "3.00" "$(fake_zoom)" "compat: 0.1 last_zoom honoured as the saved zoom"
}

# test_filter_unsupported — filters need the engine; the fallback says so.
# Args:    none
# Returns: 0 always
# Globals: none
test_filter_unsupported() {
  local mode
  for mode in hyprlang lua-no-engine; do
    reset_sandbox
    set_fake_mode "$mode"
    run_zoomctl filter on
    assert_status 1 "filter on $mode: not supported"
    assert_contains "$ZC_ERR" "not supported on the legacy config" "filter on $mode: explains why"
  done
}

# test_flock_race — concurrent `in` never loses a step; a lock-less copy does (the proof bites).
# Args:    none
# Returns: 0 always
# Globals: none
test_flock_race() {
  local mutant_root="$TEST_SANDBOX/mutant" mode
  # The real CLI, in both fallback situations: every notch must count.
  for mode in hyprlang lua-no-engine; do
    reset_sandbox
    set_fake_mode "$mode"
    use_add_mode 0.10
    assert_eq "2.00" "$(parallel_in "$ZOOMCTL" 10)" "race ($mode): 10 concurrent in = 10 steps"
  done
  # Mutation: a copy of the code base whose lock line is a no-op (schema copied alongside).
  mkdir -p "$mutant_root/src" "$mutant_root/config"
  cp -r "$TEST_ROOT/src/." "$mutant_root/src/"
  cp "$SCHEMA_FILE" "$mutant_root/config/"
  # shellcheck disable=SC2016  # the pattern must contain a literal dollar sign
  sed -i 's/flock --timeout "\$ZOOMCTL_LOCK_TIMEOUT_SECONDS" 9 || {/true || {/' \
    "$mutant_root/src/lib/state.sh"
  if cmp -s "$mutant_root/src/lib/state.sh" "$TEST_ROOT/src/lib/state.sh"; then
    fail "race mutation applied"
  else
    pass "race mutation applied"
  fi
  reset_sandbox
  set_fake_mode hyprlang
  use_add_mode 0.10
  if [ "$(parallel_in "$mutant_root/src/zoomctl" 10)" != "2.00" ]; then
    pass "race: without flock steps are lost (the test proves the lock matters)"
  else
    fail "race: without flock steps are lost (the test proves the lock matters)"
  fi
}

test_option_strings
test_step_math
test_toggle_reset_zoom
test_state_and_01_compat
test_filter_unsupported
test_flock_race
test_finish
