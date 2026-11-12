#!/usr/bin/env bash
# test-forwarding.sh — suite: engine forwarding strings (C4), injection rejection, preview, status,
# doctor, help, exit codes and the settings-app launcher.
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/test-lib.sh"
test_init forwarding

# assert_calls — compare the recorded hyprctl calls with the expected text exactly.
# Args:    $1 expected calls (newline separated; empty for none); $2 label
# Returns: 0 always
# Globals: none
assert_calls() {
  assert_eq "$1" "$(fake_calls)" "$2"
}

# test_zoom_forwarding — one eval per action with exactly the contract strings.
# Args:    none
# Returns: 0 always
# Globals: none
test_zoom_forwarding() {
  local command_line expected
  local -a command_words
  for command_line in 'in:HyprZoom.zoom_in(1)' 'in 3:HyprZoom.zoom_in(3)' 'in 007:HyprZoom.zoom_in(7)' \
    'out:HyprZoom.zoom_out(1)' 'out 2:HyprZoom.zoom_out(2)' 'toggle:HyprZoom.toggle()' \
    'reset:HyprZoom.reset()' 'zoom 2.5:HyprZoom.set_zoom(2.50)' 'zoom 10:HyprZoom.set_zoom(10.00)' \
    'filter:HyprZoom.filter("toggle")' 'filter on:HyprZoom.filter("on")' \
    'filter OFF:HyprZoom.filter("off")' 'filter smart-invert:HyprZoom.filter("smart-invert")' \
    'filter Grayscale:HyprZoom.filter("grayscale")'; do
    reset_sandbox
    set_fake_mode engine
    # The command words are space separated and never contain shell syntax.
    read -ra command_words <<< "${command_line%%:*}"
    run_zoomctl "${command_words[@]}"
    expected="eval ${command_line#*:}"
    assert_status 0 "forward [${command_line%%:*}]"
    assert_calls "$expected" "forward [${command_line%%:*}] sends exactly one eval"
  done
}

# test_injection_rejected — hostile arguments never reach hyprctl.
# Args:    none
# Returns: 0 always
# Globals: none
test_injection_rejected() {
  local arguments
  local -a argument_list
  reset_sandbox
  set_fake_mode engine
  # Each case is one command line; '|' separates the arguments so no shell parsing is involved.
  for arguments in 'in|1)os.exit()' 'in|0' 'in|101' 'in|-1' 'in|1.5' 'in|1|2' 'out|1;1' \
    'zoom|11' 'zoom|0.5' 'zoom|abc' 'zoom|2)os.exit()' 'zoom' 'zoom|1|2' \
    'filter|nope' 'filter|x")os.exit()--' 'filter|on|off' 'toggle|now' 'reset|now'; do
    IFS='|' read -ra argument_list <<< "$arguments"
    run_zoomctl "${argument_list[@]}"
    if [ "$ZC_STATUS" -ne 0 ]; then pass "reject [$arguments]"; else fail "reject [$arguments]" "exit 0"; fi
  done
  run_zoomctl in ''
  assert_status 2 "reject: empty notch count is not the default"
  assert_calls "" "reject: no hostile argument produced a hyprctl call"
  run_zoomctl in '1)os.exit()'
  assert_status 2 "reject: bad notch count is a usage error"
  run_zoomctl set step '1)os.exit()'
  assert_status 1 "reject: bad set value is an error"
  assert_not_contains "$(fake_calls)" "os.exit" "reject: set never forwards the text"
  run_zoomctl set bind-key-in 'I"), os.exit() --'
  assert_status 1 "reject: bad key name"
  assert_not_contains "$(fake_calls)" "os.exit" "reject: key name never forwarded"
}

# test_engine_failure_paths — engine errors and absent compositors give clear errors.
# Args:    none
# Returns: 0 always
# Globals: none
test_engine_failure_paths() {
  reset_sandbox
  set_fake_mode engine
  printf 'error: [string "return HyprZoom.zoom_in(1)"]:1: boom\n' > "$FAKE_DIR/eval_error"
  run_zoomctl in
  assert_status 1 "failure: engine error exits 1"
  assert_contains "$ZC_ERR" "the engine rejected HyprZoom.zoom_in(1)" "failure: engine error shown"
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl in
  assert_status 1 "failure: no compositor exits 1"
  assert_contains "$ZC_ERR" "not reachable" "failure: no compositor message"
}

