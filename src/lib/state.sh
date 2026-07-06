#!/usr/bin/env bash

zoomctl_state_directory() {
  if [ -n "${ZOOMCTL_STATE_DIR:-}" ]; then
    printf '%s\n' "$ZOOMCTL_STATE_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    printf '%s/zoomctl\n' "$XDG_RUNTIME_DIR"
  else
    printf '/run/user/%s/zoomctl\n' "$(id -u)"
  fi
}

zoomctl_state_file() {
  printf '%s/last_zoom\n' "$(zoomctl_state_directory)"
}

zoomctl_state_ensure_directory() {
  local state_directory
  state_directory="$(zoomctl_state_directory)"

  mkdir -p "$state_directory"
  chmod 700 "$state_directory" 2>/dev/null || true
}

zoomctl_state_save() {
  local state_file
  state_file="$(zoomctl_state_file)"

  zoomctl_state_ensure_directory
  zoomctl_format_float "$1" > "$state_file"
}

zoomctl_state_read() {
  local state_file
  local state_value

  state_file="$(zoomctl_state_file)"
  [ -r "$state_file" ] || return 1

  state_value="$(tr -d '[:space:]' < "$state_file")"
  zoomctl_is_float "$state_value" || return 1

  printf '%s\n' "$state_value"
}

zoomctl_state_clear() {
  rm -f "$(zoomctl_state_file)"
}