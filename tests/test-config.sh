#!/usr/bin/env bash
# test-config.sh — suite: layered config (C2), 0.1 compat, set/get/unset/reset-config, porcelain.
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/test-lib.sh"
test_init config
load_zoomctl_libs

# write_conf — write a config file from a printf-style body.
# Args:    $1 path; $2 content (may contain \n escapes)
# Returns: 0 always
# Globals: none
write_conf() {
  mkdir -p "$(dirname -- "$1")"
  # %b expands the \n and \r escapes of the body without using it as a format string.
  printf '%b' "$2" > "$1"
}

# load_config — load the effective config in-process, capturing warnings in LOAD_WARNINGS.
# Args:    none
# Returns: 0 always
# Globals: writes LOAD_WARNINGS and the ZOOMCTL_VALUE/ZOOMCTL_SOURCE tables
load_config() {
  zoomctl_config_load 2>"$TEST_SANDBOX/load.err"
  LOAD_WARNINGS="$(<"$TEST_SANDBOX/load.err")"
}

# test_layering — defaults <- system <- user with origin tracking.
# Args:    none
# Returns: 0 always
# Globals: none
test_layering() {
  reset_sandbox
  load_config
  assert_eq "0.10" "${ZOOMCTL_VALUE[ZOOM_STEP]}" "layering: default applies"
  assert_eq "default" "${ZOOMCTL_SOURCE[ZOOM_STEP]}" "layering: default origin"
  write_conf "$ZC_SYSTEM_CONFIG" 'ZOOM_STEP=0.2\nZOOM_MAX=8\n'
  write_conf "$ZC_USER_CONFIG" 'ZOOM_STEP = 0.30\n# comment\n\n   FILTER=invert  \n'
  load_config
  assert_eq "0.30" "${ZOOMCTL_VALUE[ZOOM_STEP]}" "layering: user beats system"
  assert_eq "user" "${ZOOMCTL_SOURCE[ZOOM_STEP]}" "layering: user origin"
  assert_eq "8.00" "${ZOOMCTL_VALUE[ZOOM_MAX]}" "layering: system beats default, canonical form"
  assert_eq "system" "${ZOOMCTL_SOURCE[ZOOM_MAX]}" "layering: system origin"
  assert_eq "invert" "${ZOOMCTL_VALUE[FILTER]}" "layering: blanks and comments tolerated"
  assert_eq "" "$LOAD_WARNINGS" "layering: valid files produce no warnings"
}

# test_file_syntax — quotes, CRLF and malformed lines.
# Args:    none
# Returns: 0 always
# Globals: none
test_file_syntax() {
  reset_sandbox
  write_conf "$ZC_USER_CONFIG" 'FILTER="grayscale"\r\nZOOM_STEP=0.5\r\nthis is not a setting\n'
  load_config
  assert_eq "grayscale" "${ZOOMCTL_VALUE[FILTER]}" "syntax: quoted value and CRLF accepted"
  assert_eq "0.50" "${ZOOMCTL_VALUE[ZOOM_STEP]}" "syntax: CRLF does not corrupt the number"
  assert_contains "$LOAD_WARNINGS" "ignoring line without '='" "syntax: malformed line warned"
}

# test_invalid_values — invalid and unknown entries never abort and fall back one layer.
# Args:    none
# Returns: 0 always
# Globals: none
test_invalid_values() {
  reset_sandbox
  write_conf "$ZC_SYSTEM_CONFIG" 'ZOOM_STEP=0.25\n'
  write_conf "$ZC_USER_CONFIG" 'ZOOM_STEP=banana\nZOOM_MAX=99\nFOO=1\nBIND_KEY_IN=a b\n[x]=1\n'
  load_config
  assert_eq "0.25" "${ZOOMCTL_VALUE[ZOOM_STEP]}" "invalid: falls back to the system layer"
  assert_eq "10.00" "${ZOOMCTL_VALUE[ZOOM_MAX]}" "invalid: out-of-range falls back to the default"
  assert_eq "I" "${ZOOMCTL_VALUE[BIND_KEY_IN]}" "invalid: bad key name falls back"
  assert_contains "$LOAD_WARNINGS" "invalid value 'banana' for ZOOM_STEP" "invalid: value warning names key"
  assert_contains "$LOAD_WARNINGS" "unknown setting FOO" "invalid: unknown key warned"
  assert_contains "$LOAD_WARNINGS" "malformed key" "invalid: hostile key name rejected"
}

