#!/usr/bin/env bash
# run.sh — run the Lua unit suites of the zoom engine with the host `lua`.
# Usage: tests/lua/run.sh [suite-name ...]; exit 0 only when every case passed.
set -euo pipefail

# Directory of this script, independent of the caller's working directory.
script_directory="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Fail early with a clear message when the interpreter is missing.
command -v lua > /dev/null 2>&1 || { echo "run.sh: 'lua' not found" >&2; exit 1; }

# Suites must never touch the real user config or runtime state: use throwaway directories.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# Run with a scrubbed environment so only the sandbox paths are visible to the code.
env -i PATH="$PATH" HOME="$sandbox/home" XDG_CONFIG_HOME="$sandbox/config" \
  XDG_RUNTIME_DIR="$sandbox/runtime" ZOOMCTL_STATE_DIR="$sandbox/state" \
  ZOOMCTL_USER_CONFIG="$sandbox/user.conf" ZOOMCTL_SYSTEM_CONFIG="$sandbox/system.conf" \
  ZOOMCTL_TEST_SANDBOX="$sandbox" OMARCHY_PATH="$sandbox/omarchy" \
  lua "$script_directory/run.lua" "$@"

# The Python shader reference predicts the nested screenshots; its own unit tests run with the
# full suite only (a named Lua suite skips them). A missing python3 is a visible SKIP.
if [[ $# -eq 0 ]]; then
  if command -v python3 > /dev/null 2>&1; then
    env -i PATH="$PATH" HOME="$sandbox/home" python3 -B -m unittest discover \
      -s "$script_directory/../integration" -p 'test_*.py'
  else
    echo "SKIP shader reference tests: python3 not found"
  fi
fi
