#!/usr/bin/env bash
# setup.sh — wire hyprland-zoom into the user's Hyprland config (zoomctl setup).
# The functions between the "shared wiring block" markers are duplicated byte for byte in
# install/post_install.sh, which must stay self-contained (pacman deletes package files before
# post_remove runs). tests/setup.sh fails when the two copies drift apart.

# ---- shared wiring block: begin ----

# zoomctl_share_dir — print the directory that holds the packaged data files.
# Args:    none
# Returns: 0 always; stdout: ZOOMCTL_SHARE_DIR or /usr/share/hyprland-zoom
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_share_dir() {
  # The override lets tests and checkouts point the include lines elsewhere.
  printf '%s\n' "${ZOOMCTL_SHARE_DIR:-/usr/share/hyprland-zoom}"
}

# zoomctl_engine_include_line — the Lua line that loads the 0.2 engine.
# Args:    none
# Returns: 0 always; stdout: dofile("<share>/hyprland-zoom.lua")
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_engine_include_line() {
  # Double quotes match what 0.1 wrote, so users recognise the line.
  printf 'dofile("%s/hyprland-zoom.lua")\n' "$(zoomctl_share_dir)"
}

# zoomctl_conf_include_line — the hyprlang line that sources the legacy binds.
# Args:    none
# Returns: 0 always; stdout: source = <share>/hyprland-bindings.conf
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_conf_include_line() {
  # Identical to the line 0.1 wrote, so upgrades stay idempotent.
  printf 'source = %s/hyprland-bindings.conf\n' "$(zoomctl_share_dir)"
}

# zoomctl_is_dofile_line — recognise a dofile("<any path>/<basename>") line (quotes ' or ").
# Args:    $1 one config line; $2 file basename such as hyprland-zoom.lua
# Returns: 0 it is such a line; 1 it is not
# Globals: none
zoomctl_is_dofile_line() {
  local quote="[\"']"
  local path_text="[^\"']*"
  # The finished regular expression, built from the pieces above.
  local pattern
  # Anchored at the line start, so a commented-out dofile never matches.
  pattern="^[[:space:]]*dofile[[:space:]]*\([[:space:]]*${quote}${path_text}/${2//./\\.}"
  pattern+="${quote}[[:space:]]*\)[[:space:]]*\$"
  [[ "$1" =~ $pattern ]]
}

# zoomctl_is_engine_include_line — the line that loads the 0.2 engine.
# Args:    $1 one config line
# Returns: 0 it is one; 1 it is not
# Globals: none
zoomctl_is_engine_include_line() {
  zoomctl_is_dofile_line "$1" 'hyprland-zoom.lua'
}

# zoomctl_is_legacy_lua_include_line — the 0.1 line that loaded hyprland-bindings.lua.
# Args:    $1 one config line
# Returns: 0 it is the 0.1 line; 1 it is not (including the user's own bindings files)
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_legacy_lua_include_line() {
  zoomctl_is_dofile_line "$1" 'hyprland-bindings.lua' || return 1
  # Only our own file counts: the path names the package or the configured share dir.
  [[ "$1" == *"hyprland-zoom/"* || "$1" == *"$(zoomctl_share_dir)/hyprland-bindings.lua"* ]]
}

# zoomctl_is_managed_lua_line — a Lua config line this tool owns (engine or 0.1 include).
# Args:    $1 one config line
# Returns: 0 managed; 1 not managed
# Globals: none
zoomctl_is_managed_lua_line() {
  # Both spellings are replaced by the single engine line.
  zoomctl_is_engine_include_line "$1" || zoomctl_is_legacy_lua_include_line "$1"
}

# zoomctl_is_conf_include_line — a hyprlang line that sources our bindings file.
# Args:    $1 one config line
# Returns: 0 it is the include; 1 it is not
# Globals: none
zoomctl_is_conf_include_line() {
  local pattern='^[[:space:]]*source[[:space:]]*=[[:space:]]*[^#]*/hyprland-bindings\.conf'
  pattern+='[[:space:]]*$'
  # Shape check first; the ownership check follows below.
  [[ "$1" =~ $pattern ]] || return 1
  # Same ownership test as for the Lua line: package directory or the configured share dir.
  [[ "$1" == *"hyprland-zoom/"* || "$1" == *"$(zoomctl_share_dir)/hyprland-bindings.conf"* ]]
}

