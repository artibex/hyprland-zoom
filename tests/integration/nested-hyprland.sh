#!/usr/bin/env bash
# nested-hyprland.sh — start/stop/talk to a throwaway Hyprland nested in the live session.
#   nested-hyprland.sh start <config.lua>   -> starts, prints the instance signature
#   nested-hyprland.sh sig | wl             -> signature / nested wayland socket name
#   nested-hyprland.sh ctl <hyprctl args>   -> hyprctl against the nested instance ONLY
#   nested-hyprland.sh shot <out.png>       -> grim screenshot (SHOT_OUTPUT=HEADLESS-1 default)
#   nested-hyprland.sh run <cmd...>         -> run a client inside the nested instance
#   nested-hyprland.sh log [N]              -> tail of the nested hyprland.log
#   nested-hyprland.sh stop                 -> kill ONLY the PID we started + remove its dir
#
# State lives in $NESTED_STATE_DIR (default tests/integration/work/state).
# How it works (verified on Hyprland 0.56.2):
#  * Started inside a running Wayland session Hyprland picks the aquamarine *wayland* backend
#    and shows up as ONE window ("aquamarine - WAYLAND-1") in the parent compositor.
#    AQ_BACKENDS=headless is ignored by this aquamarine build.
#  * The window size is dictated by the parent's tiling, so for deterministic geometry a
#    virtual HEADLESS-1 output (1280x720 via hl.monitor in the config) is created and
#    screenshots use that output.
#  * The signature is injected per command; nothing is exported into the caller's shell.
set -euo pipefail

# Directory of this script and the state directory of the nested instance.
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${NESTED_STATE_DIR:-$HERE/work/state}"
# The live session's runtime directory (sockets live below it); required.
RUNTIME_DIR="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR unset}"
# Name of the virtual output screenshots are taken from.
HEADLESS_OUTPUT="${SHOT_OUTPUT:-HEADLESS-1}"

# die — print an error message and stop the script.
# Args:    $1 message
# Returns: never returns (exit 1); stderr: the message
# Globals: none
die() {
  # Errors go to stderr so stdout stays machine-readable.
  echo "nested-hyprland: $1" >&2
  exit 1
}

# read_state_file — print one recorded value of the nested instance.
# Args:    $1 file name inside the state directory (sig, wl or pid)
# Returns: 0 and the value on stdout; exits 1 when no nested instance is recorded
# Globals: reads STATE_DIR
# Notes:   SAFETY: never falls back to the live session's display or signature.
read_state_file() {
  # An empty or missing file means no instance: refuse instead of guessing.
  [[ -s "$STATE_DIR/$1" ]] || die "no nested instance running"
  cat "$STATE_DIR/$1"
}

# is_instance_running — test whether the recorded PID is alive.
# Args:    none
# Returns: 0 when the nested Hyprland process is alive; 1 otherwise
# Globals: reads STATE_DIR
is_instance_running() {
  # No PID file means never started or already stopped.
  [[ -f "$STATE_DIR/pid" ]] || return 1
  kill -0 "$(cat "$STATE_DIR/pid")" 2> /dev/null
}

# launch_hyprland — start the nested compositor in the background.
# Args:    $1 absolute path of the Lua config
# Returns: 0 always; writes the PID file and stdout.log
# Globals: reads STATE_DIR
# Notes:   The parent's WAYLAND_DISPLAY is kept on purpose: it selects the nested backend.
launch_hyprland() {
  # Isolated XDG dirs: the child never touches the user's config, cache or state.
  mkdir -p "$STATE_DIR"/xdg/{config,data,cache,state}
  # Do not inherit the parent's instance signature.
  env -u HYPRLAND_INSTANCE_SIGNATURE -u HYPRLAND_CMD \
    XDG_CONFIG_HOME="$STATE_DIR/xdg/config" XDG_DATA_HOME="$STATE_DIR/xdg/data" \
    XDG_CACHE_HOME="$STATE_DIR/xdg/cache" XDG_STATE_HOME="$STATE_DIR/xdg/state" \
    setsid Hyprland --config "$1" > "$STATE_DIR/stdout.log" 2>&1 &
  echo $! > "$STATE_DIR/pid"
}