# test_cross_field_layers — a layer breaking MIN <= RESET <= MAX loses its zoom bounds.
# Args:    none
# Returns: 0 always
# Globals: none
test_cross_field_layers() {
  reset_sandbox
  write_conf "$ZC_USER_CONFIG" 'ZOOM_MIN=3\nZOOM_RESET=2\nZOOM_STEP=0.4\n'
  load_config
  assert_eq "1.00" "${ZOOMCTL_VALUE[ZOOM_MIN]}" "cross-field: offending layer's MIN ignored"
  assert_eq "1.00" "${ZOOMCTL_VALUE[ZOOM_RESET]}" "cross-field: offending layer's RESET ignored"
  assert_eq "0.40" "${ZOOMCTL_VALUE[ZOOM_STEP]}" "cross-field: unrelated keys of the layer stay"
  assert_contains "$LOAD_WARNINGS" "ZOOM_MIN (3.00) <= ZOOM_RESET (2.00)" "cross-field: warning shows values"
}

# test_compat_01 — 0.1 files: ZOOM_CENTER_CURSOR and the implied additive step mode.
# Args:    none
# Returns: 0 always
# Globals: none
test_compat_01() {
  reset_sandbox
  write_conf "$ZC_USER_CONFIG" 'ZOOM_STEP=0.25\nZOOM_CENTER_CURSOR=1\n'
  load_config
  assert_eq "centered" "${ZOOMCTL_VALUE[ZOOM_TRACKING]}" "compat: CENTER_CURSOR=1 -> centered"
  assert_eq "add" "${ZOOMCTL_VALUE[ZOOM_STEP_MODE]}" "compat: 0.1 file implies step mode add"
  write_conf "$ZC_USER_CONFIG" 'ZOOM_CENTER_CURSOR=0\n'
  load_config
  assert_eq "edge" "${ZOOMCTL_VALUE[ZOOM_TRACKING]}" "compat: CENTER_CURSOR=0 -> edge"
  write_conf "$ZC_USER_CONFIG" 'ZOOM_CENTER_CURSOR=1\nZOOM_TRACKING=follow\nZOOM_STEP_MODE=multiply\n'
  load_config
  assert_eq "follow" "${ZOOMCTL_VALUE[ZOOM_TRACKING]}" "compat: explicit tracking wins"
  assert_eq "multiply" "${ZOOMCTL_VALUE[ZOOM_STEP_MODE]}" "compat: explicit step mode wins"
  write_conf "$ZC_USER_CONFIG" 'ZOOM_CENTER_CURSOR=maybe\n'
  load_config
  assert_contains "$LOAD_WARNINGS" "invalid ZOOM_CENTER_CURSOR" "compat: invalid old switch warned"
  write_conf "$ZC_SYSTEM_CONFIG" 'ZOOM_CENTER_CURSOR=0\nZOOM_STEP=0.30\n'
  rm -f "$ZC_USER_CONFIG"
  load_config
  assert_eq "add" "${ZOOMCTL_VALUE[ZOOM_STEP_MODE]}" "compat: system layer in 0.1 format implies add too"
}

