#!/usr/bin/env bash
# setup.sh — wire hyprland-zoom into the user's Hyprland config (zoomctl setup).
# The functions between the "shared wiring block" markers are duplicated byte for byte in
# install/post_install.sh, which must stay self-contained (pacman deletes package files before
# post_remove runs). tests/test-setup.sh fails when the two copies drift apart.
#
# The block also holds the safe file helpers (draft, backup, replace) that the user-config
# writer reuses: they resolve symlinked dotfiles, keep modes and never follow links as root.

# ---- shared wiring block: begin ----

# Oldest Hyprland release whose Lua config manager can load the engine.
ZOOMCTL_MIN_LUA_HYPRLAND_MAJOR=0
ZOOMCTL_MIN_LUA_HYPRLAND_MINOR=55
# Where the package installs the engine; lines pointing here are ours whatever the share dir is.
ZOOMCTL_PACKAGE_ENGINE_PATH='/usr/share/hyprland-zoom/hyprland-zoom.lua'

# zoomctl_share_dir — print the directory that holds the packaged data files.
# Args:    none
# Returns: 0 always; stdout: ZOOMCTL_SHARE_DIR or /usr/share/hyprland-zoom
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_share_dir() {
  # The override lets tests and checkouts point the include lines elsewhere.
  printf '%s\n' "${ZOOMCTL_SHARE_DIR:-/usr/share/hyprland-zoom}"
}

# zoomctl_engine_path — print the engine file the include line must load.
# Args:    none
# Returns: 0 always; stdout: <share>/hyprland-zoom.lua
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_engine_path() {
  # One place builds the path, so the line and its recogniser can never disagree.
  printf '%s/hyprland-zoom.lua\n' "$(zoomctl_share_dir)"
}

# zoomctl_engine_include_line — the Lua line that loads the 0.2 engine.
# Args:    none
# Returns: 0 always; stdout: dofile("<share>/hyprland-zoom.lua")
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_engine_include_line() {
  # Double quotes match what 0.1 wrote, so users recognise the line.
  printf 'dofile("%s")\n' "$(zoomctl_engine_path)"
}

# zoomctl_conf_include_line — the hyprlang line that sources the legacy binds.
# Args:    none
# Returns: 0 always; stdout: source = <share>/hyprland-bindings.conf
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_conf_include_line() {
  # Identical to the line 0.1 wrote, so upgrades stay idempotent.
  printf 'source = %s/hyprland-bindings.conf\n' "$(zoomctl_share_dir)"
}

# zoomctl_wiring_fail — report why the wiring could not be changed.
# Args:    $1 message
# Returns: 1 always; stderr: "zoomctl: <message>"
# Globals: none
zoomctl_wiring_fail() {
  # Every failure names its real cause; callers pass the status on.
  printf 'zoomctl: %s\n' "$1" >&2
  return 1
}

# zoomctl_is_root — test whether the wiring runs with root privileges (pacman hook, sudo).
# Args:    none
# Returns: 0 root; 1 a normal user
# Globals: none
zoomctl_is_root() {
  # Root writes into other people's homes, so it gets stricter rules below.
  [ "$(id -u)" = '0' ]
}

# zoomctl_dofile_target — extract the path of a dofile("<dir>/<basename>") line.
# Args:    $1 one config line; $2 file basename such as hyprland-zoom.lua
# Returns: 0 it is such a line; 1 it is not; stdout: the quoted path
# Globals: none
zoomctl_dofile_target() {
  local base_pattern="${2//./\\.}"
  local quote call_open call_close pattern
  # After the call a `;` and a trailing Lua comment are still the same statement.
  local tail_pattern='[[:space:]]*;?[[:space:]]*(--.*)?$'
  for quote in '"' "'"; do
    # Both dofile("x") and the parenthesis-less dofile "x" are valid Lua.
    for call_open in '[[:space:]]*\([[:space:]]*' '[[:space:]]*'; do
      call_close='[[:space:]]*\)'
      [ "$call_open" = '[[:space:]]*' ] && call_close=''
      # Anchored at the line start, so a commented-out dofile never matches.
      pattern="^[[:space:]]*dofile${call_open}${quote}([^${quote}]*/${base_pattern})${quote}"
      pattern+="${call_close}${tail_pattern}"
      # The first form that matches yields the quoted path.
      [[ "$1" =~ $pattern ]] && { printf '%s\n' "${BASH_REMATCH[1]}"; return 0; }
    done
  done
  return 1
}