# test_preview — preview builds a table literal from validated values only.
# Args:    none
# Returns: 0 always
# Globals: none
test_preview() {
  reset_sandbox
  set_fake_mode engine
  run_zoomctl preview ZOOM_STEP=0.15 FILTER=invert
  assert_calls 'eval HyprZoom.preview({ZOOM_STEP="0.15", FILTER="invert"})' \
    "preview: one eval with the table literal, no probe on the happy path"
  reset_sandbox
  set_fake_mode engine
  run_zoomctl preview step=0.1 bind-modifiers='super+alt' bind-key-in=
  assert_calls $'eval HyprZoom.preview({ZOOM_STEP="0.10", BIND_MODIFIERS="SUPER + ALT", BIND_KEY_IN=""})' \
    "preview: aliases resolved, values canonical, empty key allowed"
  reset_sandbox
  set_fake_mode engine
  run_zoomctl preview --end
  assert_calls 'eval HyprZoom.preview_end()' "preview --end"
  run_zoomctl preview --end now
  assert_status 2 "preview --end with extra argument"
  run_zoomctl preview
  assert_status 2 "preview without arguments"
  reset_sandbox
  set_fake_mode engine
  run_zoomctl preview ZOOM_STEP=abc
  assert_status 1 "preview: invalid value"
  run_zoomctl preview 'ZOOM_STEP=0.1"})os.exit()--'
  assert_status 1 "preview: injection attempt in a value"
  run_zoomctl preview NOPE=1
  assert_status 1 "preview: unknown key"
  run_zoomctl preview ZOOM_STEP
  assert_status 1 "preview: pair without ="
  assert_calls "" "preview: rejected input produced no call at all"
  set_fake_mode lua-no-engine
  run_zoomctl preview ZOOM_STEP=0.2
  assert_status 1 "preview: needs the engine"
  assert_contains "$ZC_ERR" "zoomctl setup" "preview: tells how to get the engine"
  set_fake_mode unreachable
  run_zoomctl preview ZOOM_STEP=0.2
  assert_contains "$ZC_ERR" "needs a running Hyprland session" "preview: no compositor explained"
}

# test_tracking_command — tracking is a persisted setting.
# Args:    none
# Returns: 0 always
# Globals: none
test_tracking_command() {
  reset_sandbox
  set_fake_mode engine
  run_zoomctl tracking edge
  assert_status 0 "tracking: edge"
  assert_file_content "$ZC_USER_CONFIG" 'ZOOM_TRACKING=edge' "tracking: written to the user file"
  assert_contains "$(fake_calls)" "eval HyprZoom.reload()" "tracking: engine reloaded"
  run_zoomctl tracking sideways
  assert_status 1 "tracking: invalid mode"
  run_zoomctl tracking
  assert_status 2 "tracking: missing mode"
}

