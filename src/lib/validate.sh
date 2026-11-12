#!/usr/bin/env bash
# validate.sh — per-type value validators for settings (contract C1).
# Every validator prints the canonical value on success, so callers get validation and
# normalisation in one step. Nothing that fails here may reach a config file or Lua code.

# Modifier names the Hyprland binds understand, in canonical output order.
ZOOMCTL_MODIFIER_ORDER=(SUPER SHIFT CTRL ALT)

# zoomctl_validate_float — validate a decimal against a "min..max" constraint.
# Args:    $1 constraint like 0.01..2.00; $2 value
# Returns: 0 valid; 1 not a number or out of range; stdout: canonical two decimals
# Globals: none
zoomctl_validate_float() {
  local constraint="$1"
  local value_centi minimum_centi maximum_centi
  # Compare in integer hundredths so no floating point is involved.
  value_centi="$(zoomctl_float_to_centi "$2")" || return 1
  minimum_centi="$(zoomctl_float_to_centi "${constraint%%..*}")" || return 1
  maximum_centi="$(zoomctl_float_to_centi "${constraint#*..}")" || return 1
  # The rounded value must lie inside the inclusive range.
  (( value_centi >= minimum_centi && value_centi <= maximum_centi )) || return 1
  zoomctl_centi_to_float "$value_centi"
}

# zoomctl_validate_int — validate an integer against a "min..max" constraint.
# Args:    $1 constraint like 0..300; $2 value
# Returns: 0 valid; 1 not an integer or out of range; stdout: canonical integer
# Globals: none
zoomctl_validate_int() {
  local constraint="$1"
  local value="$2"
  local number
  # Only plain decimal integers; the digit limit prevents arithmetic overflow.
  [[ "$value" =~ ^-?[0-9]{1,9}$ ]] || return 1
  # Force base 10 so a leading zero is not read as octal.
  number=$((10#${value#-}))
  [[ "$value" == -* ]] && number=$((-number))
  # Inclusive range check, then print without leading zeros.
  (( number >= ${constraint%%..*} && number <= ${constraint#*..} )) || return 1
  printf '%s\n' "$number"
}

# zoomctl_validate_bool — normalise the accepted boolean spellings to on/off.
# Args:    $1 value (on/off/1/0/true/false/yes/no, any case)
# Returns: 0 valid; 1 not a boolean; stdout: on or off
# Globals: none
zoomctl_validate_bool() {
  local lowered="${1,,}"
  # Truthy spellings first, falsy second, everything else is rejected.
  case "$lowered" in
    on|1|true|yes) printf 'on\n' ;;
    off|0|false|no) printf 'off\n' ;;
    *) return 1 ;;
  esac
}

# zoomctl_validate_enum — accept one member of a comma separated list, case-insensitive.
# Args:    $1 constraint like a,b,c; $2 value
# Returns: 0 valid; 1 not a member; stdout: the member as spelled in the constraint
# Globals: none
zoomctl_validate_enum() {
  local -a members
  local member
  # Split the constraint into its members.
  IFS=',' read -ra members <<< "$1"
  # Return the schema's spelling so stored values stay canonical.
  for member in "${members[@]}"; do
    [ "$member" = "${2,,}" ] && { printf '%s\n' "$member"; return 0; }
  done
  return 1
}

# zoomctl_validate_key — validate a Hyprland key name; empty means "bind disabled".
# Args:    $1 key name
# Returns: 0 valid; 1 invalid; stdout: canonical key (single letters upper-case)
# Globals: none
zoomctl_validate_key() {
  local key_name="$1"
  # Empty disables the bind and is valid by contract.
  [ -n "$key_name" ] || { printf '\n'; return 0; }
  # The character set is safe inside a Lua string and a hyprlang bind line.
  [[ "$key_name" =~ ^[A-Za-z0-9_:.-]{1,32}$ ]] || return 1
  # Letters are case-insensitive in Hyprland; store them upper-case.
  [ "${#key_name}" -eq 1 ] && key_name="${key_name^^}"
  printf '%s\n' "$key_name"
}

# zoomctl_validate_mods — validate a modifier list and render it as "A + B".
# Args:    $1 modifiers separated by +, comma or blanks (case-insensitive, CONTROL=CTRL)
# Returns: 0 valid (1-4 distinct known modifiers); 1 invalid; stdout: canonical list
# Globals: reads ZOOMCTL_MODIFIER_ORDER
zoomctl_validate_mods() {
  local normalised="${1^^}"
  local -a words=()
  local -A seen=()
  local word modifier
  local -a ordered=()
  # Treat plus and comma like blanks, then split into words.
  normalised="${normalised//[+,]/ }"
  read -ra words <<< "$normalised"
  # Every word must be a known modifier (CONTROL is an alias of CTRL).
  for word in "${words[@]}"; do
    [ "$word" = 'CONTROL' ] && word='CTRL'
    # The case pattern is the whitelist: nothing else may become a map key.
    case "$word" in
      SUPER|SHIFT|CTRL|ALT) seen[$word]=1 ;;
      *) return 1 ;;
    esac
  done
  # At least one modifier, otherwise a bare scroll would hijack the wheel.
  [ "${#seen[@]}" -gt 0 ] || return 1
  # Emit in canonical order, deduplicated.
  for modifier in "${ZOOMCTL_MODIFIER_ORDER[@]}"; do
    [ -n "${seen[$modifier]+set}" ] && ordered+=("$modifier")
  done
  zoomctl_join_by ' + ' "${ordered[@]}"
}

# zoomctl_validate_by_type — dispatch a value to the validator of its schema type.
# Args:    $1 type; $2 constraint; $3 value
# Returns: 0 valid; 1 invalid or unknown type; stdout: canonical value
# Globals: none
zoomctl_validate_by_type() {
  # One arm per C1 type; the constraint only matters for ranged and enum types.
  case "$1" in
    float) zoomctl_validate_float "$2" "$3" ;;
    int) zoomctl_validate_int "$2" "$3" ;;
    bool) zoomctl_validate_bool "$3" ;;
    enum) zoomctl_validate_enum "$2" "$3" ;;
    key) zoomctl_validate_key "$3" ;;
    mods) zoomctl_validate_mods "$3" ;;
    *) return 1 ;;
  esac
}

# zoomctl_bounds_ok — check the cross-field rule ZOOM_MIN <= ZOOM_RESET <= ZOOM_MAX.
# Args:    $1 minimum; $2 reset; $3 maximum (decimal texts)
# Returns: 0 rule holds; 1 rule violated or a value is not a number
# Globals: none
zoomctl_bounds_ok() {
  local minimum_centi reset_centi maximum_centi
  # Integer hundredths make the comparison exact.
  minimum_centi="$(zoomctl_float_to_centi "$1")" || return 1
  reset_centi="$(zoomctl_float_to_centi "$2")" || return 1
  maximum_centi="$(zoomctl_float_to_centi "$3")" || return 1
  (( minimum_centi <= reset_centi && reset_centi <= maximum_centi ))
}

# zoomctl_bounds_message — describe the cross-field rule with the offending values.
# Args:    $1 minimum; $2 reset; $3 maximum
# Returns: 0 always; stdout: one sentence
# Globals: none
zoomctl_bounds_message() {
  # Show all three numbers so the user sees which one to change.
  printf 'ZOOM_MIN (%s) <= ZOOM_RESET (%s) <= ZOOM_MAX (%s) must hold\n' "$1" "$2" "$3"
}
