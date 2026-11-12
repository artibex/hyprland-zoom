#!/usr/bin/env bash
# test-cli-nested.sh — drive the whole zoomctl CLI against a real nested Hyprland (engine present).
# Phase 1: Lua config with the merged engine loaded from this checkout, wired by `zoomctl setup`.
# Phase 2: hyprlang config without the engine, to prove the bash fallback on a real compositor.
# Local only: a window of the nested compositor appears in the live session for ~1 minute.
# Exit 0 = all checks passed or SKIP (no Wayland session / missing tools); 1 = a check failed.
# Safety: every compositor call goes through nested-hyprland.sh or an explicit nested signature;
# the live session, ~/.config/hypr and ~/.config/zoomctl are never touched.
set -uo pipefail

# Locations: this directory, the repository root and the scratch directory of this test.
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
WORK="${NESTED_WORK_DIR:-$HERE/work/cli-nested}"
# The nested-instance harness and the CLI under test.
NESTED="$HERE/nested-hyprland.sh"
ZOOMCTL="$REPO/src/zoomctl"
# Counters of the final summary.
PASS_COUNT=0
FAIL_COUNT=0
# Tools the test needs; a missing one turns the whole run into a SKIP.
REQUIRED_TOOLS=(Hyprland hyprctl jq)
# The status keys of contract C6, in order.
C6_KEYS='engine version hyprland zoom saved_zoom tracking tracking_effective edge_margin plugin
filter filter_active filter_shader scroll_event_delay_ms'
# Per-phase environment of every zoomctl call (state directory, config paths, share dir).
ZC_ENV=()
# Where zc keeps the stderr of its last call (parallel callers point it at /dev/null).
ZC_ERR_FILE=''

# record_result — print and count one check result.
# Args:    $1 PASS or FAIL; $2 label
# Returns: 0 always
# Globals: writes PASS_COUNT, FAIL_COUNT
record_result() {
  # Count first, then print the stable "STATUS label" line.
  if [[ "$1" == PASS ]]; then PASS_COUNT=$((PASS_COUNT + 1)); else FAIL_COUNT=$((FAIL_COUNT + 1)); fi
  echo "$1 $2"
}

# expect_equal — compare two values.
# Args:    $1 label; $2 actual; $3 expected
# Returns: 0 always; prints PASS/FAIL (with both values on failure)
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_equal() {
  # Show both values on failure so the log is self-explanatory.
  if [[ "$2" == "$3" ]]; then
    record_result PASS "$1"
  else
    record_result FAIL "$1 (expected '$3', got '$2')"
  fi
}

# expect_contains — check that text contains a substring.
# Args:    $1 label; $2 text; $3 needle
# Returns: 0 always; prints PASS/FAIL
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_contains() {
  # Plain substring match, no pattern syntax.
  if [[ "$2" == *"$3"* ]]; then
    record_result PASS "$1"
  else
    record_result FAIL "$1 (missing '$3' in '$2')"
  fi
}

# expect_lacks — check that text does not contain a substring.
# Args:    $1 label; $2 text; $3 needle
# Returns: 0 always; prints PASS/FAIL
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_lacks() {
  # Plain substring match, no pattern syntax.
  if [[ "$2" != *"$3"* ]]; then
    record_result PASS "$1"
  else
    record_result FAIL "$1 (unexpected '$3' in '$2')"
  fi
}

# nested — run the nested-instance harness with this test's state directory.
# Args:    $@ harness arguments
# Returns: the harness exit status
# Globals: reads WORK, NESTED
nested() {
  # The harness gets its own state directory; nothing is exported into the caller's shell.
  NESTED_STATE_DIR="$WORK/state" bash "$NESTED" "$@"
}

# zc — run zoomctl against the nested instance ONLY; stdout is zoomctl's, stderr is kept aside.
# Args:    $@ zoomctl arguments
# Returns: zoomctl's exit status; 99 without a recorded nested instance (never the live one)
# Globals: reads WORK, ZC_ENV, ZC_ERR_FILE
zc() {
  local signature
  # No recorded instance means no run: hyprctl must never fall back to the live session.
  signature="$(nested sig 2> /dev/null)" || return 99
  [[ -n "$signature" ]] || return 99
  # A scrubbed environment: only the nested signature, the runtime dir and the test paths.
  env -i PATH="$PATH" HOME="$WORK/home" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" LC_ALL=C \
    HYPRLAND_INSTANCE_SIGNATURE="$signature" "${ZC_ENV[@]}" "$ZOOMCTL" "$@" \
    2> "${ZC_ERR_FILE:-$WORK/last.err}"
}

