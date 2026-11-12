#!/usr/bin/env bash
# config.sh — suite: layered config (C2), 0.1 compat, set/get/unset/reset-config, porcelain.
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/testlib.sh"
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

# test_atomic_write — no draft files remain; modes are kept; failures leave the file intact.
# Args:    none
# Returns: 0 always
# Globals: none
test_atomic_write() {
  reset_sandbox
  set_fake_mode unreachable
  run_zoomctl set step 0.3
  assert_eq "zoom.conf" "$(ls -A "$(dirname -- "$ZC_USER_CONFIG")")" "atomic: only zoom.conf in the directory"
  assert_eq "644" "$(stat -c '%a' "$ZC_USER_CONFIG")" "atomic: new file is 0644"
  chmod 600 "$ZC_USER_CONFIG"
  run_zoomctl set step 0.4
  assert_eq "600" "$(stat -c '%a' "$ZC_USER_CONFIG")" "atomic: existing mode kept"
  chmod 555 "$(dirname -- "$ZC_USER_CONFIG")"
  run_zoomctl set step 0.9
  chmod 755 "$(dirname -- "$ZC_USER_CONFIG")"
  assert_status 1 "atomic: unwritable directory fails"
  assert_file_content "$ZC_USER_CONFIG" 'ZOOM_STEP=0.40' "atomic: failed write leaves the old file"
  assert_eq "zoom.conf" "$(ls -A "$(dirname -- "$ZC_USER_CONFIG")")" "atomic: no draft left after failure"
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
test_porcelain
test_reload_after_set
test_finish
