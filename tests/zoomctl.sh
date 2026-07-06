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

printf 'zoomctl tests passed\n'