# zc_offline — run zoomctl with no compositor at all (the `setup` step before the first start).
# Args:    $@ zoomctl arguments
# Returns: zoomctl's exit status
# Globals: reads WORK, ZC_ENV
zc_offline() {
  # No runtime dir and no signature: hyprctl cannot reach any compositor, live or nested.
  env -i PATH="$PATH" HOME="$WORK/home" LC_ALL=C "${ZC_ENV[@]}" "$ZOOMCTL" "$@" \
    2> "$WORK/last.err"
}

# zq — like zc, for commands whose stdout (the echoed KEY=VALUE lines) is of no interest.
# Args:    $@ zoomctl arguments
# Returns: zoomctl's exit status
# Globals: none
zq() {
  zc "$@" > /dev/null
}

# status_value — read one key of `zoomctl status --porcelain`.
# Args:    $1 key name
# Returns: 0 and the value on stdout (empty when the key is missing)
# Globals: none
status_value() {
  zc status --porcelain | sed -n "s/^$1=//p"
}

# option_value — read a Hyprland option of the nested instance.
# Args:    $1 option name such as cursor:zoom_factor
# Returns: 0 and the value on stdout
# Globals: none
option_value() {
  # Booleans may be `false`, which jq's `//` would skip, so pick the first non-null field.
  nested ctl -j getoption "$1" \
    | jq -r '[.float, .int, .bool, .str, .custom] | map(select(. != null))
      | (if length > 0 then .[0] else "" end) | tostring
      | if . == "[[EMPTY]]" then "" else . end'
}

# option_flag — read a boolean Hyprland option as true/false (hyprlang reports 0/1, Lua true/false).
# Args:    $1 option name
# Returns: 0 and true or false on stdout
# Globals: none
option_flag() {
  # Both the integer and the boolean spelling of "on" count as true.
  case "$(option_value "$1")" in
    1|true) echo true ;;
    *) echo false ;;
  esac
}

# zoom_now — the compositor's zoom factor with two decimals.
# Args:    none
# Returns: 0 and the factor on stdout
# Globals: none
zoom_now() {
  printf '%.2f' "$(option_value cursor:zoom_factor)"
}

# expect_zoom — check the zoom reported by zoomctl and held by the compositor.
# Args:    $1 label; $2 expected zoom with two decimals
# Returns: 0 always; prints two results
# Globals: none
expect_zoom() {
  expect_equal "$1: status zoom" "$(status_value zoom)" "$2"
  expect_equal "$1: compositor zoom_factor" "$(zoom_now)" "$2"
}

# wait_until — poll a command until it succeeds.
# Args:    $1 seconds to wait at most; remaining arguments: the command
# Returns: 0 when the command succeeded in time; 1 on timeout
# Globals: none
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  # Check every 0.2 s so short waits stay cheap.
  while ! "$@" > /dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 0.2
  done
}

# missing_tools — list required tools that are not installed.
# Args:    none
# Returns: 0 always; stdout: the missing tool names, space separated
# Globals: reads REQUIRED_TOOLS
missing_tools() {
  local tool missing=""
  for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
  done
  echo "${missing# }"
}

# should_skip — decide whether the test can run here.
# Args:    none
# Returns: 0 and a reason on stdout when the test must be skipped; 1 when it can run
# Globals: none
should_skip() {
  local missing
  # A nested Hyprland needs a parent Wayland session to attach to.
  if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo "no Wayland session (WAYLAND_DISPLAY/XDG_RUNTIME_DIR unset)"
    return 0
  fi
  # Every external tool the checks use must be present.
  missing="$(missing_tools)"
  if [[ -n "$missing" ]]; then
    echo "missing tools: $missing"
    return 0
  fi
  return 1
}

