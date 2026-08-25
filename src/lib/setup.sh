#!/usr/bin/env bash
# Shared Hyprland config wiring, used by both zoomctl and the package install hooks
# so the two never drift out of sync.

ZOOMCTL_BINDINGS_FILE='/usr/share/hyprland-zoom/hyprland-bindings.conf'
ZOOMCTL_BINDINGS_INCLUDE="source = $ZOOMCTL_BINDINGS_FILE"
ZOOMCTL_BINDINGS_LUA_FILE='/usr/share/hyprland-zoom/hyprland-bindings.lua'
ZOOMCTL_BINDINGS_LUA_INCLUDE="dofile(\"$ZOOMCTL_BINDINGS_LUA_FILE\")"

zoomctl_target_home() {
  if [ -n "${ZOOMCTL_TARGET_HOME:-}" ]; then
    printf '%s\n' "$ZOOMCTL_TARGET_HOME"
    return 0
  fi

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != 'root' ]; then
    getent passwd "$SUDO_USER" | awk -F: '{ print $6 }'
    return 0
  fi

  if [ -n "${HOME:-}" ] && [ "$HOME" != '/root' ]; then
    printf '%s\n' "$HOME"
    return 0
  fi

  return 1
}

# Resolves the *account name* that should own any files we touch. This is
# only meaningful when we are root (e.g. a pacman install hook) writing into
# another user's home - a plain user invocation never needs to chown anything.
zoomctl_target_user() {
  if [ -n "${ZOOMCTL_TARGET_USER:-}" ]; then
    printf '%s\n' "$ZOOMCTL_TARGET_USER"
    return 0
  fi

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != 'root' ]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi

  return 1
}

# When running as root on another user's behalf, make sure any file or
# directory we create or rewrite still belongs to that user - otherwise
# Hyprland (running unprivileged) loses the ability to read or reload its
# own config after the package installs.
zoomctl_fix_ownership() {
  local path="$1"
  local target_user
  local target_group

  [ "$(id -u)" = '0' ] || return 0
  target_user="$(zoomctl_target_user)" || return 0
  target_group="$(id -gn "$target_user" 2>/dev/null)" || target_group="$target_user"

  chown "$target_user":"$target_group" "$path" 2>/dev/null || true
}

# mkdir -p that also fixes ownership on every directory it actually creates,
# so a fresh ~/.config or ~/.config/hypr does not end up root-owned.
zoomctl_mkdir_owned() {
  local dir="$1"
  local parent

  [ -d "$dir" ] && return 0

  parent="$(dirname -- "$dir")"
  [ "$parent" = "$dir" ] || zoomctl_mkdir_owned "$parent"

  mkdir "$dir" 2>/dev/null || mkdir -p "$dir"
  zoomctl_fix_ownership "$dir"
}

zoomctl_hyprland_config_file() {
  local target_home

  target_home="$(zoomctl_target_home)" || return 1

  # Only honor XDG_CONFIG_HOME for a direct, non-redirected invocation (no
  # ZOOMCTL_TARGET_HOME override, not running via sudo for another user) -
  # otherwise it may point at an unrelated user's config directory.
  if [ -z "${ZOOMCTL_TARGET_HOME:-}" ] && [ -z "${SUDO_USER:-}" ] && [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/hypr/hyprland.conf\n' "$XDG_CONFIG_HOME"
    return 0
  fi

  printf '%s/.config/hypr/hyprland.conf\n' "$target_home"
}

zoomctl_hyprland_lua_config_file() {
  local target_home

  target_home="$(zoomctl_target_home)" || return 1

  # Same XDG honoring as zoomctl_hyprland_config_file: only for a direct,
  # non-redirected invocation (no ZOOMCTL_TARGET_HOME override, not running
  # via sudo for another user).
  if [ -z "${ZOOMCTL_TARGET_HOME:-}" ] && [ -z "${SUDO_USER:-}" ] && [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s/hypr/hyprland.lua\n' "$XDG_CONFIG_HOME"
    return 0
  fi

  printf '%s/.config/hypr/hyprland.lua\n' "$target_home"
}

# Adds an exact line to a config file, creating the file when needed. Prints
# what it did and is safe to run repeatedly.
zoomctl_ensure_include() {
  local config_file="$1"
  local include_line="$2"
  local temporary_file
  local original_mode

  if [ ! -f "$config_file" ]; then
    zoomctl_mkdir_owned "$(dirname -- "$config_file")"
    printf '%s\n' "$include_line" > "$config_file"
    chmod 644 "$config_file"
    zoomctl_fix_ownership "$config_file"
    printf 'zoomctl: created %s\n' "$config_file"
    return 0
  fi

  if grep -Fxq "$include_line" "$config_file"; then
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    return 0
  fi

  original_mode="$(stat -c '%a' "$config_file" 2>/dev/null || printf '644')"

  temporary_file="$(mktemp)"
  cat "$config_file" > "$temporary_file"
  # Never glue the include onto the last line of a file that lacks a trailing
  # newline — that would turn a valid config file into a syntax error.
  if [ -s "$temporary_file" ] && [ "$(tail -c 1 "$temporary_file" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$temporary_file"
  fi
  printf '%s\n' "$include_line" >> "$temporary_file"
  chmod "$original_mode" "$temporary_file"
  mv "$temporary_file" "$config_file"
  zoomctl_fix_ownership "$config_file"
  printf 'zoomctl: added Hyprland include to %s\n' "$config_file"
}

zoomctl_install_hyprland_include() {
  local lua_config
  local conf_config

  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 1
  conf_config="$(zoomctl_hyprland_config_file)" || return 1

  # Hyprland 0.55+ uses the Lua config (hyprland.lua) when it exists. Wire
  # the Lua bindings into that file, and keep the legacy include in
  # hyprland.conf in sync when that file is also around, so the bindings
  # survive a switch back to the legacy config format.
  if [ -f "$lua_config" ]; then
    zoomctl_ensure_include "$lua_config" "$ZOOMCTL_BINDINGS_LUA_INCLUDE" || return 1
    if [ -f "$conf_config" ]; then
      zoomctl_ensure_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE" || return 1
    fi
    return 0
  fi

  zoomctl_ensure_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE" || return 1
}

# Removes an exact line from a config file. Deletes the file entirely when
# the include was its only content.
zoomctl_remove_include() {
  local config_file="$1"
  local include_line="$2"
  local temporary_file
  local original_mode

  [ -f "$config_file" ] || return 0

  original_mode="$(stat -c '%a' "$config_file" 2>/dev/null || printf '644')"

  temporary_file="$(mktemp)"
  grep -Fxv "$include_line" "$config_file" > "$temporary_file" || true

  if [ -s "$temporary_file" ]; then
    chmod "$original_mode" "$temporary_file"
    mv "$temporary_file" "$config_file"
    zoomctl_fix_ownership "$config_file"
  else
    rm -f "$temporary_file" "$config_file"
  fi
}

zoomctl_remove_hyprland_include() {
  local lua_config
  local conf_config

  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 0
  conf_config="$(zoomctl_hyprland_config_file)" || return 0

  [ -f "$lua_config" ] && zoomctl_remove_include "$lua_config" "$ZOOMCTL_BINDINGS_LUA_INCLUDE"
  [ -f "$conf_config" ] && zoomctl_remove_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE"
}
