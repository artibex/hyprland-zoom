#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$script_directory/src/lib/setup.sh"

fail() {
  printf 'test failed: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  grep -Fq "$2" "$1" || fail "$3 (missing '$2' in $1)"
}

assert_missing() {
  if grep -Fq "$2" "$1" 2>/dev/null; then
    fail "$3 (unexpected '$2' in $1)"
  fi
}

# --- Lua-mode: active config is hyprland.lua, legacy conf also present ---
lua_home="$(mktemp -d)"
trap 'rm -rf "$lua_home"' EXIT
mkdir -p "$lua_home/.config/hypr"
printf -- '-- test lua config\n' > "$lua_home/.config/hypr/hyprland.lua"
printf '# test legacy config\n' > "$lua_home/.config/hypr/hyprland.conf"

export ZOOMCTL_TARGET_HOME="$lua_home"
zoomctl_install_hyprland_include >/dev/null
assert_contains "$lua_home/.config/hypr/hyprland.lua" 'dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua")' 'lua include added'
assert_contains "$lua_home/.config/hypr/hyprland.conf" 'source = /usr/share/hyprland-zoom/hyprland-bindings.conf' 'legacy include added'

zoomctl_install_hyprland_include >/dev/null
[ "$(grep -c 'hyprland-bindings.lua' "$lua_home/.config/hypr/hyprland.lua")" -eq 1 ] || fail 'lua include duplicated on re-run'
[ "$(grep -c 'hyprland-bindings.conf' "$lua_home/.config/hypr/hyprland.conf")" -eq 1 ] || fail 'legacy include duplicated on re-run'

zoomctl_remove_hyprland_include
assert_missing "$lua_home/.config/hypr/hyprland.lua" 'hyprland-bindings.lua' 'lua include removed'
assert_missing "$lua_home/.config/hypr/hyprland.conf" 'hyprland-bindings.conf' 'legacy include removed'

# --- Legacy-mode: no hyprland.lua at all ---
legacy_home="$(mktemp -d)"
trap 'rm -rf "$legacy_home"' EXIT
mkdir -p "$legacy_home/.config/hypr"
printf '# legacy config\n' > "$legacy_home/.config/hypr/hyprland.conf"

export ZOOMCTL_TARGET_HOME="$legacy_home"
zoomctl_install_hyprland_include >/dev/null
assert_contains "$legacy_home/.config/hypr/hyprland.conf" 'source = /usr/share/hyprland-zoom/hyprland-bindings.conf' 'legacy-only include added'
[ ! -f "$legacy_home/.config/hypr/hyprland.lua" ] || fail 'lua config created in legacy mode'

zoomctl_remove_hyprland_include
assert_missing "$legacy_home/.config/hypr/hyprland.conf" 'hyprland-bindings.conf' 'legacy-only include removed'

# --- Fresh home: no config at all -> legacy conf is created ---
fresh_home="$(mktemp -d)"
trap 'rm -rf "$fresh_home"' EXIT

export ZOOMCTL_TARGET_HOME="$fresh_home"
zoomctl_install_hyprland_include >/dev/null
assert_contains "$fresh_home/.config/hypr/hyprland.conf" 'source = /usr/share/hyprland-zoom/hyprland-bindings.conf' 'fresh config created with legacy include'

printf 'setup tests passed\n'