# set_phase_env — choose the state and config paths every zoomctl call of a phase uses.
# Args:    $1 phase name (engine|legacy)
# Returns: 0 always
# Globals: writes ZC_ENV; creates the phase directories below WORK
set_phase_env() {
  mkdir -p "$WORK/$1/user"
  # The same variables go to the nested compositor, so engine and CLI read the same files.
  ZC_ENV=(ZOOMCTL_STATE_DIR="$WORK/$1/state" ZOOMCTL_USER_CONFIG="$WORK/$1/user/zoom.conf"
    ZOOMCTL_SYSTEM_CONFIG="$WORK/system.conf" ZOOMCTL_SHARE_DIR="$REPO/src/lua"
    ZOOMCTL_TARGET_HOME="$WORK/home" ZOOMCTL_SETTINGS_BIN="$REPO/src/ui/hyprland-zoom-settings")
}

# write_lua_config — the user's hyprland.lua before `zoomctl setup`: fixed geometry, no engine.
# Args:    none
# Returns: 0 always; writes $WORK/home/.config/hypr/hyprland.lua
# Globals: reads WORK
write_lua_config() {
  mkdir -p "$WORK/home/.config/hypr"
  # Fixed output, no gaps or borders, and no donation nag overlay in the screenshots.
  {
    echo 'hl.monitor({ output = "HEADLESS-1", mode = "1280x720@60", position = "0x0", scale = 1 })'
    echo 'hl.config({ general = { gaps_in = 0, gaps_out = 0, border_size = 0 } })'
    echo 'hl.config({ ecosystem = { no_donation_nag = true, no_update_news = true } })'
  } > "$WORK/home/.config/hypr/hyprland.lua"
}

# start_nested — start the nested Hyprland with a config and the phase's ZOOMCTL_* variables.
# Args:    $1 config file
# Returns: 0 when it is up; 1 otherwise
# Globals: reads ZC_ENV, WORK
start_nested() {
  # The variables are inherited by the nested compositor (the engine reads them) only.
  env "${ZC_ENV[@]}" NESTED_STATE_DIR="$WORK/state" bash "$NESTED" start "$1" > /dev/null
}

# stop_nested — stop the nested instance (also used by the EXIT trap).
# Args:    none
# Returns: 0 always
# Globals: none
stop_nested() {
  nested stop > /dev/null 2>&1 || true
}

# compositor_ready — true when zoomctl reaches the compositor (engine or fallback).
# Args:    none
# Returns: 0 reachable; 1 otherwise
# Globals: none
compositor_ready() {
  [[ "$(status_value engine)" == legacy ]]
}

# engine_ready — true when zoomctl sees the loaded engine.
# Args:    none
# Returns: 0 engine=lua; 1 otherwise
# Globals: none
engine_ready() {
  [[ "$(status_value engine)" == lua ]]
}

# check_setup_wiring — `zoomctl setup` writes the engine include into the user's hyprland.lua.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK, REPO
check_setup_wiring() {
  local lua_file="$WORK/home/.config/hypr/hyprland.lua" engine_line status=0
  engine_line="dofile(\"$REPO/src/lua/hyprland-zoom.lua\")"
  zc_offline setup > /dev/null || status=$?
  expect_equal "setup exits 0" "$status" "0"
  expect_equal "setup appends exactly one engine include" \
    "$(grep -cFx -- "$engine_line" "$lua_file")" "1"
  zc_offline setup > "$WORK/setup2.out" || status=$?
  expect_contains "second setup is idempotent" "$(< "$WORK/setup2.out")" "already present"
  expect_equal "one backup of the original, none for the repeat" \
    "$(find "$(dirname "$lua_file")" -name 'hyprland.lua.zoomctl-bak-*' | grep -c .)" "1"
}