# zoomctl_lua_line_kind — classify one line of hyprland.lua.
# Args:    $1 one config line
# Returns: 0 always; stdout: engine-own | engine-package | engine-custom | legacy-include | other
# Globals: reads ZOOMCTL_SHARE_DIR, ZOOMCTL_PACKAGE_ENGINE_PATH
zoomctl_lua_line_kind() {
  local include_path
  # The 0.2 engine file: ours, the package's, or the user's own copy elsewhere.
  if include_path="$(zoomctl_dofile_target "$1" hyprland-zoom.lua)"; then
    case "$include_path" in
      # Our own path first, then the package default; anything else is the user's.
      "$(zoomctl_engine_path)") printf 'engine-own\n' ;;
      "$ZOOMCTL_PACKAGE_ENGINE_PATH") printf 'engine-package\n' ;;
      # Any other path is the user's own checkout or copy: hands off.
      *) printf 'engine-custom\n' ;;
    esac
    return 0
  fi
  # The 0.1 shim counts only when it lives in our package or share directory.
  if include_path="$(zoomctl_dofile_target "$1" hyprland-bindings.lua)" &&
    [[ "$include_path" == *"hyprland-zoom/"* ||
      "$include_path" == "$(zoomctl_share_dir)/hyprland-bindings.lua" ]]; then
    # Ours: replaced by the engine line on setup, removed on uninstall.
    printf 'legacy-include\n'
    return 0
  fi
  printf 'other\n'
}

# zoomctl_is_engine_include_line — a line that loads the 0.2 engine from anywhere.
# Args:    $1 one config line
# Returns: 0 it is one; 1 it is not
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_engine_include_line() {
  # Our line, the package's line and a user's own copy all load the engine.
  case "$(zoomctl_lua_line_kind "$1")" in
    engine-*) return 0 ;;
  esac
  return 1
}

# zoomctl_is_custom_engine_line — the user's own engine include (checkout, copy), not ours.
# Args:    $1 one config line
# Returns: 0 it is one; 1 it is not
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_custom_engine_line() {
  # Such a line is left alone and keeps setup from adding a second engine load.
  [ "$(zoomctl_lua_line_kind "$1")" = 'engine-custom' ]
}

# zoomctl_is_legacy_lua_include_line — the 0.1 line that loaded hyprland-bindings.lua.
# Args:    $1 one config line
# Returns: 0 it is the 0.1 line; 1 it is not (including the user's own bindings files)
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_legacy_lua_include_line() {
  # Only our own shim counts; foreign bindings files are never touched.
  [ "$(zoomctl_lua_line_kind "$1")" = 'legacy-include' ]
}

# zoomctl_is_managed_lua_line — a Lua config line this tool owns (engine or 0.1 include).
# Args:    $1 one config line
# Returns: 0 managed; 1 not managed (including a user's custom engine path)
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_managed_lua_line() {
  # Managed lines are replaced by the single engine line or removed on uninstall.
  case "$(zoomctl_lua_line_kind "$1")" in
    engine-own|engine-package|legacy-include) return 0 ;;
  esac
  return 1
}

# zoomctl_is_conf_include_line — a hyprlang line that sources our bindings file.
# Args:    $1 one config line
# Returns: 0 it is the include; 1 it is not
# Globals: reads ZOOMCTL_SHARE_DIR
zoomctl_is_conf_include_line() {
  local pattern='^[[:space:]]*source[[:space:]]*=[[:space:]]*([^#]*/hyprland-bindings\.conf)'
  pattern+='[[:space:]]*(#.*)?$'
  # Shape check first (an optional trailing comment is fine); the ownership check follows.
  [[ "$1" =~ $pattern ]] || return 1
  # Ownership: the path names the package directory or the configured share dir.
  [[ "${BASH_REMATCH[1]}" == *"hyprland-zoom/"* ||
    "${BASH_REMATCH[1]}" == "$(zoomctl_share_dir)/hyprland-bindings.conf" ]]
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
  # No line satisfied the predicate.
  return 1
}

