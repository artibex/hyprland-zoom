#!/usr/bin/env bash

zoomctl_config_defaults() {
  ZOOMCTL_STEP='0.10'
  ZOOMCTL_MIN='1.00'
  ZOOMCTL_MAX='10.00'
  ZOOMCTL_RESET='1.00'
  ZOOMCTL_CENTER_CURSOR='0'
  ZOOMCTL_STATE_DIR=''
  ZOOMCTL_CONFIG_FILE=''

  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    ZOOMCTL_STATE_DIR="$XDG_RUNTIME_DIR/zoomctl"
  else
    ZOOMCTL_STATE_DIR="/run/user/$(id -u)/zoomctl"
  fi

  if [ -z "${ZOOMCTL_CONFIG_FILE:-}" ]; then
    ZOOMCTL_CONFIG_FILE='/etc/zoomctl.conf'
  fi
}

zoomctl_config_apply_setting() {
  local key="$1"
  local value="$2"

  case "$key" in
    ZOOM_STEP) ZOOMCTL_STEP="$value" ;;
    ZOOM_MIN) ZOOMCTL_MIN="$value" ;;
    ZOOM_MAX) ZOOMCTL_MAX="$value" ;;
    ZOOM_RESET) ZOOMCTL_RESET="$value" ;;
    ZOOM_CENTER_CURSOR) ZOOMCTL_CENTER_CURSOR="$value" ;;
    ZOOMCTL_STATE_DIR) ZOOMCTL_STATE_DIR="$value" ;;
    ZOOMCTL_CONFIG_FILE) ZOOMCTL_CONFIG_FILE="$value" ;;
  esac
}

zoomctl_trim() {
  local value="$1"

  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s\n' "$value"
}

zoomctl_config_load_file() {
  local config_file="$1"
  local line
  local key
  local value

  [ -r "$config_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac

    case "$line" in
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        key="$(zoomctl_trim "$key")"
        value="$(zoomctl_trim "$value")"
        zoomctl_config_apply_setting "$key" "$value"
        ;;
    esac
  done < "$config_file"
}

zoomctl_config_validate() {
  if ! zoomctl_is_float "$ZOOMCTL_STEP"; then
    printf 'zoomctl: invalid ZOOM_STEP value, using 0.10\n' >&2
    ZOOMCTL_STEP='0.10'
  fi

  if ! zoomctl_is_float "$ZOOMCTL_MIN"; then
    printf 'zoomctl: invalid ZOOM_MIN value, using 1.00\n' >&2
    ZOOMCTL_MIN='1.00'
  fi

  if ! zoomctl_is_float "$ZOOMCTL_MAX"; then
    printf 'zoomctl: invalid ZOOM_MAX value, using 10.00\n' >&2
    ZOOMCTL_MAX='10.00'
  fi

  if ! zoomctl_is_float "$ZOOMCTL_RESET"; then
    printf 'zoomctl: invalid ZOOM_RESET value, using 1.00\n' >&2
    ZOOMCTL_RESET='1.00'
  fi

  case "$ZOOMCTL_CENTER_CURSOR" in
    0|1) ;;
    *)
      printf 'zoomctl: invalid ZOOM_CENTER_CURSOR value, using 0\n' >&2
      ZOOMCTL_CENTER_CURSOR='0'
      ;;
  esac

  if awk -v minimum="$ZOOMCTL_MIN" -v maximum="$ZOOMCTL_MAX" 'BEGIN { exit(!((minimum + 0) <= (maximum + 0))) }'; then
    :
  else
    printf 'zoomctl: ZOOM_MIN is greater than ZOOM_MAX, using defaults\n' >&2
    ZOOMCTL_MIN='1.00'
    ZOOMCTL_MAX='10.00'
  fi
}

zoomctl_config_load() {
  zoomctl_config_defaults

  if [ -n "${ZOOMCTL_CONFIG_FILE:-}" ] && [ -r "$ZOOMCTL_CONFIG_FILE" ]; then
    zoomctl_config_load_file "$ZOOMCTL_CONFIG_FILE"
  fi

  if [ -r "${XDG_CONFIG_HOME:-$HOME/.config}/zoomctl/zoom.conf" ]; then
    zoomctl_config_load_file "${XDG_CONFIG_HOME:-$HOME/.config}/zoomctl/zoom.conf"
  fi

  zoomctl_config_validate
}


# Maps the short, user-friendly names accepted by `zoomctl set`/`zoomctl get`
# onto the canonical ZOOM_* keys used in config files. Keeping this table in
# one place means adding a new setting only ever requires touching this file.
zoomctl_config_canonical_key() {
  case "$1" in
    step|zoom-step|ZOOM_STEP) printf 'ZOOM_STEP\n' ;;
    min|minimum|zoom-min|ZOOM_MIN) printf 'ZOOM_MIN\n' ;;
    max|maximum|zoom-max|ZOOM_MAX) printf 'ZOOM_MAX\n' ;;
    reset|zoom-reset|ZOOM_RESET) printf 'ZOOM_RESET\n' ;;
    center-cursor|center|cursor|ZOOM_CENTER_CURSOR) printf 'ZOOM_CENTER_CURSOR\n' ;;
    *) return 1 ;;
  esac
}

zoomctl_config_get() {
  case "$1" in
    ZOOM_STEP) printf '%s\n' "$ZOOMCTL_STEP" ;;
    ZOOM_MIN) printf '%s\n' "$ZOOMCTL_MIN" ;;
    ZOOM_MAX) printf '%s\n' "$ZOOMCTL_MAX" ;;
    ZOOM_RESET) printf '%s\n' "$ZOOMCTL_RESET" ;;
    ZOOM_CENTER_CURSOR) printf '%s\n' "$ZOOMCTL_CENTER_CURSOR" ;;
    *) return 1 ;;
  esac
}

# Accepts human-friendly boolean spellings for ZOOM_CENTER_CURSOR so
# `zoomctl set center-cursor on` works as well as the raw 0/1 config value.
zoomctl_normalize_bool() {
  case "$1" in
    1|on|On|ON|true|True|TRUE|yes|Yes|YES) printf '1\n' ;;
    0|off|Off|OFF|false|False|FALSE|no|No|NO) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Validates a single value for a single key, without touching any other
# setting or silently substituting a default - used by `zoomctl set` so a
# typo is reported immediately instead of being masked later.
zoomctl_config_validate_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    ZOOM_STEP|ZOOM_MIN|ZOOM_MAX|ZOOM_RESET)
      zoomctl_is_float "$value"
      ;;
    ZOOM_CENTER_CURSOR)
      case "$value" in
        0|1) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

zoomctl_config_summary() {
  cat <<EOF
ZOOM_STEP=$(zoomctl_config_get ZOOM_STEP)
ZOOM_MIN=$(zoomctl_config_get ZOOM_MIN)
ZOOM_MAX=$(zoomctl_config_get ZOOM_MAX)
ZOOM_RESET=$(zoomctl_config_get ZOOM_RESET)
ZOOM_CENTER_CURSOR=$(zoomctl_config_get ZOOM_CENTER_CURSOR)
ZOOM_STATE_DIR=$ZOOMCTL_STATE_DIR
ZOOMCTL_CONFIG_FILE=$ZOOMCTL_CONFIG_FILE
EOF
}