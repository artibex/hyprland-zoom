#!/usr/bin/env bash
# math.sh — fixed-point decimal helpers (hundredths) in pure bash, no awk forks.
# A "centi" is an integer number of hundredths: 1.25 is 125, -0.50 is -50.

# zoomctl_is_float — test whether text is a plain decimal number.
# Args:    $1 text
# Returns: 0 it is (optional minus, 1-6 digits, optional fraction); 1 it is not
# Globals: none
zoomctl_is_float() {
  # Six integer digits keep the later arithmetic far from overflow.
  [[ "$1" =~ ^-?[0-9]{1,6}(\.[0-9]+)?$ ]]
}

# zoomctl_float_to_centi — convert a decimal to hundredths, rounding half away from zero.
# Args:    $1 decimal text accepted by zoomctl_is_float
# Returns: 0 on success; 1 when the text is not a number; stdout: integer hundredths
# Globals: none
zoomctl_float_to_centi() {
  local text="$1"
  local sign=1
  local whole fraction centi
  # Reject anything that is not a number before any arithmetic.
  zoomctl_is_float "$text" || return 1
  # Remember the sign and work on the magnitude.
  if [[ "$text" == -* ]]; then
    sign=-1
    text="${text#-}"
  fi
  # Split into integer and fraction; pad the fraction so slicing is safe.
  whole="${text%%.*}"
  fraction=""
  [[ "$text" == *.* ]] && fraction="${text#*.}"
  fraction="${fraction}000"
  # Hundredths come from two digits, the third digit decides the rounding.
  centi=$((10#$whole * 100 + 10#${fraction:0:2}))
  (( 10#${fraction:2:1} >= 5 )) && centi=$((centi + 1))
  printf '%s\n' "$((sign * centi))"
}

# zoomctl_centi_to_float — format hundredths as a two-decimal number.
# Args:    $1 integer hundredths
# Returns: 0 always; stdout: for example 1.50 or -0.05
# Globals: none
zoomctl_centi_to_float() {
  local centi="$1"
  local sign=""
  # Format the magnitude and put the sign back in front.
  (( centi < 0 )) && { sign="-"; centi=$((-centi)); }
  printf '%s%d.%02d\n' "$sign" "$((centi / 100))" "$((centi % 100))"
}

# zoomctl_format_float — normalise a decimal to the canonical two-decimal form.
# Args:    $1 decimal text
# Returns: 0 on success; 1 when not a number; stdout: canonical text (1.5 -> 1.50)
# Globals: none
zoomctl_format_float() {
  local centi
  # Round to hundredths first, then render.
  centi="$(zoomctl_float_to_centi "$1")" || return 1
  zoomctl_centi_to_float "$centi"
}

# zoomctl_clamp_centi — limit an integer to an inclusive range.
# Args:    $1 value; $2 minimum; $3 maximum (all integers)
# Returns: 0 always; stdout: the clamped integer
# Globals: none
zoomctl_clamp_centi() {
  local value="$1"
  # Below the range snaps up, above the range snaps down.
  (( value < $2 )) && value="$2"
  (( value > $3 )) && value="$3"
  printf '%s\n' "$value"
}
