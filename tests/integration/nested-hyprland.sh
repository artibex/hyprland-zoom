#!/usr/bin/env bash
# nested-hyprland.sh — start/stop/talk to a throwaway Hyprland nested in the live session.
#   nested-hyprland.sh start <config.lua>   -> starts, prints instance signature
#   nested-hyprland.sh sig | wl             -> signature / nested wayland socket name
#   nested-hyprland.sh ctl <hyprctl args>   -> hyprctl against the nested instance ONLY
#   nested-hyprland.sh shot <out.png>       -> grim screenshot (SHOT_OUTPUT=HEADLESS-1 by default)
#   nested-hyprland.sh run <cmd...>         -> run a client inside the nested instance
#   nested-hyprland.sh log [N]              -> tail of the nested hyprland.log
#   nested-hyprland.sh stop                 -> kill ONLY the PID we started + remove its runtime dir
#
# How it works (verified on Hyprland 0.56.2):
#  * Started inside a running Wayland session Hyprland picks the aquamarine *wayland* backend and
#    shows up as ONE window ("aquamarine - WAYLAND-1") in the parent compositor. (AQ_BACKENDS=headless
#    is ignored by this aquamarine build; without WAYLAND_DISPLAY it dies "CBackend::create() failed".)
#  * The window size is dictated by the parent's tiling, so for deterministic geometry we add a
#    virtual `HEADLESS-1` output (1280x720 via hl.monitor in the config) with
#    `hyprctl output create headless` and screenshot that one (grim -o HEADLESS-1).
#  * The signature is injected per command (HYPRLAND_INSTANCE_SIGNATURE=... on the hyprctl call);
#    nothing is exported into the caller's shell.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${NESTED_STATE_DIR:-$HERE/work/state}"
mkdir -p "$STATE"
RT="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR unset}"

cmd="${1:-}"; shift || true

sig()  { [[ -s "$STATE/sig" ]] || { echo "nested-hyprland: no nested instance running" >&2; exit 1; }; cat "$STATE/sig"; }
pid()  { cat "$STATE/pid"; }
# SAFETY: never fall back to the live session's WAYLAND_DISPLAY / signature when no nested instance runs
disp() { [[ -s "$STATE/wl" ]] || { echo "nested-hyprland: no nested instance running" >&2; exit 1; }; cat "$STATE/wl"; }

case "$cmd" in
  start)
    cfg="$(readlink -f "${1:?usage: start <config.lua>}")"
    [[ -f "$STATE/pid" ]] && kill -0 "$(pid)" 2>/dev/null && { echo "already running: $(sig)" >&2; exit 1; }
    rm -f "$STATE"/{sig,pid,wl}
    ls "$RT/hypr" 2>/dev/null | sort > "$STATE/before.sig" || true
    ls "$RT" 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort > "$STATE/before.wl" || true
    # Isolated XDG dirs: the child never touches the user's config/cache/state.
    mkdir -p "$STATE/xdg/config" "$STATE/xdg/data" "$STATE/xdg/cache" "$STATE/xdg/state"
    # env -u: don't inherit the parent's instance signature. The parent's WAYLAND_DISPLAY is kept on
    # purpose: it is what makes Hyprland choose the nested (wayland) backend.
    env -u HYPRLAND_INSTANCE_SIGNATURE -u HYPRLAND_CMD \
        XDG_CONFIG_HOME="$STATE/xdg/config" XDG_DATA_HOME="$STATE/xdg/data" \
        XDG_CACHE_HOME="$STATE/xdg/cache" XDG_STATE_HOME="$STATE/xdg/state" \
        setsid Hyprland --config "$cfg" > "$STATE/stdout.log" 2>&1 &
    echo $! > "$STATE/pid"
    new=""
    for _ in $(seq 1 100); do
      sleep 0.2
      kill -0 "$(pid)" 2>/dev/null || { echo "Hyprland exited early; see $STATE/stdout.log" >&2; exit 1; }
      new="$(ls "$RT/hypr" 2>/dev/null | sort | comm -13 "$STATE/before.sig" - | head -1 || true)"
      [[ -n "$new" && -S "$RT/hypr/$new/.socket.sock" ]] && break
      new=""
    done
    [[ -n "$new" ]] || { echo "no new instance signature appeared" >&2; exit 1; }
    echo "$new" > "$STATE/sig"
    ls "$RT" | grep -E '^wayland-[0-9]+$' | sort | comm -13 "$STATE/before.wl" - | head -1 > "$STATE/wl" || true
    if [[ "${NESTED_HEADLESS_OUTPUT:-1}" == 1 ]]; then
      for _ in $(seq 1 25); do
        HYPRLAND_INSTANCE_SIGNATURE="$new" hyprctl output create headless >/dev/null 2>&1 && break
        sleep 0.2
      done
      sleep 0.5
      # make the headless output the focused one so new windows open there
      HYPRLAND_INSTANCE_SIGNATURE="$new" hyprctl dispatch focusmonitor HEADLESS-1 >/dev/null 2>&1 || true
    fi
    echo "$new"
    ;;
  sig)  sig ;;
  wl)   disp ;;
  ctl)  s="$(sig)" || exit 1; HYPRLAND_INSTANCE_SIGNATURE="$s" hyprctl "$@" ;;
  shot) w="$(disp)" || exit 1; WAYLAND_DISPLAY="$w" grim -o "${SHOT_OUTPUT:-HEADLESS-1}" "${1:?usage: shot <out.png>}" ;;
  run)  w="$(disp)" || exit 1; s="$(sig)" || exit 1
        WAYLAND_DISPLAY="$w" HYPRLAND_INSTANCE_SIGNATURE="$s" setsid "$@" >/dev/null 2>&1 & ;;
  log)  tail -n "${1:-60}" "$RT/hypr/$(sig)/hyprland.log" ;;
  stop)
    if [[ -f "$STATE/pid" ]] && kill -0 "$(pid)" 2>/dev/null; then
      s="$(cat "$STATE/sig" 2>/dev/null || true)"
      kill "$(pid)"
      for _ in $(seq 1 50); do kill -0 "$(pid)" 2>/dev/null || break; sleep 0.1; done
      kill -0 "$(pid)" 2>/dev/null && kill -9 "$(pid)"
      echo "stopped $(pid)"
      # remove the stale runtime dir of THIS instance (never the live session's)
      if [[ -n "$s" && "$s" != "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then rm -rf "${RT:?}/hypr/$s"; fi
    else
      echo "not running"
    fi
    rm -f "$STATE"/{sig,pid,wl}
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
