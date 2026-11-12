#!/usr/bin/env bash
# cmd_info.sh — the informational and housekeeping commands: help, version, status, ui, uninstall.

# zoomctl_usage_text — the grouped help text.
# Args:    none
# Returns: 0 always; stdout: help
# Globals: none
zoomctl_usage_text() {
  cat <<'EOF'
Usage: zoomctl <command> [arguments]

Zoom:
  in [n]            zoom in by n steps (default 1)
  out [n]           zoom out by n steps
  zoom <factor> [--transient]
                    jump to a zoom factor from 1.00 to 10.00 (--transient: the toggle
                    keeps its remembered level, for tests)
  toggle            switch between the reset zoom and the last zoom level
  reset             go back to the reset zoom
  filter [name]     color filter: on, off, toggle (default) or a filter name
  tracking <mode>   how the view follows the pointer: centered, edge, margin, follow

Settings:
  set <key> <value> [<key> <value>...]
                    validate, save and apply settings in one step (e.g. set step 0.15)
  get <key>         print the effective value of one setting
  unset <key>       drop your override of one setting
  reset-config      drop all of your overrides
  config            show the effective configuration
                    (--porcelain: KEY=VALUE lines, --template: commented defaults)
  preview K=V...    try settings live without saving; `preview --end` undoes it
  edit-config       open your config file in $EDITOR
  ui                open the settings window (alias: configure)

Maintenance:
  status            show the current zoom state (--porcelain for scripts)
  doctor            check the installation and the Hyprland wiring
  setup             add hyprland-zoom to your Hyprland config (safe to repeat)
  uninstall         remove the package (asks first; --yes skips the question)
  version, help

Exit status: 0 success, 1 error, 2 wrong usage.
EOF
}

# zoomctl_command_help — print the help text.
# Args:    none
# Returns: 0 always
# Globals: none
zoomctl_command_help() {
  zoomctl_usage_text
}

# zoomctl_command_version — print the package version.
# Args:    none
# Returns: 0 always; stdout: "zoomctl <version>"
# Globals: reads the VERSION file through zoomctl_version
zoomctl_command_version() {
  printf 'zoomctl %s\n' "$(zoomctl_version)"
}

# zoomctl_command_status — print the zoom status.
# Args:    $1 optional --porcelain
# Returns: 0 done; 1 failed; 2 usage error
# Globals: none
zoomctl_command_status() {
  [ "$#" -le 1 ] || { zoomctl_usage_error "status takes at most one option"; return 2; }
  # Porcelain is the machine-readable C6 form; anything else is a usage error.
  case "${1:-}" in
    '') zoomctl_status_human ;;
    --porcelain) zoomctl_status_porcelain ;;
    # Anything else is a usage error.
    *) zoomctl_usage_error "unknown option '$1' for status" ;;
  esac
}

# zoomctl_command_setup — wire hyprland-zoom into the Hyprland config.
# Args:    none
# Returns: 0 done; 1 failed (the wiring functions print the real cause); 2 usage error
# Globals: none
zoomctl_command_setup() {
  [ "$#" -eq 0 ] || { zoomctl_usage_error "setup takes no arguments"; return 2; }
  # The wiring functions print what they did and, on failure, exactly why.
  zoomctl_install_hyprland_include
}

# zoomctl_find_settings_app — locate the settings app (override, installed, or in the checkout).
# Args:    none
# Returns: 0 found; 1 not found; stdout: path or command name
# Globals: reads ZOOMCTL_SETTINGS_BIN, ZOOMCTL_SCRIPT_DIR
# Notes:   ZOOMCTL_SETTINGS_BIN, when set, is the only candidate (tests and packagers use it).
zoomctl_find_settings_app() {
  # An explicit path is authoritative: a wrong one must not silently fall through to another app.
  if [ -n "${ZOOMCTL_SETTINGS_BIN:-}" ]; then
    [ -x "$ZOOMCTL_SETTINGS_BIN" ] && printf '%s\n' "$ZOOMCTL_SETTINGS_BIN"
    return
  fi
  # An installed app on PATH wins; the checkout copy serves developers.
  command -v hyprland-zoom-settings && return 0
  [ -x "${ZOOMCTL_SCRIPT_DIR:-.}/ui/hyprland-zoom-settings" ] || return 1
  printf '%s\n' "${ZOOMCTL_SCRIPT_DIR:-.}/ui/hyprland-zoom-settings"
}

# zoomctl_command_ui — start the settings window.
# Args:    arguments passed through to the app
# Returns: does not return on success (exec); 1 when the app is missing
# Globals: none
zoomctl_command_ui() {
  local settings_app
  settings_app="$(zoomctl_find_settings_app)" || {
    # A clear hint beats a bare 'command not found' when the app is absent.
    zoomctl_error "hyprland-zoom-settings is not installed (it needs python-gobject and libadwaita)"
    return 1
  }
  # The window needs the caller's UTF-8 locale; zoomctl's byte-wise one is for validation only.
  zoomctl_restore_locale
  exec "$settings_app" "$@"
}

# zoomctl_run_privileged — run a command as root through sudo, doas or pkexec.
# Args:    $1.. command and arguments
# Returns: the command's status; 1 when no privilege helper exists
# Globals: none
zoomctl_run_privileged() {
  local helper
  # Already root: no helper needed.
  [ "$(id -u)" = '0' ] && { "$@"; return; }
  # First helper that exists wins.
  for helper in sudo doas pkexec; do
    command -v "$helper" >/dev/null 2>&1 && { "$helper" "$@"; return; }
  done
  zoomctl_error "uninstall needs sudo, doas or pkexec"
}

# zoomctl_command_uninstall — remove the package after confirmation.
# Args:    $1 optional --yes to skip the question
# Returns: 0 removed or cancelled; 1 failed; 2 usage error
# Globals: none
zoomctl_command_uninstall() {
  local answer='n'
  [ "$#" -le 1 ] || { zoomctl_usage_error "uninstall takes at most --yes"; return 2; }
  # The question is skipped only on explicit request.
  if [ "${1:-}" = '--yes' ]; then
    answer='y'
  elif [ -t 0 ]; then
    # Ask only on a terminal; scripts must pass --yes explicitly.
    read -r -p 'Remove the hyprland-zoom package? [y/N] ' answer
  fi
  case "${answer,,}" in
    y|yes) zoomctl_run_privileged pacman -Rs hyprland-zoom ;;
    # Any other answer, including no terminal at all, cancels.
    *) printf 'zoomctl: uninstall cancelled\n' ;;
  esac
}
