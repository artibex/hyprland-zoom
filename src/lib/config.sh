#!/usr/bin/env bash
# config.sh — layered configuration (contract C2): schema defaults <- system <- user.
# Invalid input never aborts: bad values and keys are reported and the next layer wins.

# Effective value and origin layer (default|system|user) per schema key.
declare -gA ZOOMCTL_VALUE=() ZOOMCTL_SOURCE=()

# zoomctl_system_config_file — print the system config path.
# Args:    none
# Returns: 0 always; stdout: path
# Globals: reads ZOOMCTL_SYSTEM_CONFIG
zoomctl_system_config_file() {
  # /etc/zoomctl.conf unless a test redirects it.
  printf '%s\n' "${ZOOMCTL_SYSTEM_CONFIG:-/etc/zoomctl.conf}"
}

# zoomctl_user_config_file — print the per-user config path.
# Args:    none
# Returns: 0 always; stdout: path
# Globals: reads ZOOMCTL_USER_CONFIG, XDG_CONFIG_HOME, HOME
zoomctl_user_config_file() {
  # An explicit override beats the XDG location.
  printf '%s\n' "${ZOOMCTL_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zoomctl/zoom.conf}"
}

# zoomctl_config_parse_file — read KEY=VALUE lines of one file into a raw map.
# Args:    $1 file; $2 name of an associative array to fill (last assignment wins)
# Returns: 0 always (a missing file is an empty layer); stderr: warnings for bad lines
# Globals: none
zoomctl_config_parse_file() {
  local config_file="$1"
  local -n raw_map_ref="$2"
  local line key value line_number=0
  [ -r "$config_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    # Tolerate CRLF files and surrounding blanks.
    line="${line%$'\r'}"
    zoomctl_trim_var line
    # Blank lines and comments carry no setting.
    case "$line" in ''|'#'*) continue ;; esac
    if [[ "$line" != *=* ]]; then
      zoomctl_warn "$config_file:$line_number: ignoring line without '='"
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    zoomctl_trim_var key
    zoomctl_trim_var value
    # Keys become map subscripts, so only plain identifiers are allowed.
    if [[ ! "$key" =~ ^[A-Za-z0-9_]+$ ]]; then
      zoomctl_warn "$config_file:$line_number: ignoring malformed key"
      continue
    fi
    # One pair of matching quotes around the value is optional.
    [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
    raw_map_ref[$key]="$value"
  done < "$config_file"
}

# zoomctl_config_apply_compat — translate the 0.1 keys of one layer in place (C2).
# Args:    $1 file (for messages); $2 name of the raw map to rewrite
# Returns: 0 always
# Globals: none
zoomctl_config_apply_compat() {
  local config_file="$1"
  local -n compat_map_ref="$2"
  local tracking_mode
  # Only 0.1 files carry ZOOM_CENTER_CURSOR.
  [ -n "${compat_map_ref[ZOOM_CENTER_CURSOR]+set}" ] || return 0
  # An explicit ZOOM_TRACKING wins over the old switch.
  if [ -z "${compat_map_ref[ZOOM_TRACKING]+set}" ]; then
    if tracking_mode="$(zoomctl_config_legacy_tracking "${compat_map_ref[ZOOM_CENTER_CURSOR]}")"; then
      compat_map_ref[ZOOM_TRACKING]="$tracking_mode"
    else
      zoomctl_warn "$config_file: invalid ZOOM_CENTER_CURSOR ignored"
    fi
  fi
  # 0.1 steps were additive, so the layer keeps its meaning with step mode add.
  [ -n "${compat_map_ref[ZOOM_STEP_MODE]+set}" ] || compat_map_ref[ZOOM_STEP_MODE]='add'
  unset 'compat_map_ref[ZOOM_CENTER_CURSOR]'
}

# zoomctl_config_legacy_tracking — map the 0.1 on/off cursor switch to a tracking mode.
# Args:    $1 0.1 value (1/0/on/off/...)
# Returns: 0 valid; 1 not a boolean; stdout: centered (on) or edge (off)
# Globals: none
zoomctl_config_legacy_tracking() {
  local switch_state
  switch_state="$(zoomctl_validate_bool "$1")" || return 1
  # centered kept the cursor in the middle; edge was the 0.1 default behaviour.
  [ "$switch_state" = 'on' ] && printf 'centered\n' || printf 'edge\n'
}

# zoomctl_config_read_layer — parse, translate and validate one config file.
# Args:    $1 file; $2 name of an associative array that receives canonical values
# Returns: 0 always; stderr: warnings for unknown keys and invalid values
# Globals: reads the ZOOMCTL_SCHEMA_* tables
zoomctl_config_read_layer() {
  local config_file="$1"
  local -n layer_map_ref="$2"
  local -A raw_values=()
  local key canonical_value
  layer_map_ref=()
  [ -r "$config_file" ] || return 0
  zoomctl_config_parse_file "$config_file" raw_values
  zoomctl_config_apply_compat "$config_file" raw_values
  # Schema order keeps warnings deterministic.
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    [ -n "${raw_values[$key]+set}" ] || continue
    if canonical_value="$(zoomctl_schema_validate "$key" "${raw_values[$key]}")"; then
      layer_map_ref[$key]="$canonical_value"
    else
      zoomctl_warn "$config_file: invalid value '${raw_values[$key]}' for $key ignored"
    fi
    unset 'raw_values[$key]'
  done
  # Whatever is left is not in the schema.
  for key in "${!raw_values[@]}"; do
    zoomctl_warn "$config_file: unknown setting $key ignored"
  done
}

# zoomctl_config_layer_bounds_check — test MIN <= RESET <= MAX for the effective config plus a layer.
# Args:    $1 name of a layer map (canonical values)
# Returns: 0 rule holds, no output; 1 violated; stdout: the violated rule with the values
# Globals: reads ZOOMCTL_VALUE
zoomctl_config_layer_bounds_check() {
  local -n candidate_layer_ref="$1"
  local minimum="${candidate_layer_ref[ZOOM_MIN]:-${ZOOMCTL_VALUE[ZOOM_MIN]}}"
  local reset="${candidate_layer_ref[ZOOM_RESET]:-${ZOOMCTL_VALUE[ZOOM_RESET]}}"
  local maximum="${candidate_layer_ref[ZOOM_MAX]:-${ZOOMCTL_VALUE[ZOOM_MAX]}}"
  # A layer value overrides the effective one, missing keys keep it.
  zoomctl_bounds_ok "$minimum" "$reset" "$maximum" && return 0
  zoomctl_bounds_message "$minimum" "$reset" "$maximum"
  return 1
}

# zoomctl_config_apply_layer — merge one config file over the effective values.
# Args:    $1 file; $2 layer name (system|user)
# Returns: 0 always; stderr: warnings
# Globals: reads/writes ZOOMCTL_VALUE, ZOOMCTL_SOURCE
zoomctl_config_apply_layer() {
  local config_file="$1"
  local layer_name="$2"
  local -A layer_values=()
  local key bounds_problem
  zoomctl_config_read_layer "$config_file" layer_values
  # A layer that breaks MIN <= RESET <= MAX loses those three keys, not the whole file.
  if ! bounds_problem="$(zoomctl_config_layer_bounds_check layer_values)"; then
    zoomctl_warn "$config_file: $bounds_problem; ignoring the zoom bounds of this file"
    unset 'layer_values[ZOOM_MIN]' 'layer_values[ZOOM_RESET]' 'layer_values[ZOOM_MAX]'
  fi
  # What survived overrides the lower layers.
  for key in "${!layer_values[@]}"; do
    ZOOMCTL_VALUE[$key]="${layer_values[$key]}"
    ZOOMCTL_SOURCE[$key]="$layer_name"
  done
}

# zoomctl_config_load — compute the effective configuration.
# Args:    $1 optional "base" to stop before the user layer
# Returns: 0 loaded; 1 schema unavailable
# Globals: writes ZOOMCTL_VALUE, ZOOMCTL_SOURCE
zoomctl_config_load() {
  local key
  zoomctl_schema_load || return 1
  ZOOMCTL_VALUE=()
  ZOOMCTL_SOURCE=()
  # Layer 0: schema defaults (trusted, pinned by a test).
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    ZOOMCTL_VALUE[$key]="${ZOOMCTL_SCHEMA_DEFAULT[$key]}"
    ZOOMCTL_SOURCE[$key]='default'
  done
  zoomctl_config_apply_layer "$(zoomctl_system_config_file)" system
  [ "${1:-}" = 'base' ] && return 0
  zoomctl_config_apply_layer "$(zoomctl_user_config_file)" user
}

# zoomctl_config_porcelain — print every key as KEY=VALUE in schema order (C4).
# Args:    none (config must be loaded)
# Returns: 0 always; stdout: one line per schema key
# Globals: reads ZOOMCTL_SCHEMA_KEYS, ZOOMCTL_VALUE
zoomctl_config_porcelain() {
  local key
  # Schema order is the contract for machine readers.
  for key in "${ZOOMCTL_SCHEMA_KEYS[@]}"; do
    printf '%s=%s\n' "$key" "${ZOOMCTL_VALUE[$key]}"
  done
}
