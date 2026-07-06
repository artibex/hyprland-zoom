#!/usr/bin/env bash

zoomctl_format_float() {
  awk -v value="$1" 'BEGIN { printf "%.2f\n", value + 0 }'
}

zoomctl_add_float() {
  awk -v left="$1" -v right="$2" 'BEGIN { printf "%.2f\n", left + right }'
}

zoomctl_clamp_float() {
  awk -v value="$1" -v minimum="$2" -v maximum="$3" '
    BEGIN {
      if ((value + 0) < (minimum + 0)) {
        printf "%.2f\n", minimum + 0
      } else if ((value + 0) > (maximum + 0)) {
        printf "%.2f\n", maximum + 0
      } else {
        printf "%.2f\n", value + 0
      }
    }
  '
}

zoomctl_float_gt() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit(!((left + 0) > (right + 0))) }'
}

zoomctl_is_float() {
  awk -v value="$1" 'BEGIN { exit(!(value ~ /^-?[0-9]+([.][0-9]+)?$/)) }'
}