# check_status_porcelain — the C6 key set comes straight from the engine.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads C6_KEYS, REPO
check_status_porcelain() {
  local keys expected_keys
  keys="$(zc status --porcelain | cut -d= -f1 | tr '\n' ' ')"
  # The C6 list is written over two lines; both sides end up as one blank-separated line.
  expected_keys="$(tr '\n' ' ' <<< "$C6_KEYS")"
  expect_equal "status --porcelain: C6 keys in order" "${keys% }" "${expected_keys% }"
  expect_equal "status: engine=lua" "$(status_value engine)" "lua"
  expect_equal "status: version is the VERSION file" "$(status_value version)" "$(< "$REPO/VERSION")"
  expect_equal "status: unzoomed at start" "$(status_value zoom)" "1.00"
  expect_contains "status (human) shows the heading" "$(zc status)" "Hyprland zoom status"
}

# check_zoom_commands — in/out/zoom/toggle/reset drive the compositor's zoom exactly.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_zoom_commands() {
  local status=0
  zc in || status=$?
  expect_equal "in exits 0" "$status" "0"
  expect_zoom "in" "1.10"
  zc in 3
  expect_zoom "in 3 (1.1^4)" "1.46"
  zc out
  expect_zoom "out" "1.33"
  zc zoom 2.5
  expect_zoom "zoom 2.5" "2.50"
  zc toggle
  expect_zoom "toggle -> reset zoom" "1.00"
  zc toggle
  expect_zoom "toggle -> last level" "2.50"
  zc reset
  expect_zoom "reset" "1.00"
  zc zoom 11 > /dev/null || status=$?
  expect_equal "zoom 11 is refused (exit 1)" "$status" "1"
  expect_zoom "refused zoom changes nothing" "1.00"
}

# check_tracking_modes — `tracking` and `set tracking` persist and reach Hyprland's options.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_tracking_modes() {
  local mode expected
  # name:rigid:detached as verified in spike S1 (Q7) and by the engine test.
  for mode in edge:false:true follow:false:false centered:true:false; do
    zq tracking "${mode%%:*}"
    expected="${mode#*:}"
    expect_equal "tracking ${mode%%:*}: rigid/detached" \
      "$(option_value cursor:zoom_rigid):$(option_value cursor:zoom_detached_camera)" "$expected"
    expect_equal "tracking ${mode%%:*}: status" "$(status_value tracking)" "${mode%%:*}"
  done
  zq set tracking margin
  expect_equal "margin without the plugin degrades to edge" \
    "$(status_value tracking_effective)" "edge"
  zq unset tracking
}

# check_settings_reload — set/unset/reset-config reach the running engine without a restart.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK
check_settings_reload() {
  local user_file="$WORK/engine/user/zoom.conf"
  zq set scroll-event-delay-ms 50
  expect_equal "set: scroll_event_delay applied live" "$(option_value binds:scroll_event_delay)" "50"
  zq unset scroll-event-delay-ms
  expect_equal "unset: back to the schema default" "$(option_value binds:scroll_event_delay)" "0"
  zq set zoom-smooth-images off
  expect_equal "set: crisp images switch antialiasing off" \
    "$(option_value cursor:zoom_disable_aa)" "true"
  zq set step 0.25 step-mode multiply tracking edge
  expect_equal "multi-key set: one canonical file" "$(< "$user_file")" \
    $'ZOOM_STEP=0.25\nZOOM_STEP_MODE=multiply\nZOOM_SMOOTH_IMAGES=off\nZOOM_TRACKING=edge'
  zc in
  expect_zoom "new step 0.25 is in effect" "1.25"
  zq reset-config
  expect_equal "reset-config removes the user file" "$([[ -e "$user_file" ]] && echo yes || echo no)" "no"
  expect_equal "reset-config re-applies the defaults live" \
    "$(option_value cursor:zoom_disable_aa):$(option_value cursor:zoom_rigid)" "false:true"
  zc reset
  expect_equal "get reads the effective value" "$(zc get step)" "0.10"
}

# check_bind_reload — bind settings re-bind the engine's keys on reload.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_bind_reload() {
  local binds
  zq set BIND_MODIFIERS "SUPER + CTRL"
  binds="$(nested ctl -j binds | jq -r '.[] | "\(.modmask) \(.key) \(.description)"')"
  expect_contains "modifiers as ONE argument re-bind key I on SUPER+CTRL" \
    "$binds" "68 I hyprland-zoom: Zoom in"
  zq set BIND_KEY_IN ""
  binds="$(nested ctl -j binds | jq -r '.[] | "\(.modmask) \(.key) \(.description)"')"
  expect_lacks "an empty argument disables the key bind" "$binds" "68 I hyprland-zoom: Zoom in"
  zq reset-config
  binds="$(nested ctl -j binds | jq -r '.[] | "\(.modmask) \(.key) \(.description)"')"
  expect_contains "reset-config restores SUPER+ALT+I" "$binds" "72 I hyprland-zoom: Zoom in"
}