# zoomctl_file_has_line_where — test whether any line of a file satisfies a predicate.
# Args:    $1 file; $2 predicate function name taking one line
# Returns: 0 a line matches; 1 none matches or the file is unreadable
# Globals: none
zoomctl_file_has_line_where() {
  local line
  [ -r "$1" ] || return 1
  # Stop at the first hit.
  while IFS= read -r line || [ -n "$line" ]; do
    "$2" "$line" && return 0
  done < "$1"
  return 1
}

# zoomctl_target_home — home directory of the user whose Hyprland config is edited.
# Args:    none
# Returns: 0 found; 1 unknown; stdout: path
# Globals: reads ZOOMCTL_TARGET_HOME, SUDO_USER, HOME
zoomctl_target_home() {
  # An explicit override first (tests, install hooks).
  if [ -n "${ZOOMCTL_TARGET_HOME:-}" ]; then
    printf '%s\n' "$ZOOMCTL_TARGET_HOME"
    return 0
  fi
  # Running through sudo: the invoking user owns the config.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != 'root' ]; then
    getent passwd "$SUDO_USER" | awk -F: '{ print $6 }'
    return 0
  fi
  # A plain user session; root's home is never the target.
  if [ -n "${HOME:-}" ] && [ "$HOME" != '/root' ]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  # No usable home: the caller decides what to do.
  return 1
}

# zoomctl_target_user — account that must own files written on a user's behalf.
# Args:    none
# Returns: 0 found; 1 not applicable; stdout: user name
# Globals: reads ZOOMCTL_TARGET_USER, SUDO_USER
zoomctl_target_user() {
  # Only meaningful for root writing into another user's home.
  if [ -n "${ZOOMCTL_TARGET_USER:-}" ]; then
    printf '%s\n' "$ZOOMCTL_TARGET_USER"
    return 0
  fi
  # Running through sudo: the invoking user owns the files.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != 'root' ]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  # Not applicable: there is nobody to hand files to.
  return 1
}

# zoomctl_fix_ownership — hand a file back to the target user when running as root.
# Args:    $1 path
# Returns: 0 always
# Globals: none
zoomctl_fix_ownership() {
  local target_user target_group
  # Hyprland runs unprivileged and must keep read/write access to its config.
  [ "$(id -u)" = '0' ] || return 0
  target_user="$(zoomctl_target_user)" || return 0
  target_group="$(id -gn "$target_user" 2>/dev/null)" || target_group="$target_user"
  # Best effort: a failed chown must not abort the wiring.
  chown "$target_user":"$target_group" "$1" 2>/dev/null || true
}

# zoomctl_mkdir_owned — mkdir -p that also fixes ownership of every directory it creates.
# Args:    $1 directory
# Returns: 0 always
# Globals: none
zoomctl_mkdir_owned() {
  local parent
  [ -d "$1" ] && return 0
  # Create the parents first so each level gets the right owner.
  parent="$(dirname -- "$1")"
  [ "$parent" = "$1" ] || zoomctl_mkdir_owned "$parent"
  mkdir "$1" 2>/dev/null || mkdir -p "$1"
  # The new directory belongs to the user, not to root.
  zoomctl_fix_ownership "$1"
}

# zoomctl_hyprland_lua_config_file — path of hyprland.lua for the target user.
# Args:    none
# Returns: 0 ok; 1 no target home; stdout: path
# Globals: reads ZOOMCTL_TARGET_HOME, SUDO_USER, XDG_CONFIG_HOME
zoomctl_hyprland_lua_config_file() {
  local target_home
  target_home="$(zoomctl_target_home)" || return 1
  # XDG_CONFIG_HOME is only trusted for a direct, non-redirected invocation.
  if [ -z "${ZOOMCTL_TARGET_HOME:-}" ] && [ -z "${SUDO_USER:-}" ] &&
    [ -n "${XDG_CONFIG_HOME:-}" ]; then
    # A direct invocation honours the XDG location.
    printf '%s/hypr/hyprland.lua\n' "$XDG_CONFIG_HOME"
    return 0
  fi
  # Default location for a plain session.
  printf '%s/.config/hypr/hyprland.lua\n' "$target_home"
}