# test_status — C6 keys, engine passthrough and the three fallback states.
# Args:    none
# Returns: 0 always
# Globals: none
test_status() {
  local c6_keys='engine version hyprland zoom saved_zoom tracking tracking_effective edge_margin plugin filter filter_active filter_shader scroll_event_delay_ms'
  reset_sandbox
  set_fake_mode engine
  printf 'engine=lua\nversion=9.9\nzoom=2.50\n' > "$FAKE_DIR/status"
  run_zoomctl status --porcelain
  assert_eq $'engine=lua\nversion=9.9\nzoom=2.50' "$ZC_OUT" "status: engine answer passed through"
  set_fake_mode unreachable
  run_zoomctl status --porcelain
  assert_status 0 "status: works without a compositor"
  assert_eq "$c6_keys" "$(cut -d= -f1 <<< "$ZC_OUT" | tr '\n' ' ' | sed 's/ $//')" "status: exact C6 key set and order"
  assert_contains "$ZC_OUT" $'engine=missing\n' "status: engine=missing when Hyprland is unreachable"
  assert_contains "$ZC_OUT" $'zoom=1.00\n' "status: neutral zoom without compositor"
  set_fake_mode lua-no-engine
  printf '2.500000\n' > "$FAKE_DIR/zoom"
  mkdir -p "$ZC_STATE_DIR"
  printf 'saved_zoom=3.00\n' > "$ZC_STATE_DIR/state"
  run_zoomctl status --porcelain
  assert_contains "$ZC_OUT" $'engine=legacy\n' "status: engine=legacy without the engine"
  assert_contains "$ZC_OUT" $'zoom=2.50\n' "status: live zoom read from Hyprland"
  assert_contains "$ZC_OUT" $'saved_zoom=3.00\n' "status: saved zoom from the state file"
  assert_contains "$ZC_OUT" $'hyprland=0.56.2\n' "status: Hyprland version"
  assert_contains "$ZC_OUT" $'plugin=missing\n' "status: plugin missing"
  assert_contains "$ZC_OUT" $'filter_active=off\n' "status: filter off on the fallback path"
  set_fake_mode hyprlang
  run_zoomctl set tracking margin
  run_zoomctl status --porcelain
  assert_contains "$ZC_OUT" $'tracking=margin\ntracking_effective=edge\n' "status: margin degrades to edge"
  run_zoomctl status
  assert_contains "$ZC_OUT" "Hyprland zoom status" "status: human view"
  run_zoomctl status --nope
  assert_status 2 "status: unknown option"
}

# test_help_and_exit_codes — help text, version, unknown commands.
# Args:    none
# Returns: 0 always
# Globals: none
test_help_and_exit_codes() {
  local heading
  reset_sandbox
  run_zoomctl help
  assert_status 0 "help"
  for heading in "Zoom:" "Settings:" "Maintenance:" "preview K=V" "doctor" "Exit status"; do
    assert_contains "$ZC_OUT" "$heading" "help mentions [$heading]"
  done
  run_zoomctl
  assert_contains "$ZC_OUT" "Usage: zoomctl" "no arguments shows help"
  assert_status 0 "no arguments"
  run_zoomctl frobnicate
  assert_status 2 "unknown command"
  assert_contains "$ZC_ERR" "unknown command 'frobnicate'" "unknown command message"
  run_zoomctl --version
  assert_eq "zoomctl $(<"$TEST_ROOT/VERSION")" "$ZC_OUT" "version comes from the VERSION file"
  assert_not_contains "$(grep -c . <<< "$ZC_OUT")" "x" "version is one line"
  run_zoomctl ''
  assert_status 2 "an empty command is a usage error, not help"
  assert_eq 0 "$(grep -ciE 'wofi|zenity|rofi' "$TEST_ROOT/src/zoomctl" "$TEST_ROOT"/src/lib/*.sh | awk -F: '{s+=$2} END {print s+0}')" \
    "old wofi/zenity/rofi menu code is gone"
}

# test_ui_launcher — `ui` and `configure` exec the settings app or explain what is missing.
# Args:    none
# Returns: 0 always
# Globals: none
test_ui_launcher() {
  reset_sandbox
  run_zoomctl ui
  assert_status 1 "ui: missing app"
  assert_contains "$ZC_ERR" "hyprland-zoom-settings is not installed" "ui: clear message"
  printf '#!/bin/sh\necho "settings-app $*"\n' > "$TEST_SANDBOX/bin/hyprland-zoom-settings"
  chmod +x "$TEST_SANDBOX/bin/hyprland-zoom-settings"
  run_zoomctl configure --page filter
  assert_eq "settings-app --page filter" "$ZC_OUT" "ui: configure execs the app with its arguments"
  rm -f "$TEST_SANDBOX/bin/hyprland-zoom-settings"
}