# zoomctl_target_home — home directory of the user whose Hyprland config is edited.
# Args:    none
# Returns: 0 found; 1 unknown or unusable; stdout: path
# Globals: reads ZOOMCTL_TARGET_HOME, SUDO_USER, HOME
zoomctl_target_home() {
  local account_home
  # An explicit override first (tests, install hooks).
  if [ -n "${ZOOMCTL_TARGET_HOME:-}" ]; then
    printf '%s\n' "$ZOOMCTL_TARGET_HOME"
    return 0
  fi
  # Running through sudo: the invoking user owns the config, and the account must resolve.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != 'root' ]; then
    account_home="$(getent passwd "$SUDO_USER" | awk -F: '{ print $6 }')"
    # An unknown account must not turn into a write below "/".
    [[ "$account_home" == /* && -d "$account_home" ]] || return 1
    printf '%s\n' "$account_home"
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
# Returns: 0 always (best effort; a failed chown must not abort the wiring)
# Globals: none
zoomctl_fix_ownership() {
  local target_user target_group
  # Hyprland runs unprivileged and must keep read/write access to its config.
  zoomctl_is_root || return 0
  target_user="$(zoomctl_target_user)" || return 0
  target_group="$(id -gn "$target_user" 2>/dev/null)" || target_group="$target_user"
  # -h: never follow a link planted at the path, change the link itself.
  chown -h "$target_user":"$target_group" "$1" 2>/dev/null || true
}

# zoomctl_refuse_root_symlink — as root, refuse a path that is or sits below a symlink.
# Args:    $1 path of a file that will be created, edited or removed
# Returns: 0 safe (or not root); 1 refused (message on stderr)
# Globals: none
zoomctl_refuse_root_symlink() {
  local checked_path="$1" level
  zoomctl_is_root || return 0
  # File, hypr directory and .config: a link in any of them could point at /etc or worse.
  for level in 1 2 3; do
    if [ -L "$checked_path" ]; then
      # The message names the link so the user can inspect it.
      zoomctl_wiring_fail "refusing to follow the symlink $checked_path as root"
      return 1
    fi
    checked_path="$(dirname -- "$checked_path")"
  done
}

# zoomctl_real_path — the file a config path really names (symlinks resolved).
# Args:    $1 path (may not exist yet)
# Returns: 0 resolved; 1 cannot be resolved; stdout: absolute path
# Globals: none
zoomctl_real_path() {
  # Root never follows links (see zoomctl_refuse_root_symlink), so its path stays as given.
  if zoomctl_is_root; then
    printf '%s\n' "$1"
  else
    readlink -f -- "$1"
  fi
}

# zoomctl_new_draft — create a private draft file next to the file it will replace.
# Args:    $1 target path (a symlink is resolved, the draft sits next to the real file)
# Returns: 0 created; 1 failed (message on stderr); stdout: draft path
# Globals: none
zoomctl_new_draft() {
  local real_target
  real_target="$(zoomctl_real_path "$1")" || return 1
  # mktemp makes the draft 0600 (private until the final mode is set) in the target's own
  # directory, so the closing rename stays on one file system and atomic.
  mktemp "$real_target.XXXXXX" 2>/dev/null ||
    zoomctl_wiring_fail "cannot create a draft next to $real_target"
}

# zoomctl_backup_file — copy a config file next to itself before it is edited.
# Args:    $1 file; $2 optional label (default zoomctl-bak)
# Returns: 0 backup saved; 1 no backup could be made (message on stderr)
# Globals: none
zoomctl_backup_file() {
  local real_file backup_file backup_template
  real_file="$(zoomctl_real_path "$1")" || return 1
  # An unpredictable name: nobody can pre-plant a link there for a privileged copy to follow.
  backup_template="$real_file.${2:-zoomctl-bak}-$(date +%Y%m%d%H%M%S)-XXXXXX"
  backup_file="$(mktemp "$backup_template" 2>/dev/null)" ||
    { zoomctl_wiring_fail "cannot create a backup of $real_file"; return 1; }
  # -P keeps links as links, -p keeps mode and times; a failed copy aborts the edit.
  if ! cp -pP -- "$real_file" "$backup_file" 2>/dev/null; then
    # An empty leftover must not pass for a real backup.
    rm -f -- "$backup_file"
    zoomctl_wiring_fail "cannot back up $real_file"
    return 1
  fi
  # The backup belongs to the user, like the file it copies.
  zoomctl_fix_ownership "$backup_file"
  printf 'zoomctl: backup of %s saved as %s\n' "$real_file" "$backup_file" >&2
}

# zoomctl_replace_file — atomically put a prepared draft in place of a config file.
# Args:    $1 draft file (from zoomctl_new_draft); $2 target file; $3 default mode (644)
# Returns: 0 replaced; 1 failed (message on stderr)
# Globals: none
zoomctl_replace_file() {
  local real_target original_mode
  real_target="$(zoomctl_real_path "$2")" || return 1
  # Keep the mode the user had (stat -L reads through a symlink); a fresh file gets the default.
  original_mode="$(stat -L -c '%a' -- "$real_target" 2>/dev/null)" || original_mode="${3:-644}"
  # The config is code Hyprland runs, so a world-writable bit is never carried over.
  chmod "$(printf '%o' "$((8#$original_mode & ~8#002))")" -- "$1" || return 1
  # Renaming onto the resolved path keeps a dotfile symlink in place and is atomic.
  mv -f -- "$1" "$real_target" || { zoomctl_wiring_fail "cannot replace $real_target"; return 1; }
  # The replaced file keeps the user's ownership.
  zoomctl_fix_ownership "$real_target"
}

# zoomctl_commit_draft — back up the original, then replace it with the finished draft.
# Args:    $1 draft file; $2 target file; $3 optional validator command run on the draft
# Returns: 0 replaced; 1 failed (the target is untouched, the draft is removed)
# Globals: none
zoomctl_commit_draft() {
  # A draft that fails its check must never replace a working config.
  if [ -n "${3:-}" ] && ! "$3" "$1"; then
    rm -f -- "$1"
    return 1
  fi
  # No backup, no edit: a failed backup stops the replacement.
  zoomctl_backup_file "$2" || { rm -f -- "$1"; return 1; }
  zoomctl_replace_file "$1" "$2" || { rm -f -- "$1"; return 1; }
}

# zoomctl_mkdir_owned — mkdir -p that also fixes ownership of every directory it creates.
# Args:    $1 directory
# Returns: 0 exists or created; 1 cannot be created (message on stderr)
# Globals: none
zoomctl_mkdir_owned() {
  local parent
  [ -d "$1" ] && return 0
  # Create the parents first so each level gets the right owner.
  parent="$(dirname -- "$1")"
  [ "$parent" = "$1" ] || zoomctl_mkdir_owned "$parent" || return 1
  mkdir -- "$1" 2>/dev/null || { zoomctl_wiring_fail "cannot create the directory $1"; return 1; }
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

# zoomctl_hyprctl_version_text — ask a running Hyprland for its version.
# Args:    none
# Returns: 0 found; 1 no hyprctl or no instance; stdout: for example 0.56.2
# Globals: none
zoomctl_hyprctl_version_text() {
  local answer
  command -v hyprctl >/dev/null 2>&1 || return 1
  # Without a running instance hyprctl fails; the caller falls back to the binary.
  answer="$(hyprctl -j version 2>/dev/null)" || return 1
  answer="$(printf '%s\n' "$answer" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1)"
  # An answer without a version field counts as unavailable.
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# zoomctl_detect_hyprland_version — the Hyprland version, from the session or the binary.
# Args:    none
# Returns: 0 found; 1 unknown; stdout: for example 0.56.2
# Globals: reads ZOOMCTL_HYPRLAND_BINARY (default Hyprland)
zoomctl_detect_hyprland_version() {
  local binary="${ZOOMCTL_HYPRLAND_BINARY:-Hyprland}" answer
  zoomctl_hyprctl_version_text && return 0
  # No session (pacman hook, TTY): the installed binary knows its release as well.
  command -v "$binary" >/dev/null 2>&1 || return 1
  answer="$("$binary" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)"
  # Anything without a version number counts as unknown.
  [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

# zoomctl_hyprland_supports_lua — test whether a Hyprland release has the Lua config manager.
# Args:    $1 version such as 0.56.2
# Returns: 0 new enough; 1 older or not a version
# Globals: reads ZOOMCTL_MIN_LUA_HYPRLAND_MAJOR, ZOOMCTL_MIN_LUA_HYPRLAND_MINOR
zoomctl_hyprland_supports_lua() {
  local major minor
  # Only the first two components matter for the threshold.
  IFS=. read -r major minor _ <<< "$1"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  # A newer major wins at once; the same major needs the minimum minor.
  (( 10#$major > ZOOMCTL_MIN_LUA_HYPRLAND_MAJOR ||
    (10#$major == ZOOMCTL_MIN_LUA_HYPRLAND_MAJOR && 10#$minor >= ZOOMCTL_MIN_LUA_HYPRLAND_MINOR) ))
}

# zoomctl_trailing_return_index — find the top-level `return` that ends a Lua file.
# Args:    $1.. the lines of the file
# Returns: 0 always; stdout: zero-based index of that line, or the line count when there is none
# Globals: none
zoomctl_trailing_return_index() {
  local line_count="$#" index candidate=-1
  local -a lines=("$@")
  # The last unindented `return` is the file's own, as long as no block closer follows it.
  for ((index = 0; index < line_count; index++)); do
    [[ "${lines[index]}" =~ ^return([^A-Za-z0-9_]|$) ]] && candidate="$index"
  done
  # A function body with an unindented return is closed by `end`; that is not top level.
  for ((index = candidate + 1; candidate >= 0 && index < line_count; index++)); do
    [[ "${lines[index]}" =~ ^[[:space:]]*(--.*)?$ ]] && continue
    # A block closer right after it means the return belongs to a function.
    [[ "${lines[index]}" =~ ^[[:space:]]*(end|else|elseif|until)([^A-Za-z0-9_]|$) ]] &&
      candidate=-1
    break
  done
  # No candidate means the file has no top-level return: append at the end.
  (( candidate >= 0 )) && printf '%s\n' "$candidate" || printf '%s\n' "$line_count"
}

# zoomctl_render_lua_config — print a Lua config with exactly one engine include.
# Args:    $1 config file
# Returns: 0 rendered; 1 the file cannot be read; stdout: the new content
# Globals: reads ZOOMCTL_SHARE_DIR
# Notes:   0.1 and package lines are upgraded in place, a user's custom engine path stays and
#          prevents a second load, a missing include goes before a trailing `return`.
zoomctl_render_lua_config() {
  # Per-line state: its kind, where the include goes, whether the engine line was printed.
  local line kind index engine_line insert_index=-1 engine_emitted=0
  local custom_present=0 managed_present=0
  local -a lines=()
  # The whole file is read first: a trailing `return` needs the position of the end.
  mapfile -t lines < "$1" || return 1
  engine_line="$(zoomctl_engine_include_line)"
  # One scan tells whether the engine is wired by the user or by us already.
  zoomctl_file_has_line_where "$1" zoomctl_is_custom_engine_line && custom_present=1
  zoomctl_file_has_line_where "$1" zoomctl_is_managed_lua_line && managed_present=1
  # Nothing wired yet: the include goes before a trailing `return`, else at the end.
  (( custom_present + managed_present == 0 )) &&
    insert_index="$(zoomctl_trailing_return_index "${lines[@]}")"
  for ((index = 0; index <= ${#lines[@]}; index++)); do
    # One extra pass past the last line lets the include be appended at the very end.
    [ "$index" -ne "$insert_index" ] || printf '%s\n' "$engine_line"
    [ "$index" -lt "${#lines[@]}" ] || break
    # Only the managed kinds are rewritten; everything else passes through.
    line="${lines[index]}"
    kind="$(zoomctl_lua_line_kind "$line")"
    # Managed kinds are replaced or dropped, everything else passes through.
    case "$kind" in
      engine-own|engine-package|legacy-include)
        # Duplicates and leftovers vanish; the first managed line is kept or upgraded in place.
        (( custom_present || engine_emitted )) && continue
        engine_emitted=1
        # An own line keeps its comment; package and 0.1 lines become the engine line.
        [ "$kind" = 'engine-own' ] || line="$engine_line"
        printf '%s\n' "$line" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# zoomctl_validate_lua_draft — let luac refuse a draft that would not parse.
# Args:    $1 draft file
# Returns: 0 parses or luac is not installed; 1 syntax error (message on stderr)
# Globals: none
zoomctl_validate_lua_draft() {
  local problem
  # Without luac nothing can be checked; the trailing-return rule covers the usual trap.
  command -v luac >/dev/null 2>&1 || return 0
  problem="$(luac -p "$1" 2>&1)" && return 0
  zoomctl_wiring_fail "the edited Lua config would not parse, left untouched: $problem"
}

# zoomctl_create_config — create a missing config file that holds one include line.
# Args:    $1 file; $2 the include line
# Returns: 0 created; 1 failed (message on stderr)
# Globals: none
zoomctl_create_config() {
  local draft_file
  zoomctl_refuse_root_symlink "$1" || return 1
  # A missing ~/.config/hypr is created (owned by the user when running as root).
  zoomctl_mkdir_owned "$(dirname -- "$1")" || return 1
  draft_file="$(zoomctl_new_draft "$1")" || return 1
  # A fresh dotfile is world-readable like the rest of ~/.config (never world-writable).
  printf '%s\n' "$2" > "$draft_file" || { rm -f -- "$draft_file"; return 1; }
  zoomctl_replace_file "$draft_file" "$1" 644 || { rm -f -- "$draft_file"; return 1; }
  printf 'zoomctl: created %s\n' "$1"
}

# zoomctl_same_content — tell whether two files hold exactly the same bytes.
# Args:    $1 first file; $2 second file
# Returns: 0 identical; 1 different or unreadable
# Globals: none
# Notes:   sha256sum (coreutils) instead of cmp: diffutils is not part of Arch's base set
#          and was missing on the CI container, which made every unchanged file look changed.
zoomctl_same_content() {
  local first_sum second_sum
  # Only the checksum column matters; the file name column differs by definition.
  first_sum="$(sha256sum < "$1" 2>/dev/null)" || return 1
  # The second file is hashed the same way, from stdin.
  second_sum="$(sha256sum < "$2" 2>/dev/null)" || return 1
  # Equal checksums mean equal content for every practical purpose.
  [ "$first_sum" = "$second_sum" ]
}

# zoomctl_wire_lua_config — make an existing hyprland.lua load the engine exactly once.
# Args:    $1 path of hyprland.lua (a file or a symlink to one)
# Returns: 0 done or already wired; 1 failed (message on stderr, file untouched)
# Globals: none
zoomctl_wire_lua_config() {
  local config_file="$1" draft_file
  # As root, links in the user's directory are never followed.
  zoomctl_refuse_root_symlink "$config_file" || return 1
  draft_file="$(zoomctl_new_draft "$config_file")" || return 1
  # The draft is built beside the original for an atomic swap.
  zoomctl_render_lua_config "$config_file" > "$draft_file" ||
    { rm -f -- "$draft_file"; zoomctl_wiring_fail "cannot read $config_file"; return 1; }
  # Identical output means nothing to do, and no backup clutter either.
  if zoomctl_same_content "$draft_file" "$config_file"; then
    rm -f -- "$draft_file"
    # Say so instead of staying silent.
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    return 0
  fi
  zoomctl_commit_draft "$draft_file" "$config_file" zoomctl_validate_lua_draft || return 1
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
  # Our include goes last.
  zoomctl_conf_include_line
}

# zoomctl_ensure_conf_include — append the hyprlang include line to an existing hyprland.conf.
# Args:    $1 path of hyprland.conf (a file or a symlink to one)
# Returns: 0 done or already present; 1 failed (message on stderr)
# Globals: none
zoomctl_ensure_conf_include() {
  local config_file="$1" draft_file
  zoomctl_refuse_root_symlink "$config_file" || return 1
  # Any form of the include counts as present.
  if zoomctl_file_has_line_where "$config_file" zoomctl_is_conf_include_line; then
    printf 'zoomctl: Hyprland include already present in %s\n' "$config_file"
    return 0
  fi
  # The draft sits beside the original (symlinks resolved) for an atomic swap.
  draft_file="$(zoomctl_new_draft "$config_file")" || return 1
  # Copy the file; the line reader below re-terminates an unterminated last line.
  zoomctl_render_conf_config "$config_file" > "$draft_file" ||
    { rm -f -- "$draft_file"; zoomctl_wiring_fail "cannot read $config_file"; return 1; }
  zoomctl_commit_draft "$draft_file" "$config_file" || return 1
  # The announcement tells the user which file changed.
  printf 'zoomctl: added Hyprland include to %s\n' "$config_file"
}

# zoomctl_create_first_config — create the Hyprland config when the user has none yet.
# Args:    $1 path of hyprland.lua; $2 path of hyprland.conf
# Returns: 0 created; 1 failed (message on stderr)
# Globals: none
zoomctl_create_first_config() {
  local hyprland_version
  # Only a release with the Lua config manager reads hyprland.lua; older ones need the conf.
  if hyprland_version="$(zoomctl_detect_hyprland_version)" &&
    zoomctl_hyprland_supports_lua "$hyprland_version"; then
    # New enough: the Lua config is what Hyprland reads.
    zoomctl_create_config "$1" "$(zoomctl_engine_include_line)"
  else
    # Older or unknown: the legacy conf works everywhere.
    zoomctl_create_config "$2" "$(zoomctl_conf_include_line)"
  fi
}

# zoomctl_install_hyprland_include — wire the engine (Lua) or the legacy binds (hyprlang).
# Args:    none
# Returns: 0 done; 1 failed (the reason is on stderr)
# Globals: reads the target-home variables
zoomctl_install_hyprland_include() {
  # The two config files of the target user (they live side by side).
  local lua_config conf_config
  lua_config="$(zoomctl_hyprland_lua_config_file)" ||
    { zoomctl_wiring_fail "no usable home directory for the Hyprland config (set HOME)"; return 1; }
  # The legacy file always sits next to hyprland.lua.
  conf_config="$(zoomctl_hyprland_config_file)" || return 1
  # Hyprland 0.55+ uses hyprland.lua when it exists; keep a present hyprland.conf in sync too.
  if [ -f "$lua_config" ]; then
    zoomctl_wire_lua_config "$lua_config" || return 1
    # A present hyprland.conf is kept in sync as well (the legacy fallback of the same user).
    [ ! -f "$conf_config" ] || zoomctl_ensure_conf_include "$conf_config"
  elif [ -f "$conf_config" ]; then
    zoomctl_ensure_conf_include "$conf_config"
  else
    # No config at all: create the one the installed release reads.
    zoomctl_create_first_config "$lua_config" "$conf_config"
  fi
}

# zoomctl_remove_matching_lines — delete the lines a predicate accepts; drop an emptied file.
# Args:    $1 config file; $2 name of a predicate function taking one line
# Returns: 0 done or nothing to remove; 1 failed (message on stderr)
# Globals: none
zoomctl_remove_matching_lines() {
  local line draft_file removed=0
  # Nothing to remove from a missing file.
  [ -f "$1" ] || return 0
  zoomctl_refuse_root_symlink "$1" || return 1
  draft_file="$(zoomctl_new_draft "$1")" || return 1
  # Copy every line the predicate does not claim.
  while IFS= read -r line || [ -n "$line" ]; do
    if "$2" "$line"; then removed=1; else printf '%s\n' "$line"; fi
  done < "$1" > "$draft_file"
  # Nothing of ours in the file: leave it untouched.
  [ "$removed" -eq 1 ] || { rm -f -- "$draft_file"; return 0; }
  # Keep the user's own lines; a file that held only ours is deleted (after a backup).
  if [ -s "$draft_file" ]; then
    zoomctl_commit_draft "$draft_file" "$1"
    return
  fi
  # Only our lines were in it: the file goes, after a backup.
  rm -f -- "$draft_file"
  zoomctl_backup_file "$1" && rm -f -- "$1"
}

# zoomctl_remove_hyprland_include — undo the wiring in both config files (engine and 0.1 lines).
# Args:    none
# Returns: 0 done; 1 a file could not be edited (the other one was still tried)
# Globals: reads the target-home variables
zoomctl_remove_hyprland_include() {
  local lua_config conf_config lua_status conf_status
  lua_config="$(zoomctl_hyprland_lua_config_file)" || return 0
  # The legacy file always sits next to hyprland.lua.
  conf_config="$(zoomctl_hyprland_config_file)" || return 0
  # Each file loses only the lines this tool wrote.
  zoomctl_remove_matching_lines "$lua_config" zoomctl_is_managed_lua_line
  lua_status=$?
  # The legacy conf is cleaned even when the Lua file failed.
  zoomctl_remove_matching_lines "$conf_config" zoomctl_is_conf_include_line
  conf_status=$?
  (( lua_status == 0 && conf_status == 0 ))
}

# ---- shared wiring block: end ----