# test_set_get_unset — CLI round trip with canonical, schema-ordered, comment-free output.
# Args:    none
# Returns: 0 always
# Globals: none
test_set_get_unset() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set tracking follow
  assert_status 0 "set: tracking"
  assert_eq "ZOOM_TRACKING=follow" "$ZC_OUT" "set: prints the stored pair"
  run_zoomctl set step 1.5
  run_zoomctl set bind-modifiers 'ctrl+alt'
  assert_file_content "$ZC_USER_CONFIG" $'ZOOM_STEP=1.50\nZOOM_TRACKING=follow\nBIND_MODIFIERS=CTRL + ALT' \
    "set: canonical values in schema order, no comments"
  run_zoomctl get step
  assert_eq "1.50" "$ZC_OUT" "get: effective value"
  run_zoomctl set step 0.2
  assert_file_content "$ZC_USER_CONFIG" $'ZOOM_STEP=0.20\nZOOM_TRACKING=follow\nBIND_MODIFIERS=CTRL + ALT' \
    "set: updating replaces instead of duplicating"
  run_zoomctl unset step
  assert_file_content "$ZC_USER_CONFIG" $'ZOOM_TRACKING=follow\nBIND_MODIFIERS=CTRL + ALT' "unset: drops one key"
  run_zoomctl unset step
  assert_status 0 "unset: absent override is not an error"
  run_zoomctl reset-config
  assert_no_file "$ZC_USER_CONFIG" "reset-config: user file removed"
  run_zoomctl unset tracking
  assert_no_file "$ZC_USER_CONFIG" "unset: no file appears from nothing"
}

# test_set_rewrites_01_file — `set` upgrades a 0.1 user file to canonical 0.2 keys.
# Args:    none
# Returns: 0 always
# Globals: none
test_set_rewrites_01_file() {
  reset_sandbox
  set_fake_mode unreachable
  write_conf "$ZC_USER_CONFIG" '# my old settings\nZOOM_STEP=0.25\nZOOM_CENTER_CURSOR=1\n'
  run_zoomctl set max 6
  assert_file_content "$ZC_USER_CONFIG" \
    $'ZOOM_STEP=0.25\nZOOM_STEP_MODE=add\nZOOM_MAX=6.00\nZOOM_TRACKING=centered' \
    "set: 0.1 file rewritten, implied keys explicit, ZOOM_CENTER_CURSOR dropped"
  run_zoomctl set center-cursor off
  assert_eq "ZOOM_TRACKING=edge" "$ZC_OUT" "set: 0.1 alias center-cursor off -> edge"
  run_zoomctl set center-cursor maybe
  assert_status 1 "set: invalid 0.1 switch"
}

# test_set_errors — usage errors, unknown keys, invalid values, cross-field rejection.
# Args:    none
# Returns: 0 always
# Globals: none
test_set_errors() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set
  assert_status 2 "set: no arguments is a usage error"
  run_zoomctl set step
  assert_status 2 "set: missing value is a usage error"
  run_zoomctl set nope 1
  assert_status 1 "set: unknown key"
  assert_contains "$ZC_ERR" "unknown setting 'nope'" "set: unknown key message"
  run_zoomctl set step abc
  assert_status 1 "set: invalid value"
  assert_contains "$ZC_ERR" "expected a number from 0.01 to 2.00" "set: message names the accepted range"
  run_zoomctl get nope
  assert_status 1 "get: unknown key"
  run_zoomctl get
  assert_status 2 "get: no key is a usage error"
  run_zoomctl set min 2
  assert_status 1 "set: MIN above RESET rejected"
  assert_contains "$ZC_ERR" "ZOOM_MIN (2.00) <= ZOOM_RESET (1.00)" "set: cross-field message"
  assert_no_file "$ZC_USER_CONFIG" "set: rejected value writes nothing"
}

# test_cross_field_sequence — raising bounds in the right order works, breaking them is refused.
# Args:    none
# Returns: 0 always
# Globals: none
test_cross_field_sequence() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set reset 3
  assert_status 0 "cross-field: reset 3 within 1..10"
  run_zoomctl set min 2
  assert_status 0 "cross-field: min 2 now fine"
  run_zoomctl set max 2.5
  assert_status 1 "cross-field: max below reset rejected"
  run_zoomctl unset reset
  assert_status 1 "cross-field: unset reset would put it below min"
  assert_file_content "$ZC_USER_CONFIG" $'ZOOM_MIN=2.00\nZOOM_RESET=3.00' "cross-field: failed unset keeps the file"
}