# check_filter_commands — filter on/off/toggle/<name> switch the screen shader.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_filter_commands() {
  local status=0
  zc filter on
  expect_equal "filter on: active" "$(status_value filter_active)" "on"
  expect_lacks "filter on: a shader path is reported" "$(status_value filter_shader)" "none"
  expect_equal "filter on: Hyprland got a screen shader" \
    "$([[ -n "$(option_value decoration:screen_shader)" ]] && echo set || echo empty)" "set"
  zc filter off
  expect_equal "filter off: inactive" "$(status_value filter_active)" "off"
  expect_equal "filter off: screen_shader option empty" "$(option_value decoration:screen_shader)" ""
  zc filter toggle
  expect_equal "filter toggle: on" "$(status_value filter_active)" "on"
  zc filter toggle
  expect_equal "filter toggle: off again" "$(status_value filter_active)" "off"
  zc filter Grayscale
  expect_equal "filter <name>: selected and on" \
    "$(status_value filter):$(status_value filter_active)" "grayscale:on"
  zc filter nope > /dev/null || status=$?
  expect_equal "filter with an unknown name exits 1" "$status" "1"
  zc filter off
}

# check_preview — preview applies settings live, writes nothing, and --end restores them.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK
check_preview() {
  local status=0
  zc preview step=0.5
  zc in
  expect_zoom "preview step=0.5 is in effect" "1.50"
  zc reset
  zc preview --end
  zc in
  expect_zoom "preview --end restores the saved step" "1.10"
  zc reset
  zc preview FILTER=invert FILTER_ACTIVE=on
  expect_equal "preview filter: on with the previewed filter" \
    "$(status_value filter):$(status_value filter_active)" "invert:on"
  expect_equal "preview wrote no user file" \
    "$([[ -e "$WORK/engine/user/zoom.conf" ]] && echo yes || echo no)" "no"
  zc preview --end
  expect_equal "preview --end: filter off again" "$(status_value filter_active)" "off"
  zc preview ZOOM_STEP=abc > /dev/null || status=$?
  expect_equal "preview with a bad value exits 1" "$status" "1"
}

# check_doctor — the doctor reports a healthy engine setup.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_doctor() {
  local report status=0
  report="$(zc doctor)" || status=$?
  expect_equal "doctor exits 0" "$status" "0"
  expect_contains "doctor: Lua config, engine loaded" "$report" "[ok  ] Lua config, engine loaded"
  expect_contains "doctor: engine include present" "$report" "[ok  ] engine include present"
  expect_contains "doctor: engine warnings answered" "$report" "[ok  ] engine reports no configuration warnings"
  expect_contains "doctor: settings app found in the checkout" "$report" "[ok  ] settings app found"
  expect_lacks "doctor: no warning line at all" "$report" "[warn]"
  expect_contains "doctor: scroll_event_delay ok" "$report" "[ok  ] scroll_event_delay is 0 ms"
}

# check_concurrent_notches — 20 concurrent `zoomctl in` end exactly at 1.1^20.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_concurrent_notches() {
  local _
  # Every call is a separate zoomctl process, like 20 scroll notches arriving at once.
  for _ in $(seq 1 20); do
    ZC_ERR_FILE=/dev/null zc in > /dev/null &
  done
  wait
  expect_zoom "20 concurrent in = 1.1^20" "6.73"
  zc reset
}

# check_error_exit_codes — usage mistakes and invalid values exit 2 and 1.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_error_exit_codes() {
  local status=0
  zq set step abc || status=$?
  expect_equal "set with a bad value exits 1" "$status" "1"
  zc in 0 > /dev/null || status=$?
  expect_equal "in 0 is a usage error (2)" "$status" "2"
  zc frobnicate > /dev/null || status=$?
  expect_equal "unknown command is a usage error (2)" "$status" "2"
}