# zoomctl_hyprland_config_file — path of the legacy hyprland.conf for the target user.
# Args:    none
# Returns: 0 ok; 1 no target home; stdout: path
# Globals: reads ZOOMCTL_TARGET_HOME, SUDO_USER, XDG_CONFIG_HOME
zoomctl_hyprland_config_file() {
  local lua_config
  # The two files always live side by side.
  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 1
  printf '%s/hyprland.conf\n' "$(dirname -- "$lua_config")"
}

# zoomctl_backup_file — copy a config file next to itself before it is edited.
# Args:    $1 file
# Returns: 0 always; stdout: none (the backup name is announced on stderr)
# Globals: none
zoomctl_backup_file() {
  local backup_file
  # The timestamp keeps every earlier backup, so the original is never overwritten.
  backup_file="$1.zoomctl-bak-$(date +%Y%m%d%H%M%S)"
  cp -p -- "$1" "$backup_file" && zoomctl_fix_ownership "$backup_file"
  printf 'zoomctl: backup of %s saved as %s\n' "$1" "$backup_file" >&2
}

# zoomctl_replace_file — atomically put a prepared draft in place of a config file.
# Args:    $1 draft file (same directory); $2 target file
# Returns: 0 replaced; 1 failed
# Globals: none
zoomctl_replace_file() {
  local original_mode
  # Keep the permissions the user had; a fresh file is world-readable.
  original_mode="$(stat -c '%a' -- "$2" 2>/dev/null || printf '644')"
  chmod "$original_mode" "$1"
  mv -f -- "$1" "$2" || return 1
  # The replaced file keeps the user's ownership.
  zoomctl_fix_ownership "$2"
}

# zoomctl_render_lua_config — print a Lua config with one engine include replacing ours.
# Args:    $1 config file
# Returns: 0 always; stdout: new content (0.1 line replaced in place, else appended)
# Globals: none
zoomctl_render_lua_config() {
  local line engine_line emitted=0
  engine_line="$(zoomctl_engine_include_line)"
  # Walk the file once; the first managed line becomes the engine line.
  while IFS= read -r line || [ -n "$line" ]; do
    if zoomctl_is_managed_lua_line "$line"; then
      [ "$emitted" -eq 0 ] && printf '%s\n' "$engine_line"
      # Later managed lines (duplicates, 0.1 leftovers) are dropped.
      emitted=1
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
  # No managed line yet: append the include at the end so it loads after the user's binds.
  [ "$emitted" -eq 1 ] || printf '%s\n' "$engine_line"
}

# zoomctl_wire_lua_config — make hyprland.lua load the engine exactly once (idempotent).
# Args:    $1 path of hyprland.lua (created when missing)
# Returns: 0 done; 1 cannot write
# Globals: none
zoomctl_wire_lua_config() {
  local config_file="$1"
  local draft_file
  # A missing file is created with just the include.
  if [ ! -f "$config_file" ]; then
    zoomctl_mkdir_owned "$(dirname -- "$config_file")"
    zoomctl_engine_include_line > "$config_file" || return 1
    # A file created as root would lock the user out.
    zoomctl_fix_ownership "$config_file"
    printf 'zoomctl: created %s\n' "$config_file"
    return 0
  fi
  # The draft is built beside the original for an atomic swap.
  draft_file="$(mktemp "$config_file.XXXXXX")" || return 1
  zoomctl_render_lua_config "$config_file" > "$draft_file"
  # Identical output means nothing to do, and no backup clutter either.
  if cmp -s -- "$draft_file" "$config_file"; then
    rm -f -- "$draft_file"
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    # No change: no backup and no rewrite.
    return 0
  fi
  zoomctl_backup_file "$config_file"
  zoomctl_replace_file "$draft_file" "$config_file" || { rm -f -- "$draft_file"; return 1; }
  # The announcement tells the user which file changed.
  printf 'zoomctl: wired the engine into %s\n' "$config_file"
}

# zoomctl_render_conf_config — print a hyprland.conf with our include appended.
# Args:    $1 config file
# Returns: 0 always; stdout: the content, newline-terminated, include last
# Globals: none
zoomctl_render_conf_config() {
  local line
  # Reading line by line also terminates an unterminated last line.
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
  done < "$1"
  zoomctl_conf_include_line
}