# test_empty_key_value — key-type settings may be set to the empty string (bind disabled).
# Args:    none
# Returns: 0 always
# Globals: none
test_empty_key_value() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set bind-key-in ''
  assert_status 0 "set: empty key disables a bind"
  assert_file_content "$ZC_USER_CONFIG" 'BIND_KEY_IN=' "set: empty value stored"
  run_zoomctl get bind-key-in
  assert_eq "" "$ZC_OUT" "get: empty value read back"
  run_zoomctl set step ''
  assert_status 1 "set: empty value invalid for a float"
}

# config_dir_files — list the config directory, hiding the (intended) lock file.
# Args:    none
# Returns: 0 always; stdout: one entry per line
# Globals: reads ZC_USER_CONFIG
config_dir_files() {
  find "$(dirname -- "$ZC_USER_CONFIG")" -mindepth 1 -maxdepth 1 ! -name '.zoom.conf.lock' \
    -printf '%f\n' | sort
}

# test_atomic_write — no draft files remain; modes are kept; failures leave the file intact.
# Args:    none
# Returns: 0 always
# Globals: none
test_atomic_write() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set step 0.3
  assert_eq "zoom.conf" "$(config_dir_files)" "atomic: only zoom.conf (and the lock) in the directory"
  assert_eq "644" "$(stat -c '%a' "$ZC_USER_CONFIG")" "atomic: new file is 0644"
  chmod 600 "$ZC_USER_CONFIG"
  run_zoomctl set step 0.4
  assert_eq "600" "$(stat -c '%a' "$ZC_USER_CONFIG")" "atomic: existing mode kept"
  chmod 555 "$(dirname -- "$ZC_USER_CONFIG")"
  run_zoomctl set step 0.9
  chmod 755 "$(dirname -- "$ZC_USER_CONFIG")"
  assert_status 1 "atomic: unwritable directory fails"
  assert_file_content "$ZC_USER_CONFIG" 'ZOOM_STEP=0.40' "atomic: failed write leaves the old file"
  assert_eq "zoom.conf" "$(config_dir_files)" "atomic: no draft left after failure"
}

# test_atomic_rename — the file is replaced by a rename; a failing rename leaves it untouched.
# Args:    none
# Returns: 0 always
# Globals: none
test_atomic_rename() {
  local shim_dir="$TEST_SANDBOX/shim"
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set step 0.3
  # A shim mv that always fails: only an implementation that renames survives this unharmed.
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexit 1\n' > "$shim_dir/mv"
  chmod +x "$shim_dir/mv"
  ZC_EXTRA_ENV=("PATH=$shim_dir:$TEST_SANDBOX/bin:/usr/bin:/bin")
  run_zoomctl set step 0.9
  ZC_EXTRA_ENV=()
  assert_status 1 "atomic rename: a failing mv fails the command"
  assert_file_content "$ZC_USER_CONFIG" 'ZOOM_STEP=0.30' "atomic rename: old file intact (no in-place write)"
  assert_eq "zoom.conf" "$(config_dir_files)" "atomic rename: the draft is cleaned up"
  assert_contains "$ZC_ERR" "cannot replace" "atomic rename: the failure is reported"
}

# test_set_multi — several pairs: all validated first, one write, one reload.
# Args:    none
# Returns: 0 always
# Globals: none
test_set_multi() {
  reset_sandbox
  set_fake_mode engine
  run_zoomctl set step 0.2 tracking edge bind-key-in '' min 2 reset 2
  assert_status 0 "set multi: exit status"
  assert_file_content "$ZC_USER_CONFIG" \
    $'ZOOM_STEP=0.20\nZOOM_MIN=2.00\nZOOM_RESET=2.00\nZOOM_TRACKING=edge\nBIND_KEY_IN=' \
    "set multi: every pair stored in one canonical file (MIN and RESET together)"
  assert_eq 5 "$(grep -c . <<< "$ZC_OUT")" "set multi: one KEY=VALUE line per pair"
  assert_eq 1 "$(grep -c 'HyprZoom.reload' <<< "$(fake_calls)" || true)" "set multi: one reload"
  rm -f "$ZC_USER_CONFIG"
  run_zoomctl set step 0.2 tracking sideways
  assert_status 1 "set multi: one bad pair fails the call"
  assert_no_file "$ZC_USER_CONFIG" "set multi: nothing written when any pair is invalid"
  run_zoomctl set step 0.2 tracking
  assert_status 2 "set multi: an odd argument count is a usage error"
  run_zoomctl set step 0.2 step 0.4
  assert_file_content "$ZC_USER_CONFIG" 'ZOOM_STEP=0.40' "set multi: a repeated key keeps the last value"
}

