# NOTE: this scriptlet is intentionally self-contained and duplicates a
# subset of src/lib/setup.sh instead of sourcing it. pacman's package
# database stores .INSTALL scriptlets independently of the package's
# installed files, and on removal it deletes those files *before* calling
# post_remove() - so this script cannot rely on
# /usr/share/hyprland-zoom/lib/setup.sh (or anything else the package ships)
# still being present when it runs. Keep the two in sync by hand if the
# Hyprland-include logic changes.

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

zoomctl_fix_ownership() {
  local path="$1"
  local target_user
  local target_group

  [ "$(id -u)" = '0' ] || return 0
  target_user="$(zoomctl_target_user)" || return 0
  target_group="$(id -gn "$target_user" 2>/dev/null)" || target_group="$target_user"

  chown "$target_user":"$target_group" "$path" 2>/dev/null || true
}

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
  printf '%s/.config/hypr/hyprland.conf\n' "$target_home"
}

zoomctl_hyprland_lua_config_file() {
  local target_home

  target_home="$(zoomctl_target_home)" || return 1
  printf '%s/.config/hypr/hyprland.lua\n' "$target_home"
}

zoomctl_install_hyprland_include() {
  local lua_config
  local conf_config

  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 1
  conf_config="$(zoomctl_hyprland_config_file)" || return 1

  # Hyprland 0.55+ uses the Lua config (hyprland.lua) when it exists. Wire
  # the Lua bindings into that file, and keep the legacy include in
  # hyprland.conf in sync when that file is also around.
  if [ -f "$lua_config" ]; then
    zoomctl_ensure_include "$lua_config" "$ZOOMCTL_BINDINGS_LUA_INCLUDE" || return 1
    if [ -f "$conf_config" ]; then
      zoomctl_ensure_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE" || return 1
    fi
    return 0
  fi

  zoomctl_ensure_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE" || return 1
}

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
    return 0
  fi

  if grep -Fxq "$include_line" "$config_file"; then
    return 0
  fi

  original_mode="$(stat -c '%a' "$config_file" 2>/dev/null || printf '644')"

  temporary_file="$(mktemp)"
  cat "$config_file" > "$temporary_file"
  printf '%s\n' "$include_line" >> "$temporary_file"
  chmod "$original_mode" "$temporary_file"
  mv "$temporary_file" "$config_file"
  zoomctl_fix_ownership "$config_file"
}

zoomctl_remove_hyprland_include() {
  local lua_config
  local conf_config

  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 0
  conf_config="$(zoomctl_hyprland_config_file)" || return 0

  [ -f "$lua_config" ] && zoomctl_remove_include "$lua_config" "$ZOOMCTL_BINDINGS_LUA_INCLUDE"
  [ -f "$conf_config" ] && zoomctl_remove_include "$conf_config" "$ZOOMCTL_BINDINGS_INCLUDE"
}

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

post_install() {
  if zoomctl_install_hyprland_include >/dev/null 2>&1; then
    cat <<'EOF'
hyprland-zoom has been installed and Hyprland was configured for the current user.

Next steps:
  1. Review /etc/zoomctl.conf or create ~/.config/zoomctl/zoom.conf for user overrides.
  2. Run `zoomctl status` inside a Hyprland session.
EOF
  else
    cat <<'EOF'
hyprland-zoom has been installed.

Could not automatically update a Hyprland config file for this install context.

Next steps:
  1. Source /usr/share/hyprland-zoom/hyprland-bindings.conf from your Hyprland config.
  2. Or run `zoomctl setup` to add the include line automatically.
  3. Review /etc/zoomctl.conf or create ~/.config/zoomctl/zoom.conf for user overrides.
  4. Run `zoomctl status` inside a Hyprland session.
EOF
  fi
}

post_upgrade() {
  post_install
}

post_remove() {
  zoomctl_remove_hyprland_include || true
  cat <<'EOF'
hyprland-zoom has been removed.

If you created a user override at ~/.config/zoomctl/zoom.conf, you can delete it manually.
EOF
}
