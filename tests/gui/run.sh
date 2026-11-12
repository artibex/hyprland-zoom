#!/usr/bin/env bash
# run.sh — run the settings-app test suites (model, controller, GTK widgets on Broadway).
#   tests/gui/run.sh            all suites
#   tests/gui/run.sh -k pattern extra arguments go to unittest (e.g. -k slider, -v)
#
# The widget tests start their own gtk4-broadwayd; they never open a window on the live desktop.
# The suites use only the standard library (unittest), so CI needs PyGObject, GTK4, libadwaita
# and gtk4-broadwayd — nothing from pip. pytest can run the same files (`pytest tests/gui`).
set -euo pipefail

# gui_dir — absolute directory of this script, the root of the discovered tests.
# Args:    none
# Returns: 0 always; stdout: the directory path
# Globals: reads BASH_SOURCE
gui_dir() {
  # cd + pwd resolves relative invocations such as `bash tests/gui/run.sh`.
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# main — discover and run every test_*.py of the GUI suite.
# Args:    $@ extra arguments for unittest
# Returns: unittest's exit status; stdout/stderr: the test report
# Globals: none
main() {
  local directory
  directory="$(gui_dir)"
  # -t keeps the directory itself the top level, so the tests can `import support`.
  exec python3 -m unittest discover \
    -s "$directory" -t "$directory" -p 'test_*.py' "$@"
}

main "$@"