# test_ui_locale — the settings window gets the caller's locale back, not zoomctl's byte-wise one.
# Args:    none
# Returns: 0 always
# Globals: none
test_ui_locale() {
  reset_sandbox
  # shellcheck disable=SC2016  # the stub expands the variable itself, when it runs
  printf '#!/bin/sh\necho "locale=${LC_ALL-unset}"\n' > "$TEST_SANDBOX/bin/hyprland-zoom-settings"
  chmod +x "$TEST_SANDBOX/bin/hyprland-zoom-settings"
  ZC_EXTRA_ENV=(LC_ALL=en_US.UTF-8)
  run_zoomctl ui
  assert_eq "locale=en_US.UTF-8" "$ZC_OUT" "ui: the caller's LC_ALL is restored before exec"
  # Without LC_ALL in the caller's environment, none may appear in the app's.
  ZC_OUT="$("${TEST_ENV[@]}" env -u LC_ALL "$ZOOMCTL" ui 2>&1 </dev/null)"
  assert_eq "locale=unset" "$ZC_OUT" "ui: an unset caller locale stays unset (not zoomctl's C)"
  ZC_EXTRA_ENV=()
  rm -f "$TEST_SANDBOX/bin/hyprland-zoom-settings"
}

# test_symlinked_launcher — a launcher symlink finds the libraries of the script it points to.
# Args:    none
# Returns: 0 always
# Globals: none
test_symlinked_launcher() {
  local launcher="$TEST_SANDBOX/bin/zoomctl-launcher"
  reset_sandbox
  ln -sf "$ZOOMCTL" "$launcher"
  ZC_OUT="$("${TEST_ENV[@]}" "$launcher" version 2>&1 </dev/null)"
  assert_eq "zoomctl $(<"$TEST_ROOT/VERSION")" "$ZC_OUT" "launcher: symlink resolved (libs and VERSION found)"
  rm -f "$launcher"
}

# test_uninstall — the package is removed with `pacman -Rs`, which keeps a modified /etc file as .pacsave.
# Args:    none
# Returns: 0 always
# Globals: none
test_uninstall() {
  reset_sandbox
  printf '#!/bin/sh\n"$@"\n' > "$TEST_SANDBOX/bin/sudo"
  printf '#!/bin/sh\necho "pacman $*"\n' > "$TEST_SANDBOX/bin/pacman"
  chmod +x "$TEST_SANDBOX/bin/sudo" "$TEST_SANDBOX/bin/pacman"
  run_zoomctl uninstall --yes
  assert_eq "pacman -Rs hyprland-zoom" "$ZC_OUT" "uninstall: -Rs, never -Rns"
  run_zoomctl uninstall
  assert_contains "$ZC_OUT" "cancelled" "uninstall: no terminal and no --yes cancels"
  rm -f "$TEST_SANDBOX/bin/sudo" "$TEST_SANDBOX/bin/pacman"
}

# test_doctor — checks per compositor state, binds, scroll delay, plugin and include.
# Args:    none
# Returns: 0 always
# Globals: none
test_doctor() {
  reset_sandbox
  mkdir -p "$TEST_SANDBOX/home/.config/hypr"
  printf 'dofile("%s/hyprland-zoom.lua")\n' "$TEST_SANDBOX/share" > "$TEST_SANDBOX/home/.config/hypr/hyprland.lua"
  set_fake_mode engine
  printf '0\n' > "$FAKE_DIR/delay"
  run_zoomctl doctor
  assert_status 0 "doctor: healthy engine setup"
  assert_contains "$ZC_OUT" "[ok  ] Hyprland 0.56.2" "doctor: Hyprland version"
  assert_contains "$ZC_OUT" "[ok  ] Lua config, engine loaded" "doctor: engine loaded"
  assert_contains "$ZC_OUT" "[ok  ] engine include present" "doctor: include present"
  assert_contains "$ZC_OUT" "[ok  ] scroll_event_delay is 0 ms" "doctor: scroll delay fine"
  assert_contains "$ZC_OUT" "[info] hyprzoom plugin not loaded" "doctor: plugin optional"
  assert_contains "$ZC_OUT" "[ok  ] no conflicting binds" "doctor: no conflicts"
  assert_contains "$ZC_OUT" "[warn] hyprland-zoom-settings not found" "doctor: settings app missing is a warning"
  test_doctor_problems
}

