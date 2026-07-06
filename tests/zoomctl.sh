#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$script_directory/src/lib/math.sh"
source "$script_directory/src/lib/config.sh"

fail() {
  printf 'test failed: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [ "$expected" = "$actual" ] || fail "$message (expected $expected, got $actual)"
}

zoomctl_config_defaults

assert_equal '1.25' "$(zoomctl_add_float '1.00' '0.25')" 'float addition'
assert_equal '1.00' "$(zoomctl_clamp_float '0.10' '1.00' '10.00')" 'lower clamp'
assert_equal '10.00' "$(zoomctl_clamp_float '12.50' '1.00' '10.00')" 'upper clamp'

temp_config="$(mktemp)"
trap 'rm -f "$temp_config"' EXIT

cat <<'EOF' > "$temp_config"
ZOOM_STEP=0.30
ZOOM_MIN=1.20
ZOOM_MAX=8.50
ZOOM_RESET=1.40
ZOOM_CENTER_CURSOR=1
EOF

zoomctl_config_load_file "$temp_config"
zoomctl_config_validate

assert_equal '0.30' "$ZOOMCTL_STEP" 'config step load'
assert_equal '1.20' "$ZOOMCTL_MIN" 'config min load'
assert_equal '8.50' "$ZOOMCTL_MAX" 'config max load'
assert_equal '1.40' "$ZOOMCTL_RESET" 'config reset load'
assert_equal '1' "$ZOOMCTL_CENTER_CURSOR" 'config toggle load'

assert_equal 'ZOOM_STEP' "$(zoomctl_config_canonical_key 'step')" 'canonical key alias: step'
assert_equal 'ZOOM_MAX' "$(zoomctl_config_canonical_key 'maximum')" 'canonical key alias: maximum'
assert_equal 'ZOOM_CENTER_CURSOR' "$(zoomctl_config_canonical_key 'center-cursor')" 'canonical key alias: center-cursor'
if zoomctl_config_canonical_key 'nonsense' >/dev/null 2>&1; then
  fail 'canonical key alias should reject unknown keys'
fi

assert_equal '1' "$(zoomctl_normalize_bool 'on')" 'bool normalize: on'
assert_equal '1' "$(zoomctl_normalize_bool 'YES')" 'bool normalize: YES'
assert_equal '0' "$(zoomctl_normalize_bool 'off')" 'bool normalize: off'
assert_equal '0' "$(zoomctl_normalize_bool '0')" 'bool normalize: 0'

if zoomctl_config_validate_value 'ZOOM_STEP' 'not-a-number'; then
  fail 'validate_value should reject a non-numeric step'
fi
if ! zoomctl_config_validate_value 'ZOOM_STEP' '0.25'; then
  fail 'validate_value should accept a numeric step'
fi
if zoomctl_config_validate_value 'ZOOM_CENTER_CURSOR' '2'; then
  fail 'validate_value should reject an out-of-range boolean'
fi

assert_equal '0.30' "$(zoomctl_config_get 'ZOOM_STEP')" 'config get: step'
assert_equal '1' "$(zoomctl_config_get 'ZOOM_CENTER_CURSOR')" 'config get: center cursor'

printf 'zoomctl tests passed\n'