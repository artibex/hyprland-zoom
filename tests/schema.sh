#!/usr/bin/env bash
# schema.sh — suite: schema parsing, aliases, every validator, committed generated files.
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/testlib.sh"
test_init schema
load_zoomctl_libs

# check_valid — assert that a typed value validates to the expected canonical text.
# Args:    $1 type; $2 constraint; $3 input; $4 expected canonical value
# Returns: 0 always
# Globals: none
check_valid() {
  local canonical shown
  canonical="$(zoomctl_validate_by_type "$1" "$2" "$3")"
  # %q keeps control characters out of the label.
  printf -v shown '%q' "$3"
  assert_eq "$4" "$canonical" "valid $1 [$shown] -> [$4]"
}

# check_invalid — assert that a typed value is rejected.
# Args:    $1 type; $2 constraint; $3 input
# Returns: 0 always
# Globals: none
check_invalid() {
  local shown
  printf -v shown '%q' "$3"
  if zoomctl_validate_by_type "$1" "$2" "$3" >/dev/null; then
    fail "invalid $1 [$shown] must be rejected"
  else
    pass "invalid $1 [$shown] rejected"
  fi
}

# test_schema_parse — the schema tables match the schema file line by line.
# Args:    none
# Returns: 0 always
# Globals: none
test_schema_parse() {
  local expected_count key
  zoomctl_schema_load
  expected_count="$(grep -cvE '^[[:space:]]*(#|$)' "$SCHEMA_FILE")"
  assert_eq "$expected_count" "${#ZOOMCTL_SCHEMA_KEYS[@]}" "schema: key count equals schema lines"
  assert_eq "ZOOM_STEP" "${ZOOMCTL_SCHEMA_KEYS[0]}" "schema: first key keeps file order"
  assert_eq "SCROLL_EVENT_DELAY_MS" "${ZOOMCTL_SCHEMA_KEYS[-1]}" "schema: last key keeps file order"
  assert_eq "float" "${ZOOMCTL_SCHEMA_TYPE[ZOOM_STEP]}" "schema: type parsed"
  assert_eq "0.01..2.00" "${ZOOMCTL_SCHEMA_CONSTRAINT[ZOOM_STEP]}" "schema: constraint parsed"
  assert_eq "SUPER + ALT" "${ZOOMCTL_SCHEMA_DEFAULT[BIND_MODIFIERS]}" "schema: default with blanks"
  assert_eq "" "${ZOOMCTL_SCHEMA_CONSTRAINT[BIND_SCROLL]}" "schema: empty constraint kept"
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    [ -n "${ZOOMCTL_SCHEMA_HELP[$key]}" ] || fail "schema: $key has help"
  done
  pass "schema: every key has help"
}

# test_schema_defaults_valid — every default is valid and already canonical.
# Args:    none
# Returns: 0 always
# Globals: none
test_schema_defaults_valid() {
  local key canonical bad=0
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    canonical="$(zoomctl_schema_validate "$key" "${ZOOMCTL_SCHEMA_DEFAULT[$key]}")" || bad=1
    [ "$canonical" = "${ZOOMCTL_SCHEMA_DEFAULT[$key]}" ] || { bad=1; fail "default of $key canonical"; }
  done
  assert_eq 0 "$bad" "schema: every default validates and is canonical"
  assert_true "schema: default bounds hold" zoomctl_bounds_ok "${ZOOMCTL_SCHEMA_DEFAULT[ZOOM_MIN]}" \
    "${ZOOMCTL_SCHEMA_DEFAULT[ZOOM_RESET]}" "${ZOOMCTL_SCHEMA_DEFAULT[ZOOM_MAX]}"
}

# test_aliases — CLI aliases from C1 plus the 0.1 spellings.
# Args:    none
# Returns: 0 always
# Globals: none
test_aliases() {
  local pair
  for pair in step:ZOOM_STEP zoom-step:ZOOM_STEP ZOOM_STEP:ZOOM_STEP Step-Mode:ZOOM_STEP_MODE \
    tracking:ZOOM_TRACKING edge-margin:ZOOM_EDGE_MARGIN filter:FILTER filter-contrast:FILTER_CONTRAST \
    bind-key-in:BIND_KEY_IN bind_key_in:BIND_KEY_IN scroll-event-delay-ms:SCROLL_EVENT_DELAY_MS \
    min:ZOOM_MIN minimum:ZOOM_MIN max:ZOOM_MAX maximum:ZOOM_MAX reset:ZOOM_RESET \
    center-cursor:ZOOM_TRACKING; do
    assert_eq "${pair#*:}" "$(zoomctl_schema_resolve_key "${pair%%:*}")" "alias ${pair%%:*}"
  done
  assert_false "unknown alias rejected" zoomctl_schema_resolve_key 'nope'
  assert_false "empty alias rejected" zoomctl_schema_resolve_key ''

}