# test_ui_call_shapes — the exact call shapes of the settings window work.
# Args:    none
# Returns: 0 always
# Globals: none
test_ui_call_shapes() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set ZOOM_STEP 0.25
  assert_eq "ZOOM_STEP=0.25" "$ZC_OUT" "ui shape: canonical key and value"
  run_zoomctl set BIND_MODIFIERS "SUPER + CTRL"
  assert_eq "BIND_MODIFIERS=SUPER + CTRL" "$ZC_OUT" "ui shape: modifiers as one argument"
  run_zoomctl set BIND_MODIFIERS "SHIFT + ALT + CTRL + SUPER"
  assert_eq "BIND_MODIFIERS=SUPER + CTRL + ALT + SHIFT" "$ZC_OUT" \
    "ui shape: canonical modifier order is the engine's (SUPER CTRL ALT SHIFT)"
  run_zoomctl set BIND_KEY_IN ""
  assert_status 0 "ui shape: an empty argument disables a key bind"
  run_zoomctl config --porcelain
  assert_contains "$ZC_OUT" $'BIND_KEY_IN=\n' "ui shape: the disabled bind reads back empty"
}

# test_parallel_set — parallel sets of different keys all survive; the lock is what saves them.
# Args:    none
# Returns: 0 always
# Globals: none
test_parallel_set() {
  local mutant attempt lost=0
  reset_sandbox
  set_fake_mode unreachable
  parallel_set_run "$ZOOMCTL"
  assert_eq 8 "$(grep -c . "$ZC_USER_CONFIG")" "parallel set: 8 parallel sets keep all 8 keys"
  # Mutation: the same code without the lock must lose keys, or the test above proves nothing.
  mutant="$(make_mutant common.sh 's/^    flock --timeout .*$/    true || {/')" ||
    fail "parallel set: mutation applied"
  for attempt in 1 2 3 4 5; do
    reset_sandbox
    set_fake_mode unreachable
    parallel_set_run "$mutant"
    [ "$(grep -c . "$ZC_USER_CONFIG")" -lt 8 ] && { lost=1; break; }
  done
  assert_eq 1 "$lost" "parallel set: without the lock updates are lost (the test bites)"
}

# parallel_set_run — start 8 `zoomctl set` processes at once, each for a different key.
# Args:    $1 path of the zoomctl script to run
# Returns: 0 always (waits for all of them)
# Globals: reads TEST_ENV
parallel_set_run() {
  local pair
  # Eight different keys (none touching MIN, so the order of arrival cannot matter).
  for pair in step=0.2 step-mode=add max=8 reset=2 filter-contrast=2 filter-brightness=0.1 \
    animation-speed=2 edge-margin=0.3; do
    "${TEST_ENV[@]}" "$1" set "${pair%%=*}" "${pair#*=}" >/dev/null 2>&1 </dev/null &
  done
  wait
}