# find_own_instance_dir — find the instance directory whose lock file names the PID we started.
# Args:    none
# Returns: 0 and the directory path on stdout; 1 when no lock file carries our PID (yet)
# Globals: reads RUNTIME_DIR, STATE_DIR
# Notes:   Hyprland writes "<pid>\n<wayland socket>\n" into <instance>/hyprland.lock, so the PID
#          identifies our instance even while other agents start instances in parallel.
find_own_instance_dir() {
  local own_pid lock_file
  own_pid="$(cat "$STATE_DIR/pid")"
  # A glob (not `ls`) is safe for any name; missing or unreadable locks are simply skipped.
  for lock_file in "$RUNTIME_DIR"/hypr/*/hyprland.lock; do
    # The first line of the lock file is the owning compositor's PID.
    if [[ -f "$lock_file" && "$(head -n 1 "$lock_file" 2> /dev/null)" == "$own_pid" ]]; then
      dirname "$lock_file"
      return 0
    fi
  done
  return 1
}

# wait_for_own_instance — wait until our compositor opened its control socket.
# Args:    none
# Returns: 0 and the signature on stdout (the wayland socket name goes into the wl file);
#          1 when the process died or nothing appeared
# Globals: reads RUNTIME_DIR, STATE_DIR; writes the wl file
wait_for_own_instance() {
  local instance_dir
  # Poll for up to 20 seconds.
  for _ in $(seq 1 100); do
    sleep 0.2
    # A dead process will never open a socket: fail fast with a pointer to the log.
    if ! is_instance_running; then
      echo "Hyprland exited early; see $STATE_DIR/stdout.log" >&2
      return 1
    fi
    # Ready when the lock names our PID and the control socket exists.
    if instance_dir="$(find_own_instance_dir)" && [[ -S "$instance_dir/.socket.sock" ]]; then
      # The second lock line is the nested compositor's own wayland socket.
      sed -n '2p' "$instance_dir/hyprland.lock" > "$STATE_DIR/wl"
      basename "$instance_dir"
      return 0
    fi
  done
  # Timed out: report it so the caller can stop the half-started process.
  echo "no instance with our PID appeared" >&2
  return 1
}

# create_headless_output — add the virtual 1280x720 output and focus it.
# Args:    $1 instance signature
# Returns: 0 always (failures are tolerated; the config may already provide the output)
# Globals: none
create_headless_output() {
  # The control socket may need a moment before it accepts commands.
  for _ in $(seq 1 25); do
    HYPRLAND_INSTANCE_SIGNATURE="$1" hyprctl output create headless > /dev/null 2>&1 && break
    sleep 0.2
  done
  # Give the new output a moment to settle before focusing it.
  sleep 0.5
  # New windows open on the focused output, so focus the virtual one (Lua dispatcher syntax).
  HYPRLAND_INSTANCE_SIGNATURE="$1" hyprctl dispatch \
    "hl.dsp.focus({ monitor = \"$HEADLESS_OUTPUT\" })" > /dev/null 2>&1 || true
}

# command_start — start the nested instance.
# Args:    $1 Lua config path
# Returns: 0 and the signature on stdout; 1 on failure or when already running
# Globals: reads STATE_DIR, NESTED_HEADLESS_OUTPUT; writes the state files
command_start() {
  local config_path new_signature
  # Resolve to an absolute path because Hyprland is started from another directory.
  config_path="$(readlink -f "${1:?usage: start <config.lua>}")"
  mkdir -p "$STATE_DIR"
  # Refuse to start a second instance on the same state directory.
  if is_instance_running; then
    die "already running: $(read_state_file sig)"
  fi
  # Forget stale values; the instance is identified later by the PID we are about to record.
  rm -f "$STATE_DIR"/{sig,pid,wl}
  launch_hyprland "$config_path"
  # Wait until the control socket is up; a failure leaves the PID file for `stop`.
  new_signature="$(wait_for_own_instance)" || return 1
  echo "$new_signature" > "$STATE_DIR/sig"
  # Opt out with NESTED_HEADLESS_OUTPUT=0 when the config creates its own output.
  if [[ "${NESTED_HEADLESS_OUTPUT:-1}" == 1 ]]; then
    create_headless_output "$new_signature"
  fi
  echo "$new_signature"
}

# command_ctl — run hyprctl against the nested instance only.
# Args:    $@ hyprctl arguments
# Returns: hyprctl's exit status; stdout: hyprctl's output
# Globals: reads STATE_DIR
command_ctl() {
  local signature
  # The signature is injected for this one command only (never exported).
  signature="$(read_state_file sig)"
  HYPRLAND_INSTANCE_SIGNATURE="$signature" hyprctl "$@"
}

# command_shot — take a grim screenshot of the virtual output.
# Args:    $1 output PNG path
# Returns: grim's exit status
# Globals: reads STATE_DIR, HEADLESS_OUTPUT
command_shot() {
  local display
  # grim must talk to the nested compositor's socket, not the live session's.
  display="$(read_state_file wl)"
  WAYLAND_DISPLAY="$display" grim -o "$HEADLESS_OUTPUT" "${1:?usage: shot <out.png>}"
}

# command_run — start a client inside the nested instance (detached).
# Args:    $@ the command and its arguments
# Returns: 0 once the client was started in the background
# Globals: reads STATE_DIR
command_run() {
  local display signature
  # Both values come from the recorded nested instance (refuses when none runs).
  display="$(read_state_file wl)"
  signature="$(read_state_file sig)"
  WAYLAND_DISPLAY="$display" HYPRLAND_INSTANCE_SIGNATURE="$signature" \
    setsid "$@" > /dev/null 2>&1 &
  # Remember the client so `stop` can end it (clients can outlive a killed compositor).
  echo $! >> "$STATE_DIR/clients"
}

# command_log — print the tail of the nested Hyprland log.
# Args:    $1 number of lines (optional, default 60)
# Returns: tail's exit status
# Globals: reads RUNTIME_DIR, STATE_DIR
command_log() {
  tail -n "${1:-60}" "$RUNTIME_DIR/hypr/$(read_state_file sig)/hyprland.log"
}

# stop_recorded_clients — end the clients started through `run` (only the recorded PIDs).
# Args:    none
# Returns: 0 always
# Globals: reads STATE_DIR; removes the clients file
stop_recorded_clients() {
  local client_pid
  # Nothing recorded means nothing to do.
  [[ -f "$STATE_DIR/clients" ]] || return 0
  while read -r client_pid; do
    kill "$client_pid" 2> /dev/null || true
  done < "$STATE_DIR/clients"
  # The list is consumed; the next start begins empty.
  rm -f "$STATE_DIR/clients"
}

# command_stop — stop ONLY the instance this script started.
# Args:    none
# Returns: 0 always; stdout: "stopped <pid>" or "not running"
# Globals: reads RUNTIME_DIR, STATE_DIR; removes the state files
command_stop() {
  local pid signature
  # Nothing to stop: just clean the records.
  if ! is_instance_running; then
    echo "not running"
    # Remove the leftovers so the next start begins clean.
    stop_recorded_clients
    rm -f "$STATE_DIR"/{sig,pid,wl}
    return 0
  fi
  # The recorded PID is the only process this script may ever signal.
  pid="$(cat "$STATE_DIR/pid")"
  stop_recorded_clients
  signature="$(cat "$STATE_DIR/sig" 2> /dev/null || true)"
  # Polite first, forceful only after five seconds.
  kill "$pid"
  # Poll for the process to exit.
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.1
  done
  # Still alive after the grace period: kill it hard (our own PID only).
  kill -0 "$pid" 2> /dev/null && kill -9 "$pid"
  echo "stopped $pid"
  # Remove the stale runtime dir of THIS instance only (never the live session's).
  if [[ -n "$signature" && "$signature" != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
    rm -rf "${RUNTIME_DIR:?}/hypr/$signature"
  fi
  rm -f "$STATE_DIR"/{sig,pid,wl}
}

# usage — print the header comment as help text.
# Args:    none
# Returns: 0 always; stdout: the usage lines
# Globals: none
usage() {
  # The first block of comment lines doubles as the help text.
  sed -n '2,9p' "$0"
}

# main — dispatch the sub-command.
# Args:    $1 sub-command; remaining arguments are passed on
# Returns: the sub-command's exit status; 2 for an unknown sub-command
# Globals: none
main() {
  local subcommand="${1:-}"
  # No arguments at all is fine: usage is printed below.
  shift || true
  case "$subcommand" in
    start) command_start "$@" ;;  # start the nested compositor
    sig) read_state_file sig ;;   # print its instance signature
    wl) read_state_file wl ;;     # print its wayland socket name
    ctl) command_ctl "$@" ;;      # hyprctl against the nested instance
    shot) command_shot "$@" ;;    # screenshot of the virtual output
    run) command_run "$@" ;;      # start a client inside it
    log) command_log "$@" ;;      # tail of its log
    stop) command_stop ;;         # stop only what we started
    *) usage; return 2 ;;         # unknown sub-command
  esac
}

main "$@"
