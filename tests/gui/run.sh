#!/usr/bin/env bash
# run.sh — run the settings-app test suites (model, controller, GTK widgets on Broadway).
#   tests/gui/run.sh            all suites
#   tests/gui/run.sh -k pattern extra arguments go to unittest (e.g. -k slider, -v)
#
# The widget tests start their own gtk4-broadwayd; they never open a window on the live desktop.
# The suites use only the standard library (unittest), so CI needs PyGObject, GTK4, libadwaita
# and gtk4-broadwayd — nothing from pip. pytest can run the same files (`pytest tests/gui`).
# When a prerequisite is missing the run is SKIPPED (exit 77, the automake convention) with one
# line naming it, so generic jobs and package builds do not fail for a missing GUI stack.
set -euo pipefail

# Exit status that means "skipped" to automake-style harnesses and to tests/run.sh.
readonly SKIP_STATUS=77

# gui_dir — absolute directory of this script, the root of the discovered tests.
# Args:    none
# Returns: 0 always; stdout: the directory path
# Globals: reads BASH_SOURCE
gui_dir() {
  # cd + pwd resolves relative invocations such as `bash tests/gui/run.sh`.
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# missing_prerequisite — name the first missing piece of the GUI test stack.
# Args:    none
# Returns: 0 when something is missing; 1 when everything is there; stdout: what is missing
# Globals: none
missing_prerequisite() {
  # Without python3 nothing else can be probed.
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3\n'
    return 0
  fi
  # One import probes PyGObject, GTK 4 and libadwaita together.
  if ! python3 -c 'import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk' >/dev/null 2>&1; then
    printf 'PyGObject with GTK 4 and libadwaita (python3 gi)\n'
    return 0
  fi
  # The widget tests render on a private Broadway display.
  if ! command -v gtk4-broadwayd >/dev/null 2>&1; then
    printf 'gtk4-broadwayd\n'
    return 0
  fi
  return 1
}

# main — skip when the stack is incomplete, else discover and run every test_*.py.
# Args:    $@ extra arguments for unittest
# Returns: 77 when skipped; otherwise unittest's exit status; stdout/stderr: the report
# Globals: reads SKIP_STATUS
main() {
  local directory missing
  # A missing piece is reported once and is not a failure.
  if missing="$(missing_prerequisite)"; then
    printf 'SKIP tests/gui: %s not available\n' "$missing"
    exit "$SKIP_STATUS"
  fi
  directory="$(gui_dir)"
  # -t keeps the directory itself the top level, so the tests can `import support`.
  exec python3 -m unittest discover \
    -s "$directory" -t "$directory" -p 'test_*.py' "$@"
}

main "$@"