# test_validators — table of valid and invalid inputs for every type.
# Args:    none
# Returns: 0 always
# Globals: none
test_validators() {
  local input
  check_valid float 0.01..2.00 1.5 1.50
  check_valid float 0.01..2.00 0.005 0.01
  check_valid float 0.01..2.00 2 2.00
  check_valid float -0.50..0.50 -0.5 -0.50
  check_valid float -0.50..0.50 -0.05 -0.05
  check_valid float 1.00..10.00 10 10.00
  for input in 0.004 2.01 abc '' - 1. +1 1e3 '1,5' '1 2' '0x10' 1234567; do
    check_invalid float 0.01..2.00 "$input"
  done
  check_invalid float 1.00..10.00 10.01
  check_invalid float -0.50..0.50 -0.51
  check_valid int 0..300 007 7
  check_valid int 0..300 300 300
  for input in -1 301 1.5 abc '' 9999999999; do check_invalid int 0..300 "$input"; done
  for input in on 1 true yes ON Yes; do check_valid bool '' "$input" on; done
  for input in off 0 false no OFF No; do check_valid bool '' "$input" off; done
  for input in 2 maybe '' onn; do check_invalid bool '' "$input"; done
  check_valid enum multiply,add ADD add
  check_valid enum multiply,add multiply multiply
  for input in subtract '' 'add;x' multiplyadd; do check_invalid enum multiply,add "$input"; done
}

# test_key_and_mods — key names and modifier lists, including hostile input.
# Args:    none
# Returns: 0 always
# Globals: none
test_key_and_mods() {
  local input
  check_valid key '' i I
  check_valid key '' mouse:274 mouse:274
  check_valid key '' F5 F5
  check_valid key '' '' ''
  # shellcheck disable=SC2016  # the dollar sign is deliberately literal hostile input
  for input in 'a b' 'x"y' '$(x)' 'a;b' 'a\b' "a'b" 'a]b' 'abcdefghijklmnopqrstuvwxyz0123456789' $'a\nb'; do
    check_invalid key '' "$input"
  done
  check_valid mods '' 'SUPER + ALT' 'SUPER + ALT'
  check_valid mods '' 'super+alt' 'SUPER + ALT'
  check_valid mods '' 'alt,super' 'SUPER + ALT'
  check_valid mods '' 'control shift' 'SHIFT + CTRL'
  check_valid mods '' 'SUPER + SUPER' 'SUPER'
  for input in '' '+' 'SUPER + FOO' 'SUPER; os.exit()' 'SUPER"' 'META'; do
    check_invalid mods '' "$input"
  done
}

# test_bounds_rule — the cross-field rule ZOOM_MIN <= ZOOM_RESET <= ZOOM_MAX.
# Args:    none
# Returns: 0 always
# Globals: none
test_bounds_rule() {
  assert_true "bounds: defaults hold" zoomctl_bounds_ok 1.00 1.00 10.00
  assert_true "bounds: reset == max holds" zoomctl_bounds_ok 1.00 5.00 5.00
  assert_false "bounds: min > reset rejected" zoomctl_bounds_ok 2.00 1.00 10.00
  assert_false "bounds: reset > max rejected" zoomctl_bounds_ok 1.00 6.00 5.00
  assert_false "bounds: garbage rejected" zoomctl_bounds_ok 1.00 abc 5.00
}

# test_generated_files — committed generated files equal the CLI's output (drift guard).
# Args:    none
# Returns: 0 always
# Globals: none
test_generated_files() {
  run_zoomctl config --template
  assert_status 0 "config --template"
  assert_eq "$(<"$TEST_ROOT/config/defaults.conf")" "$ZC_OUT" "config/defaults.conf matches the schema"
  run_zoomctl config --legacy-bindings
  assert_status 0 "config --legacy-bindings"
  assert_eq "$(<"$TEST_ROOT/config/hyprland-bindings.conf")" "$ZC_OUT" \
    "config/hyprland-bindings.conf matches the schema"
}

# test_template_shape — the template comments out every key with its default.
# Args:    none
# Returns: 0 always
# Globals: none
test_template_shape() {
  local key missing=0
  run_zoomctl config --template
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    [[ "$ZC_OUT"$'\n' == *$'\n'"#$key=${ZOOMCTL_SCHEMA_DEFAULT[$key]}"$'\n'* ]] || missing=1
  done
  assert_eq 0 "$missing" "template: every key commented out with its default"
  assert_not_contains "$(grep -v '^#' <<< "$ZC_OUT")" "=" "template: no active assignment"
  assert_eq 0 "$(awk 'length($0) > 80' <<< "$ZC_OUT" | wc -l)" "template: lines wrapped to 80 columns"
}

test_schema_parse
test_schema_defaults_valid
test_aliases
test_validators
test_key_and_mods
test_bounds_rule
test_generated_files
test_template_shape
test_finish