# run_engine_phase — Lua config, engine loaded: everything through zoomctl.
# Args:    none
# Returns: 0 when the instance came up; 1 otherwise
# Globals: reads WORK
run_engine_phase() {
  set_phase_env engine
  write_lua_config
  : > "$WORK/system.conf"
  # The user's flow: wire the config first, then start Hyprland with it.
  check_setup_wiring
  start_nested "$WORK/home/.config/hypr/hyprland.lua" || return 1
  wait_until 15 engine_ready || return 1
  check_status_porcelain
  check_zoom_commands
  check_tracking_modes
  check_settings_reload
  check_bind_reload
  check_filter_commands
  check_preview
  check_doctor
  check_concurrent_notches
  check_error_exit_codes
}

# check_legacy_commands — the zoom commands on the bash fallback, against the real compositor.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_legacy_commands() {
  local status=0
  expect_equal "legacy: engine=legacy" "$(status_value engine)" "legacy"
  zc in
  expect_zoom "legacy: in" "1.10"
  zc in 2
  expect_zoom "legacy: in 2 (rounded per notch)" "1.33"
  zc zoom 3
  expect_zoom "legacy: zoom 3" "3.00"
  zc toggle
  expect_zoom "legacy: toggle -> reset" "1.00"
  zc toggle
  expect_zoom "legacy: toggle -> last level" "3.00"
  zc reset
  zc filter on > /dev/null || status=$?
  expect_equal "legacy: filter is not supported (exit 1)" "$status" "1"
  expect_contains "legacy: filter says why" "$(< "$WORK/last.err")" "not supported on the legacy config"
}

# check_legacy_extras — tracking options, concurrency, preview refusal and doctor on hyprlang.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_legacy_extras() {
  local status=0 _
  zq set tracking follow
  expect_equal "legacy: tracking follow reaches the options" \
    "$(option_flag cursor:zoom_rigid):$(option_flag cursor:zoom_detached_camera)" "false:false"
  zq set step-mode add step 0.10 tracking centered
  zc reset
  for _ in $(seq 1 10); do
    ZC_ERR_FILE=/dev/null zc in > /dev/null &
  done
  wait
  expect_zoom "legacy: 10 concurrent in (add mode) = 2.00" "2.00"
  zc preview step=0.2 > /dev/null || status=$?
  expect_equal "legacy: preview needs the engine (exit 1)" "$status" "1"
  expect_contains "legacy: doctor names the hyprlang config" "$(zc doctor)" "legacy hyprlang config"
  zq reset-config
}

# run_legacy_phase — hyprlang config without the engine: the bash fallback still works.
# Args:    none
# Returns: 0 when the instance came up; 1 otherwise
# Globals: reads WORK
run_legacy_phase() {
  stop_nested
  set_phase_env legacy
  # A hyprlang config: no Lua, so no engine can be loaded.
  printf 'misc {\n    disable_hyprland_logo = true\n}\n' > "$WORK/legacy.conf"
  start_nested "$WORK/legacy.conf" || return 1
  wait_until 15 compositor_ready || return 1
  check_legacy_commands
  check_legacy_extras
}

# summarize — print the totals and return the overall status.
# Args:    none
# Returns: 0 when nothing failed; 1 otherwise
# Globals: reads PASS_COUNT, FAIL_COUNT
summarize() {
  echo "cli nested test: $PASS_COUNT passed, $FAIL_COUNT failed"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

# main — run both phases in nested Hyprland instances.
# Args:    none
# Returns: 0 when everything passed or the test was skipped; 1 otherwise
# Globals: none
main() {
  local reason
  # SKIP (not fail) where the test cannot run at all, with a clear reason.
  if reason="$(should_skip)"; then
    echo "SKIP cli nested test: $reason"
    return 0
  fi
  rm -rf "$WORK"
  mkdir -p "$WORK"
  trap stop_nested EXIT
  run_engine_phase || { echo "FAIL the engine phase could not start"; return 1; }
  run_legacy_phase || { echo "FAIL the legacy phase could not start"; return 1; }
  summarize
}

main "$@"
