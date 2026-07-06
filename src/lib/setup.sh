#!/usr/bin/env bash
# Shared Hyprland config wiring, used by both zoomctl and the package install hooks
# so the two never drift out of sync.

ZOOMCTL_BINDINGS_FILE='/usr/share/hyprland-zoom/hyprland-bindings.conf'
ZOOMCTL_BINDINGS_INCLUDE="source = $ZOOMCTL_BINDINGS_FILE"

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

zoomctl_install_hyprland_include() {
  local config_file
  local temporary_file
  local original_mode

  config_file="$(zoomctl_hyprland_config_file)" || return 1

  if [ ! -f "$config_file" ]; then
    zoomctl_mkdir_owned "$(dirname -- "$config_file")"
    printf '%s\n' "$ZOOMCTL_BINDINGS_INCLUDE" > "$config_file"
    chmod 644 "$config_file"
    zoomctl_fix_ownership "$config_file"
    printf 'zoomctl: created %s\n' "$config_file"
    return 0
  fi

  if grep -Fxq "$ZOOMCTL_BINDINGS_INCLUDE" "$config_file"; then
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    return 0
  fi

  original_mode="$(stat -c '%a' "$config_file" 2>/dev/null || printf '644')"

  temporary_file="$(mktemp)"
  cat "$config_file" > "$temporary_file"
  printf '%s\n' "$ZOOMCTL_BINDINGS_INCLUDE" >> "$temporary_file"
  chmod "$original_mode" "$temporary_file"
  mv "$temporary_file" "$config_file"
  zoomctl_fix_ownership "$config_file"
  printf 'zoomctl: added Hyprland include to %s\n' "$config_file"
}

zoomctl_remove_hyprland_include() {
  local config_file
  local temporary_file
  local original_mode

  config_file="$(zoomctl_hyprland_config_file)" || return 0
  [ -f "$config_file" ] || return 0

  original_mode="$(stat -c '%a' "$config_file" 2>/dev/null || printf '644')"

  temporary_file="$(mktemp)"
  grep -Fxv "$ZOOMCTL_BINDINGS_INCLUDE" "$config_file" > "$temporary_file" || true

  if [ -s "$temporary_file" ]; then
    chmod "$original_mode" "$temporary_file"
    mv "$temporary_file" "$config_file"
    zoomctl_fix_ownership "$config_file"
  else
    rm -f "$temporary_file" "$config_file"
  fi
}