# zoomctl_ensure_conf_include — append the hyprlang include line when it is missing.
# Args:    $1 path of hyprland.conf (created when missing)
# Returns: 0 done; 1 cannot write
# Globals: none
zoomctl_ensure_conf_include() {
  local config_file="$1"
  local draft_file
  # A missing file is created with just the include.
  if [ ! -f "$config_file" ]; then
    zoomctl_mkdir_owned "$(dirname -- "$config_file")"
    zoomctl_conf_include_line > "$config_file" || return 1
    # New dotfiles are world-readable like the rest of ~/.config.
    chmod 644 "$config_file"
    zoomctl_fix_ownership "$config_file"
    # Creating the file is announced like any other change.
    printf 'zoomctl: created %s\n' "$config_file"
    return 0
  fi
  # Any form of the include counts as present.
  if zoomctl_file_has_line_where "$config_file" zoomctl_is_conf_include_line; then
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    return 0
  fi
  # The draft is built beside the original for an atomic swap.
  draft_file="$(mktemp "$config_file.XXXXXX")" || return 1
  # Copy the file; the line reader below re-terminates an unterminated last line.
  zoomctl_render_conf_config "$config_file" > "$draft_file"
  zoomctl_backup_file "$config_file"
  zoomctl_replace_file "$draft_file" "$config_file" || { rm -f -- "$draft_file"; return 1; }
  # The announcement tells the user which file changed.
  printf 'zoomctl: added Hyprland include to %s\n' "$config_file"
}

# zoomctl_install_hyprland_include — wire the engine (Lua) or the legacy binds (hyprlang).
# Args:    none
# Returns: 0 done; 1 failed or no target home
# Globals: reads the target-home variables
zoomctl_install_hyprland_include() {
  local lua_config conf_config
  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 1
  # The legacy file always sits next to hyprland.lua.
  conf_config="$(zoomctl_hyprland_config_file)" || return 1
  # Hyprland 0.55+ uses hyprland.lua when it exists; keep a present hyprland.conf in sync too.
  if [ -f "$lua_config" ]; then
    zoomctl_wire_lua_config "$lua_config" || return 1
    [ -f "$conf_config" ] && { zoomctl_ensure_conf_include "$conf_config" || return 1; }
    # The Lua path is done; the conf was kept in sync above.
    return 0
  fi
  zoomctl_ensure_conf_include "$conf_config"
}

# zoomctl_remove_matching_lines — delete the lines a predicate accepts; drop an emptied file.
# Args:    $1 config file; $2 name of a predicate function taking one line
# Returns: 0 always
# Globals: none
zoomctl_remove_matching_lines() {
  local config_file="$1"
  local line draft_file removed=0
  # Nothing to remove from a missing file.
  [ -f "$config_file" ] || return 0
  draft_file="$(mktemp "$config_file.XXXXXX")" || return 0
  # Copy every line the predicate does not claim.
  while IFS= read -r line || [ -n "$line" ]; do
    if "$2" "$line"; then removed=1; else printf '%s\n' "$line" >> "$draft_file"; fi
  done < "$config_file"
  # Nothing of ours in the file: leave it untouched.
  [ "$removed" -eq 1 ] || { rm -f -- "$draft_file"; return 0; }
  zoomctl_backup_file "$config_file"
  if [ -s "$draft_file" ]; then
    # Keep the user's own lines; an emptied file is deleted below.
    zoomctl_replace_file "$draft_file" "$config_file" || rm -f -- "$draft_file"
  else
    rm -f -- "$draft_file" "$config_file"
  fi
}

# zoomctl_remove_hyprland_include — undo the wiring in both config files (engine and 0.1 lines).
# Args:    none
# Returns: 0 always
# Globals: reads the target-home variables
zoomctl_remove_hyprland_include() {
  local lua_config conf_config
  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 0
  # The legacy file always sits next to hyprland.lua.
  conf_config="$(zoomctl_hyprland_config_file)" || return 0
  # Each file loses only the lines this tool wrote.
  zoomctl_remove_matching_lines "$lua_config" zoomctl_is_managed_lua_line
  zoomctl_remove_matching_lines "$conf_config" zoomctl_is_conf_include_line
}

# ---- shared wiring block: end ----