# test_doctor_problems — failure and warning paths of the doctor.
# Args:    none
# Returns: 0 always
# Globals: none
test_doctor_problems() {
  printf '300\n' > "$FAKE_DIR/delay"
  printf 'hyprzoom 0.1\n' > "$FAKE_DIR/plugins"
  printf 'bindd\n\tmodmask: 72\n\tkey: mouse_up\n\tdescription: group next\n\n' > "$FAKE_DIR/binds"
  printf 'bindd\n\tmodmask: 72\n\tkey: mouse_up\n\tdescription: zoom in\n\n' >> "$FAKE_DIR/binds"
  printf 'bindd\n\tmodmask: 64\n\tkey: mouse_up\n\tdescription: other mod\n\n' >> "$FAKE_DIR/binds"
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[warn] bound more than once: mouse_up: group next, zoom in" "doctor: duplicate bind"
  assert_contains "$ZC_OUT" "[warn] scroll_event_delay is 300 ms, expected 0" "doctor: scroll delay mismatch"
  assert_contains "$ZC_OUT" "[ok  ] hyprzoom plugin loaded" "doctor: plugin loaded"
  set_fake_mode lua-no-engine
  run_zoomctl doctor
  assert_status 1 "doctor: engine missing fails"
  assert_contains "$ZC_OUT" "[FAIL] Lua config, but the engine is not loaded" "doctor: engine missing message"
  set_fake_mode hyprlang
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[warn] legacy hyprlang config" "doctor: hyprlang warning"
  set_fake_mode unreachable
  run_zoomctl doctor
  assert_status 1 "doctor: no compositor fails"
  assert_contains "$ZC_OUT" "[FAIL] Hyprland is not reachable" "doctor: unreachable message"
  printf -- '-- empty\n' > "$TEST_SANDBOX/home/.config/hypr/hyprland.lua"
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[FAIL] no engine include" "doctor: include missing"
  printf 'dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua")\n' > "$TEST_SANDBOX/home/.config/hypr/hyprland.lua"
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[warn] 0.1 include" "doctor: 0.1 include flagged for migration"
  mkdir -p "$(dirname -- "$ZC_USER_CONFIG")"
  printf 'ZOOM_STEP=banana\n' > "$ZC_USER_CONFIG"
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[warn] " "doctor: config warnings are listed"
  assert_contains "$ZC_OUT" "invalid value 'banana' for ZOOM_STEP" "doctor: config warning names the problem"
}

# test_doctor_extras — engine warnings, annotated includes, a missing schema, settings app lookup.
# Args:    none
# Returns: 0 always
# Globals: none
test_doctor_extras() {
  local engine_path="$TEST_SANDBOX/share/hyprland-zoom.lua" no_schema="$TEST_SANDBOX/noschema"
  reset_sandbox
  mkdir -p "$TEST_SANDBOX/home/.config/hypr"
  printf 'dofile("%s") -- zoom\n' "$engine_path" > "$TEST_SANDBOX/home/.config/hypr/hyprland.lua"
  set_fake_mode engine
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[ok  ] engine include present" "doctor: an annotated include line is recognised"
  assert_contains "$ZC_OUT" "[ok  ] engine reports no configuration warnings" "doctor: engine warnings: none"
  printf 'ZOOM_STEP=banana: ignored\nFOO unknown\n' > "$FAKE_DIR/warnings"
  run_zoomctl doctor
  assert_contains "$ZC_OUT" "[warn] engine: ZOOM_STEP=banana: ignored" "doctor: HyprZoom.warnings() line shown"
  assert_contains "$ZC_OUT" "[warn] engine: FOO unknown" "doctor: every warning line shown"
  assert_contains "$(fake_calls)" "repl return HyprZoom.warnings()" "doctor: asks the engine"
  # An installation without its schema must say so, not fail silently.
  mkdir -p "$no_schema"
  cp -r "$TEST_ROOT/src" "$no_schema/src"
  ZC_OUT="$("${TEST_ENV[@]}" "$no_schema/src/zoomctl" doctor 2>&1 </dev/null)"
  assert_contains "$ZC_OUT" "settings.schema not found" "doctor: a missing schema is reported"
  run_zoomctl doctor
  assert_not_contains "$ZC_OUT" "settings app found" "doctor: the settings override is authoritative (no stray checkout app)"
}

test_zoom_forwarding
test_injection_rejected
test_engine_failure_paths
test_preview
test_tracking_command
test_status
test_help_and_exit_codes
test_ui_launcher
test_ui_locale
test_symlinked_launcher
test_uninstall
test_doctor
test_doctor_extras
test_finish