# test_symlinked_config — a dotfile symlink survives; the real file is edited with its mode.
# Args:    none
# Returns: 0 always
# Globals: none
test_symlinked_config() {
  local dots="$TEST_SANDBOX/dots"
  reset_sandbox
  set_fake_mode unreachable
  mkdir -p "$dots" "$(dirname -- "$ZC_USER_CONFIG")"
  printf 'ZOOM_STEP=0.30\n' > "$dots/zoom.conf"
  chmod 600 "$dots/zoom.conf"
  ln -s "$dots/zoom.conf" "$ZC_USER_CONFIG"
  run_zoomctl set max 5
  assert_status 0 "symlink: set works through the link"
  assert_symlink "$ZC_USER_CONFIG" "$dots/zoom.conf" "symlink: the dotfile link is still a link"
  assert_file_content "$dots/zoom.conf" $'ZOOM_STEP=0.30\nZOOM_MAX=5.00' "symlink: the target was edited"
  assert_eq 600 "$(stat -c '%a' "$dots/zoom.conf")" "symlink: the target keeps its mode (not the link's 777)"
  assert_eq "zoom.conf" "$(ls -A "$dots")" "symlink: no draft in the dotfiles directory"
  run_zoomctl unset max
  assert_symlink "$ZC_USER_CONFIG" "$dots/zoom.conf" "symlink: unset keeps the link"
  chmod 666 "$dots/zoom.conf"
  run_zoomctl set step 0.4
  assert_eq 664 "$(stat -c '%a' "$dots/zoom.conf")" "symlink: a world-writable bit is never carried over"
}

# test_lossy_rewrite_backup — hand-edited content is saved once before the canonical rewrite.
# Args:    none
# Returns: 0 always
# Globals: none
test_lossy_rewrite_backup() {
  local backups
  reset_sandbox
  set_fake_mode unreachable
  write_conf "$ZC_USER_CONFIG" '# my notes\nZOOM_STEP=0.25\nFUTURE_KEY=1\n'
  run_zoomctl set max 6
  backups="$(find "$(dirname -- "$ZC_USER_CONFIG")" -name 'zoom.conf.bak-*' | sort)"
  assert_eq 1 "$(grep -c . <<< "$backups")" "backup: one zoom.conf.bak-<timestamp> before the first rewrite"
  assert_contains "$(<"$backups")" "# my notes" "backup: holds the original comments"
  assert_contains "$(<"$backups")" "FUTURE_KEY=1" "backup: holds the unknown key"
  assert_contains "$ZC_ERR" "backup of" "backup: announced"
  run_zoomctl set max 7
  assert_eq 1 "$(find "$(dirname -- "$ZC_USER_CONFIG")" -name 'zoom.conf.bak-*' | grep -c .)" \
    "backup: the now canonical file is not backed up again"
  reset_sandbox
  run_zoomctl set max 6
  assert_eq 0 "$(find "$(dirname -- "$ZC_USER_CONFIG")" -name 'zoom.conf.bak-*' | grep -c .)" \
    "backup: a fresh canonical file needs none"
  write_conf "$ZC_USER_CONFIG" '# keep me\nZOOM_STEP=0.25\n'
  run_zoomctl reset-config
  assert_eq 1 "$(find "$(dirname -- "$ZC_USER_CONFIG")" -name 'zoom.conf.bak-*' | grep -c .)" \
    "backup: reset-config saves a hand-edited file too"
}

# test_write_failures_reported — a failed reset or write is an error, never a success message.
# Args:    none
# Returns: 0 always
# Globals: none
test_write_failures_reported() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set step 0.3
  chmod 555 "$(dirname -- "$ZC_USER_CONFIG")"
  run_zoomctl reset-config
  chmod 755 "$(dirname -- "$ZC_USER_CONFIG")"
  assert_status 1 "reset-config: unremovable file exits 1"
  assert_not_contains "$ZC_OUT" "removed" "reset-config: no success message after a failure"
  assert_file_exists "$ZC_USER_CONFIG" "reset-config: the file is still there"
  chmod 555 "$(dirname -- "$ZC_USER_CONFIG")"
  run_zoomctl unset step
  chmod 755 "$(dirname -- "$ZC_USER_CONFIG")"
  assert_status 1 "unset: unwritable directory exits 1"
}

