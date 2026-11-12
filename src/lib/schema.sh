#!/usr/bin/env bash
# schema.sh — load config/settings.schema (contract C1) into bash tables.
# The schema is the only source of keys, types, defaults, ranges and labels (E3).

# Ordered list of schema keys (schema order is the canonical order everywhere).
declare -ga ZOOMCTL_SCHEMA_KEYS=()
# Per-key attributes, indexed by key.
declare -gA ZOOMCTL_SCHEMA_TYPE=() ZOOMCTL_SCHEMA_DEFAULT=() ZOOMCTL_SCHEMA_CONSTRAINT=()
declare -gA ZOOMCTL_SCHEMA_GROUP=() ZOOMCTL_SCHEMA_LABEL=() ZOOMCTL_SCHEMA_HELP=()
# CLI alias (normalised spelling) to canonical key.
declare -gA ZOOMCTL_SCHEMA_ALIAS=()
# Set to 1 once the schema file has been parsed.
ZOOMCTL_SCHEMA_LOADED=''

# zoomctl_schema_file — locate settings.schema in the share dir or the repository checkout.
# Args:    none
# Returns: 0 found; 1 not found; stdout: path of the schema file
# Globals: reads ZOOMCTL_SCHEMA_FILE (test override), ZOOMCTL_SCRIPT_DIR
zoomctl_schema_file() {
  local candidate
  # Candidates in priority order: explicit override, packaged, checkout.
  for candidate in \
    "${ZOOMCTL_SCHEMA_FILE:-}" \
    "$(zoomctl_share_dir)/settings.schema" \
    "${ZOOMCTL_SCRIPT_DIR:-.}/../config/settings.schema"; do
    # The first readable candidate wins.
    [ -n "$candidate" ] && [ -r "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  zoomctl_error "settings.schema not found (looked in $(zoomctl_share_dir) and the checkout)"
}

# zoomctl_schema_register_aliases — add the CLI spellings of one key to the alias table.
# Args:    $1 canonical key
# Returns: 0 always
# Globals: writes ZOOMCTL_SCHEMA_ALIAS
zoomctl_schema_register_aliases() {
  local key="$1"
  local hyphenated="${key,,}"
  # ZOOM_STEP -> zoom-step, plus the short form without the ZOOM_ prefix (C1).
  hyphenated="${hyphenated//_/-}"
  ZOOMCTL_SCHEMA_ALIAS[$hyphenated]="$key"
  ZOOMCTL_SCHEMA_ALIAS[${hyphenated#zoom-}]="$key"
}

# zoomctl_schema_register_legacy_aliases — add the 0.1 spellings (contract C1/C2).
# Args:    none
# Returns: 0 always
# Globals: writes ZOOMCTL_SCHEMA_ALIAS
zoomctl_schema_register_legacy_aliases() {
  local alias_name
  # 0.1 spelled these out in full.
  ZOOMCTL_SCHEMA_ALIAS[minimum]='ZOOM_MIN'
  ZOOMCTL_SCHEMA_ALIAS[maximum]='ZOOM_MAX'
  # 0.1 "center-cursor" is now the tracking mode (see zoomctl_config_legacy_value).
  for alias_name in center-cursor center cursor; do
    ZOOMCTL_SCHEMA_ALIAS[$alias_name]='ZOOM_TRACKING'
  done
}

# zoomctl_schema_parse_line — store one schema line in the tables.
# Args:    $1 line number (for messages); $2 raw schema line
# Returns: 0 stored or skipped (comment/blank); 1 malformed line
# Globals: writes the ZOOMCTL_SCHEMA_* tables
zoomctl_schema_parse_line() {
  local key type default_value constraint group label help
  # Fields are '|' separated; the last field keeps any further '|'.
  IFS='|' read -r key type default_value constraint group label help <<< "$2"
  # Blank lines and comments carry no setting.
  case "$key" in ''|'#'*) return 0 ;; esac
  # Every field except constraint and default may not be empty.
  if [ -z "$type" ] || [ -z "$group" ] || [ -z "$label" ] || [ -z "$help" ]; then
    zoomctl_error "settings.schema line $1 is malformed"
    return 1
  fi
  # Register the key and all of its attributes.
  ZOOMCTL_SCHEMA_KEYS+=("$key")
  ZOOMCTL_SCHEMA_TYPE[$key]="$type"
  ZOOMCTL_SCHEMA_DEFAULT[$key]="$default_value"
  ZOOMCTL_SCHEMA_CONSTRAINT[$key]="$constraint"
  ZOOMCTL_SCHEMA_GROUP[$key]="$group"
  ZOOMCTL_SCHEMA_LABEL[$key]="$label"
  ZOOMCTL_SCHEMA_HELP[$key]="$help"
  zoomctl_schema_register_aliases "$key"
}

# zoomctl_schema_load — parse the schema once per process.
# Args:    none
# Returns: 0 loaded; 1 schema missing or malformed
# Globals: writes the ZOOMCTL_SCHEMA_* tables and ZOOMCTL_SCHEMA_LOADED
zoomctl_schema_load() {
  local schema_file line line_number=0
  # Parsing is idempotent: later callers reuse the tables.
  [ -z "$ZOOMCTL_SCHEMA_LOADED" ] || return 0
  schema_file="$(zoomctl_schema_file)" || return 1
  # Read line by line so a malformed line reports its number.
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    zoomctl_schema_parse_line "$line_number" "$line" || return 1
  done < "$schema_file"
  # Short aliases must never shadow a canonical spelling, so legacy ones go last.
  zoomctl_schema_register_legacy_aliases
  ZOOMCTL_SCHEMA_LOADED=1
}

# zoomctl_schema_resolve_key — map a user-typed name to its canonical key.
# Args:    $1 name: KEY, zoom-step, step, bind_key_in, center-cursor, ...
# Returns: 0 known; 1 unknown; stdout: canonical key
# Globals: reads ZOOMCTL_SCHEMA_ALIAS
zoomctl_schema_resolve_key() {
  local normalised="${1,,}"
  # Underscores and hyphens are interchangeable, case does not matter.
  normalised="${normalised//_/-}"
  # An empty name would be an invalid array subscript.
  [ -n "$normalised" ] || return 1
  [ -n "${ZOOMCTL_SCHEMA_ALIAS[$normalised]+set}" ] || return 1
  printf '%s\n' "${ZOOMCTL_SCHEMA_ALIAS[$normalised]}"
}

# zoomctl_schema_validate — validate a value for a schema key.
# Args:    $1 canonical key; $2 value
# Returns: 0 valid; 1 invalid; stdout: canonical value
# Globals: reads ZOOMCTL_SCHEMA_TYPE, ZOOMCTL_SCHEMA_CONSTRAINT
zoomctl_schema_validate() {
  # The schema row decides the validator, nothing is hard-coded per key.
  zoomctl_validate_by_type "${ZOOMCTL_SCHEMA_TYPE[$1]}" "${ZOOMCTL_SCHEMA_CONSTRAINT[$1]}" "$2"
}

# zoomctl_schema_allowed_text — describe the accepted values of a key for humans.
# Args:    $1 canonical key
# Returns: 0 always; stdout: one short phrase (used in errors and the template)
# Globals: reads ZOOMCTL_SCHEMA_TYPE, ZOOMCTL_SCHEMA_CONSTRAINT
zoomctl_schema_allowed_text() {
  local constraint="${ZOOMCTL_SCHEMA_CONSTRAINT[$1]}"
  # One phrase per C1 type.
  case "${ZOOMCTL_SCHEMA_TYPE[$1]}" in
    float|int) printf 'a number from %s to %s\n' "${constraint%%..*}" "${constraint#*..}" ;;
    bool) printf 'on or off\n' ;;
    enum) printf 'one of: %s\n' "${constraint//,/, }" ;;
    key) printf 'a Hyprland key name such as I, F5 or mouse:274; empty disables the bind\n' ;;
    mods) printf 'modifiers joined with " + " from: SUPER, SHIFT, CTRL, ALT\n' ;;
  esac
}