# test_locale_independence — validators are byte-wise: non-ASCII input is rejected cleanly.
# Args:    none
# Returns: 0 always
# Globals: none
test_locale_independence() {
  if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then
    pass "locale: en_US.UTF-8 not installed here (check skipped)"
    return 0
  fi
  reset_sandbox
  set_fake_mode unreachable
  ZC_EXTRA_ENV=(LC_ALL=en_US.UTF-8)
  run_zoomctl set bind-key-in 'É'
  assert_status 1 "locale: a non-ASCII key name is rejected"
  run_zoomctl set step '٣'
  assert_status 1 "locale: an Arabic-Indic digit is not a number"
  assert_not_contains "$ZC_ERR" "invalid integer constant" "locale: no bash arithmetic error leaks out"
  run_zoomctl in '٣'
  assert_status 2 "locale: a non-ASCII notch count is a usage error"
  assert_not_contains "$ZC_ERR" "invalid integer constant" "locale: notch count error is ours"
  run_zoomctl set bind-modifiers 'Ｓuper'
  assert_status 1 "locale: a fullwidth letter is not a modifier"
  ZC_EXTRA_ENV=()
  assert_no_file "$ZC_USER_CONFIG" "locale: nothing non-ASCII reached the config file"
}

# test_porcelain — config --porcelain lists exactly the schema keys, in order, as KEY=VALUE.
# Args:    none
# Returns: 0 always
# Globals: none
test_porcelain() {
  local expected_keys actual_keys
  reset_sandbox
  write_conf "$ZC_USER_CONFIG" 'ZOOM_STEP=0.5\nFILTER_CONTRAST=1.4\n'
  run_zoomctl config --porcelain
  assert_status 0 "porcelain: exit status"
  expected_keys="$(grep -vE '^[[:space:]]*(#|$)' "$SCHEMA_FILE" | cut -d'|' -f1)"
  actual_keys="$(cut -d= -f1 <<< "$ZC_OUT")"
  assert_eq "$expected_keys" "$actual_keys" "porcelain: exact key set and order of the schema"
  assert_contains "$ZC_OUT" $'ZOOM_STEP=0.50\n' "porcelain: user value, canonical"
  assert_contains "$ZC_OUT" $'FILTER_CONTRAST=1.40\n' "porcelain: second user value"
  assert_contains "$ZC_OUT" $'BIND_MODIFIERS=SUPER + ALT\n' "porcelain: value with blanks intact"
  run_zoomctl config
  assert_contains "$ZC_OUT" "ZOOM_STEP" "config: human view lists keys"
  assert_contains "$ZC_OUT" "(user)" "config: human view shows the origin layer"
  run_zoomctl config --bogus
  assert_status 2 "config: unknown option is a usage error"
}

# test_reload_after_set — the engine is asked to reload; other cases are reported, not fatal.
# Args:    none
# Returns: 0 always
# Globals: none
test_reload_after_set() {
  reset_sandbox
  set_fake_mode engine
  run_zoomctl set step 0.3
  assert_contains "$(fake_calls)" "eval HyprZoom.reload()" "reload: engine reachable gets HyprZoom.reload()"
  assert_eq "" "$ZC_ERR" "reload: no complaint when the engine applied it"
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set step 0.3
  assert_status 0 "reload: unreachable Hyprland does not fail the save"
  assert_contains "$ZC_ERR" "not reachable" "reload: says that nothing was applied live"
  reset_sandbox
  set_fake_mode lua-no-engine
  run_zoomctl set step 0.3
  assert_status 0 "reload: engine missing does not fail the save"
  assert_contains "$ZC_ERR" "engine is not loaded" "reload: says the engine is not loaded"
  reset_sandbox
  set_fake_mode engine
  printf "error: boom\n" > "$FAKE_DIR/eval_error"
  run_zoomctl set step 0.3
  assert_status 0 "reload: engine error does not fail the save"
  assert_contains "$ZC_ERR" "rejected the reload" "reload: engine error reported"
}

test_layering
test_file_syntax
test_invalid_values
test_cross_field_layers
test_compat_01
test_set_get_unset
test_set_rewrites_01_file
test_set_errors
test_cross_field_sequence
test_empty_key_value
test_atomic_write
test_atomic_rename
test_set_multi
test_ui_call_shapes
test_parallel_set
test_symlinked_config
test_lossy_rewrite_backup
test_write_failures_reported
test_locale_independence
test_porcelain
test_reload_after_set
test_finish
