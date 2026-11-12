#!/usr/bin/env bash
# test-engine-nested.sh — prove the Lua zoom engine inside a throwaway nested Hyprland.
# Local only: a window of the nested compositor appears in the live session for ~1 minute.
# Exit 0 = all checks passed or SKIP (no Wayland session / missing tools); 1 = a check failed.
# Safety: every hyprctl/grim/client call goes through nested-hyprland.sh, which refuses to
# fall back to the live session; the live session is never touched. The plugin section builds
# plugin/hyprzoom.so and loads it into the NESTED instance only (skipped without headers).
set -euo pipefail

# Locations: this directory, the repository root and the scratch directory of this test.
HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(CDPATH='' cd -- "$HERE/../.." && pwd)"
WORK="${NESTED_WORK_DIR:-$HERE/work/engine-nested}"
# The nested-instance harness and the Python helpers.
NESTED="$HERE/nested-hyprland.sh"
PIXELS="$HERE/pixels.py"
# The built plugin and the package version the engine must report.
PLUGIN_SO="$REPO/plugin/hyprzoom.so"
PACKAGE_VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
# Counters of the final summary.
PASS_COUNT=0
FAIL_COUNT=0
# Tools the test needs; a missing one turns the whole run into a SKIP.
REQUIRED_TOOLS=(Hyprland hyprctl grim imv foot wtype jq python3)

# record_result — print and count one check result.
# Args:    $1 PASS or FAIL; $2 label
# Returns: 0 always
# Globals: writes PASS_COUNT, FAIL_COUNT
record_result() {
  # Count first, then print the stable "STATUS label" line.
  if [[ "$1" == PASS ]]; then PASS_COUNT=$((PASS_COUNT + 1)); else FAIL_COUNT=$((FAIL_COUNT + 1)); fi
  echo "$1 $2"
}

# expect_equal — compare two values.
# Args:    $1 label; $2 actual; $3 expected
# Returns: 0 always; prints PASS/FAIL (with both values on failure)
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_equal() {
  # Show both values on failure so the log is self-explanatory.
  if [[ "$2" == "$3" ]]; then
    record_result PASS "$1"
  else
    record_result FAIL "$1 (expected '$3', got '$2')"
  fi
}

# expect_contains — check that text contains a substring.
# Args:    $1 label; $2 text; $3 needle
# Returns: 0 always; prints PASS/FAIL
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_contains() {
  # Plain substring match, no pattern syntax.
  if [[ "$2" == *"$3"* ]]; then
    record_result PASS "$1"
  else
    record_result FAIL "$1 (missing '$3' in '$2')"
  fi
}

# expect_command — run a command and require exit status 0.
# Args:    $1 label; remaining arguments: the command
# Returns: 0 always; prints PASS/FAIL (with the command output on failure)
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_command() {
  local label="$1" output
  shift
  # The output is only shown when the command fails.
  if output="$("$@" 2>&1)"; then
    record_result PASS "$label"
  else
    record_result FAIL "$label ($output)"
  fi
}

# nested — run the nested-instance harness with this test's state directory.
# Args:    $@ harness arguments
# Returns: the harness exit status
# Globals: reads WORK, NESTED
nested() {
  # The harness gets its own state directory; nothing is exported into the caller's shell.
  NESTED_STATE_DIR="$WORK/state" bash "$NESTED" "$@"
}

# engine — evaluate Lua in the nested engine and print the result.
# Args:    $1 Lua expression or statements (use `return ...` for a value)
# Returns: hyprctl's exit status; stdout: the returned values
# Globals: none
engine() {
  nested ctl repl "$1"
}

# status_value — read one key of HyprZoom.status().
# Args:    $1 key name
# Returns: 0 and the value on stdout (empty when the key is missing)
# Globals: none
status_value() {
  engine 'return HyprZoom.status()' | sed -n "s/^$1=//p"
}

# option_value — read a Hyprland option of the nested instance.
# Args:    $1 option name such as cursor:zoom_factor
# Returns: 0 and the value on stdout
# Globals: none
option_value() {
  # Booleans may be `false`, which jq's `//` would skip, so pick the first non-null field.
  nested ctl -j getoption "$1" \
    | jq -r '[.float, .int, .bool, .str, .custom] | map(select(. != null)) | (if length > 0 then .[0] else "" end)
      | tostring | if . == "[[EMPTY]]" then "" else . end'
}

# wait_until — poll a command until it succeeds.
# Args:    $1 seconds to wait at most; remaining arguments: the command
# Returns: 0 when the command succeeded in time; 1 on timeout
# Globals: none
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  # Check every 0.2 s so short waits stay cheap.
  while ! "$@" > /dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 0.2
  done
}

# missing_tools — list required tools that are not installed.
# Args:    none
# Returns: 0 always; stdout: the missing tool names, space separated
# Globals: reads REQUIRED_TOOLS
missing_tools() {
  local tool missing=""
  for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" > /dev/null 2>&1 || missing="$missing $tool"
  done
  echo "${missing# }"
}

# should_skip — decide whether the test can run here.
# Args:    none
# Returns: 0 and a reason on stdout when the test must be skipped; 1 when it can run
# Globals: none
should_skip() {
  local missing
  # A nested Hyprland needs a parent Wayland session to attach to.
  if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo "no Wayland session (WAYLAND_DISPLAY/XDG_RUNTIME_DIR unset)"
    return 0
  fi
  missing="$(missing_tools)"
  if [[ -n "$missing" ]]; then
    echo "missing tools: $missing"
    return 0
  fi
  return 1
}

# write_nested_config — create the nested Hyprland config and the engine settings.
# Args:    none
# Returns: 0 always; writes config.lua, user.conf and system.conf below WORK
# Globals: reads WORK, REPO
write_nested_config() {
  mkdir -p "$WORK"
  # Instant zoom animation keeps the pixel checks fast; the user config is test-private.
  printf 'ZOOM_ANIMATION_SPEED=0.10\n' > "$WORK/user.conf"
  : > "$WORK/system.conf"
  # Fixed geometry, no gaps/borders, a fake Omarchy (helper `o` + the colliding binds), then
  # the engine itself loaded from the working tree exactly like a user's hyprland.lua would.
  {
    echo 'hl.monitor({ output = "HEADLESS-1", mode = "1280x720@60", position = "0x0", scale = 1 })'
    echo 'hl.config({ general = { gaps_in = 0, gaps_out = 0, border_size = 0 } })'
    echo 'hl.config({ ecosystem = { no_donation_nag = true, no_update_news = true } })'
    echo 'o = { bind = function() end }'
    echo 'hl.bind("SUPER + ALT + mouse_up", hl.dsp.exec_cmd("true"), { description = "Omarchy" })'
    echo 'hl.bind("SUPER + CTRL + Z", hl.dsp.exec_cmd("true"), { description = "Omarchy zoom" })'
    echo "dofile(\"$REPO/src/lua/hyprland-zoom.lua\")"
  } > "$WORK/config.lua"
}

# start_nested — start the nested Hyprland with the engine loaded.
# Args:    none
# Returns: 0 when it is up and the engine answers; 1 otherwise
# Globals: reads WORK
start_nested() {
  # Test-private engine files; the variables are inherited by the nested compositor only.
  ZOOMCTL_STATE_DIR="$WORK/engine-state" ZOOMCTL_USER_CONFIG="$WORK/user.conf" \
    ZOOMCTL_SYSTEM_CONFIG="$WORK/system.conf" nested start "$WORK/config.lua" > /dev/null
  wait_until 10 engine 'return HyprZoom.status()'
}

# stop_nested — stop the nested instance (also used by the EXIT trap).
# Args:    none
# Returns: 0 always
# Globals: none
stop_nested() {
  nested stop > /dev/null 2>&1 || true
}

# check_engine_loaded — the engine answers and reports its identity.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_engine_loaded() {
  local status
  status="$(engine 'return HyprZoom.status()')"
  expect_contains "engine reports engine=lua" "$status" "engine=lua"
  expect_equal "engine version is the VERSION file" "$(status_value version)" "$PACKAGE_VERSION"
  expect_equal "scroll_event_delay applied (E2)" "$(option_value binds:scroll_event_delay)" "0"
  expect_equal "unzoomed at start" "$(status_value zoom)" "1.00"
}

# check_binds — the C7 binds exist with the right modifiers and the takeover worked.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_binds() {
  local binds
  binds="$(nested ctl -j binds | jq -r '.[] | "\(.modmask) \(.key) \(.description)"')"
  # SUPER (64) + ALT (8) = 72 for every default chord.
  expect_contains "bind scroll down zooms in" "$binds" "72 mouse_down hyprland-zoom: Zoom in"
  expect_contains "bind scroll up zooms out" "$binds" "72 mouse_up hyprland-zoom: Zoom out"
  expect_contains "bind middle click toggles" "$binds" "72 mouse:274 hyprland-zoom: Toggle zoom"
  expect_contains "bind key I" "$binds" "72 I hyprland-zoom: Zoom in"
  expect_contains "bind key C" "$binds" "72 C hyprland-zoom: Toggle color filter"
  expect_contains "bind key Z" "$binds" "72 Z hyprland-zoom: Open settings"
  # Takeover (E11): the fake Omarchy binds on the same chords are gone; SUPER+CTRL = 68.
  expect_equal "only one bind on SUPER+ALT+mouse_up" \
    "$(grep -c ' mouse_up ' <<< "$binds")" "1"
  expect_contains "SUPER+CTRL+Z re-routed to the engine" "$binds" "68 Z hyprland-zoom: Zoom in"
}

# check_zoom_steps — single steps move the compositor's zoom factor exactly.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_zoom_steps() {
  expect_equal "zoom_in returns the new level" "$(engine 'return HyprZoom.zoom_in()')" "zoom=1.10"
  expect_equal "compositor holds 1.1 (float32)" \
    "$(printf '%.3f' "$(option_value cursor:zoom_factor)")" "1.100"
  expect_equal "zoom_out returns to 1.00" "$(engine 'return HyprZoom.zoom_out()')" "zoom=1.00"
  expect_equal "zoom never drops below the minimum" \
    "$(engine 'return HyprZoom.zoom_out(5)')" "zoom=1.00"
}

# check_rapid_notches — 20 concurrent evals end exactly at 1.1^20 (no lost update).
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_rapid_notches() {
  local _
  # The 0.1 MVP lost 17-19 of these 20 steps (race between processes).
  for _ in $(seq 1 20); do
    nested ctl eval 'HyprZoom.zoom_in()' > /dev/null &
  done
  wait
  expect_equal "20 concurrent zoom_in calls reach 1.1^20" "$(status_value zoom)" "6.73"
  expect_equal "compositor holds 1.1^20" \
    "$(printf '%.2f' "$(option_value cursor:zoom_factor)")" "6.73"
  engine 'return HyprZoom.reset()' > /dev/null
}

# check_tracking_modes — every tracking mode sets the verified camera options (via preview).
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_tracking_modes() {
  local mode expected actual
  # name:rigid:detached as measured in spike S1 (Q7).
  for mode in centered:true:false edge:false:true follow:false:false; do
    engine "return HyprZoom.preview({ ZOOM_TRACKING = '${mode%%:*}' })" > /dev/null
    expected="${mode#*:}"
    actual="$(option_value cursor:zoom_rigid):$(option_value cursor:zoom_detached_camera)"
    expect_equal "tracking ${mode%%:*} sets rigid/detached" "$actual" "$expected"
  done
  # margin needs the plugin: without it the effective mode must degrade to edge.
  engine "return HyprZoom.preview({ ZOOM_TRACKING = 'margin' })" > /dev/null
  expect_equal "margin falls back to edge without plugin" \
    "$(status_value tracking_effective)" "edge"
  engine 'return HyprZoom.preview_end()' > /dev/null
}

# check_zoom_pixels — the screen really magnifies (stripe width scales with the zoom).
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK
check_zoom_pixels() {
  local level width
  # Pointer in the middle so the centred view shows the stripe band.
  nested ctl dispatch 'hl.dsp.cursor.move({x=640,y=360})' > /dev/null
  for level in 1 2 3; do
    engine "return HyprZoom.set_zoom($level)" > /dev/null
    sleep 1
    nested shot "$WORK/zoom-$level.png"
    width="$(python3 "$PIXELS" stripe "$WORK/zoom-$level.png" 360)"
    expect_equal "stripe width at zoom $level is about $((40 * level)) px" \
      "$(( (width - 40 * level) * (width - 40 * level) <= 25 ? 1 : 0 ))" "1"
  done
  engine 'return HyprZoom.reset()' > /dev/null
  sleep 1
}

# check_screen — compare the screen with the prediction for a filter.
# Args:    $1 label; $2 filter name or "none"; remaining: KEY=VALUE adjustments
# Returns: 0 always; prints PASS/FAIL
# Globals: reads WORK
check_screen() {
  local label="$1" filter_name="$2"
  shift 2
  # Give Hyprland a moment to reload the shader before the screenshot.
  sleep 0.7
  nested shot "$WORK/screen.png"
  expect_command "$label" python3 "$PIXELS" check "$WORK/screen.png" "$filter_name" "$@"
}

# check_filters — every schema filter renders the predicted pixels; off restores the screen.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads REPO
check_filters() {
  local name names
  # The filter list comes from the schema: the single source of truth (E3).
  names="$(sed -n 's/^FILTER|enum|[^|]*|\([^|]*\)|.*/\1/p' "$REPO/config/settings.schema")"
  check_screen "baseline pattern is unfiltered" none
  for name in ${names//,/ }; do
    engine "return HyprZoom.filter('$name')" > /dev/null
    check_screen "filter $name pixels" "$name"
  done
  engine "return HyprZoom.filter('off')" > /dev/null
  check_screen "filter off restores the original pixels" none
  expect_equal "screen_shader option empty after off" "$(option_value decoration:screen_shader)" ""
}

# check_filter_adjustments — intensity/contrast/brightness/saturation are baked in correctly.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_filter_adjustments() {
  engine "return HyprZoom.preview({ FILTER_ACTIVE = 'on', FILTER = 'invert', \
FILTER_INTENSITY = '0.5', FILTER_CONTRAST = '1.5', FILTER_BRIGHTNESS = '0.1', \
FILTER_SATURATION = '0.5' })" > /dev/null
  check_screen "invert with intensity/contrast/brightness/saturation" invert \
    intensity=0.5 contrast=1.5 brightness=0.1 saturation=0.5
  engine 'return HyprZoom.preview_end()' > /dev/null
  check_screen "preview_end restores the original pixels" none
}

# check_user_shader — the user's own screen shader survives a filter on/off cycle.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK
check_user_shader() {
  local shader="$WORK/user-shader.frag"
  # A plain inversion shader stands in for the user's own one.
  printf '%s\n' '#version 300 es' 'precision highp float;' 'in vec2 v_texcoord;' \
    'layout(location = 0) out vec4 fragColor;' 'uniform sampler2D tex;' \
    'void main() { vec4 c = texture(tex, v_texcoord); fragColor = vec4(1.0 - c.rgb, c.a); }' \
    > "$shader"
  engine "hl.config({ decoration = { screen_shader = '$shader' } }) return 'set'" > /dev/null
  check_screen "user shader is active (inverts)" invert
  engine "return HyprZoom.filter('grayscale')" > /dev/null
  check_screen "engine filter replaces the user shader" grayscale
  engine "return HyprZoom.filter('off')" > /dev/null
  check_screen "user shader is restored after filter off" invert
  expect_equal "screen_shader option is the user's path again" \
    "$(option_value decoration:screen_shader)" "$shader"
  engine "hl.config({ decoration = { screen_shader = '' } }) return 'cleared'" > /dev/null
}

# check_only_when_zoomed — FILTER_ONLY_WHEN_ZOOMED switches the shader at the 1.0 boundary.
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_only_when_zoomed() {
  engine "return HyprZoom.preview({ FILTER_ONLY_WHEN_ZOOMED = 'on', FILTER_ACTIVE = 'on' })" \
    > /dev/null
  expect_equal "no shader while unzoomed" "$(option_value decoration:screen_shader)" ""
  engine 'return HyprZoom.zoom_in()' > /dev/null
  expect_contains "shader applied while zoomed" "$(option_value decoration:screen_shader)" ".frag"
  engine 'return HyprZoom.reset()' > /dev/null
  # The release waits for the zoom-out animation, so poll instead of checking at once.
  expect_command "shader removed after reset (once the animation ended)" wait_until 3 shader_is_unset
  engine 'return HyprZoom.preview_end()' > /dev/null
}

# config_errors — print the compositor's current config errors (empty when there are none).
# Args:    none
# Returns: 0 always; stdout: the error lines without blank lines
# Globals: none
config_errors() {
  nested ctl configerrors | grep -v '^[[:space:]]*$' || true
}

# expect_no_config_errors — the red "config has errors" bar must stay away (R-P1a-01, R-P2-01).
# Args:    $1 label
# Returns: 0 always; prints PASS/FAIL (with the errors on failure)
# Globals: writes PASS_COUNT, FAIL_COUNT
expect_no_config_errors() {
  expect_equal "$1: no config errors" "$(config_errors)" ""
}

# check_no_config_errors — load, reload, set and preview leave the config error list empty.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK
check_no_config_errors() {
  local label="${1:-without the plugin}"
  expect_no_config_errors "after load $label"
  # A real Hyprland reload re-runs the whole config, which used to set the missing plugin keys.
  nested ctl reload > /dev/null
  wait_until 10 engine 'return HyprZoom.status()'
  sleep 0.5
  expect_no_config_errors "after reload $label"
  engine 'return HyprZoom.reload()' > /dev/null
  expect_no_config_errors "after HyprZoom.reload() $label"
  engine "return HyprZoom.preview({ ZOOM_TRACKING = 'margin', ZOOM_EDGE_MARGIN = '0.20' })" \
    > /dev/null
  expect_no_config_errors "after preview $label"
  engine 'return HyprZoom.preview_end()' > /dev/null
  expect_no_config_errors "after preview_end $label"
}

# check_external_unbind — a bind another script removed must not crash the compositor (R-P1a-02).
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_external_unbind() {
  # Unbinding one of the engine's chords expires its handle; Hyprland 0.56.2 segfaults when the
  # engine later calls remove() on it, so the engine must check the handle first.
  engine 'hl.unbind("SUPER + ALT + I") return "unbound"' > /dev/null
  engine "return HyprZoom.preview({ BIND_KEY_IN = 'K' })" > /dev/null
  expect_equal "compositor survives an external unbind plus a bind change" \
    "$(nested ctl version > /dev/null 2>&1 && echo alive)" "alive"
  expect_contains "the engine rebuilt its binds after the external unbind" \
    "$(nested ctl -j binds | jq -r '.[] | "\(.modmask) \(.key)"')" "72 K"
  engine 'return HyprZoom.preview_end()' > /dev/null
  expect_equal "engine answers after preview_end" "$(status_value engine)" "lua"
}

# check_smart_invert_contrast — link-blue text keeps WCAG contrast on the filtered screen.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK, PIXELS
check_smart_invert_contrast() {
  engine "return HyprZoom.filter('smart-invert')" > /dev/null
  sleep 0.7
  nested shot "$WORK/contrast.png"
  expect_command "smart-invert keeps blue link text readable (contrast >= 4.5)" \
    python3 "$PIXELS" contrast "$WORK/contrast.png"
  engine "return HyprZoom.filter('off')" > /dev/null
}

# shader_is_set — test whether decoration:screen_shader currently holds a path.
# Args:    none
# Returns: 0 when a screen shader is set; 1 otherwise
# Globals: none
shader_is_set() {
  [[ -n "$(option_value decoration:screen_shader)" ]]
}

# shader_is_unset — the opposite of shader_is_set (usable with wait_until).
# Args:    none
# Returns: 0 when no screen shader is set; 1 otherwise
# Globals: none
shader_is_unset() {
  ! shader_is_set
}

# check_filter_held_during_zoom_out — FILTER_ONLY_WHEN_ZOOMED waits for the animation (R-P1a-12).
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_filter_held_during_zoom_out() {
  local started elapsed_ms
  # Speed 10 = a one second animation, long enough to observe from a shell.
  engine "return HyprZoom.preview({ FILTER_ONLY_WHEN_ZOOMED = 'on', FILTER_ACTIVE = 'on', \
ZOOM_ANIMATION_SPEED = '10.00' })" > /dev/null
  engine 'return HyprZoom.zoom_in(5)' > /dev/null
  expect_equal "filter applied while zoomed" "$(shader_is_set && echo set)" "set"
  engine 'return HyprZoom.reset()' > /dev/null
  started=$(date +%s%N)
  expect_equal "filter still applied right after the zoom-out started" \
    "$(shader_is_set && echo set)" "set"
  wait_until 5 shader_is_unset
  elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))
  expect_equal "filter released about when the 1 s animation ended (>= 700 ms)" \
    "$(( elapsed_ms >= 700 ? 1 : 0 ))" "1"
  expect_equal "filter is gone afterwards" "$(shader_is_set && echo set || echo none)" "none"
  engine 'return HyprZoom.preview_end()' > /dev/null
}

# build_plugin — build plugin/hyprzoom.so for the plugin sections.
# Args:    none
# Returns: 0 when the plugin is built; 77 when the headers are missing (skip); other: failure
# Globals: reads REPO, WORK
build_plugin() {
  mkdir -p "$WORK"
  # The build log stays in the work directory; it is only shown when something went wrong.
  bash "$REPO/tests/plugin/build.sh" > "$WORK/plugin-build.log" 2>&1
}

# plugin_state — print the plugin entry of the engine status.
# Args:    none
# Returns: 0 always; stdout: loaded or missing
# Globals: none
plugin_state() {
  status_value plugin
}

# plugin_is_loaded — usable with wait_until: the engine sees the plugin.
# Args:    none
# Returns: 0 when status says plugin=loaded
# Globals: none
plugin_is_loaded() {
  [[ "$(plugin_state)" == loaded ]]
}

# plugin_is_missing — usable with wait_until: the engine no longer sees the plugin.
# Args:    none
# Returns: 0 when status says plugin=missing
# Globals: none
plugin_is_missing() {
  [[ "$(plugin_state)" == missing ]]
}

# check_plugin_lifecycle — engine first, plugin loaded later, plugin unloaded again (R-P1a-03).
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK, PLUGIN_SO
check_plugin_lifecycle() {
  # Margin mode with a visible margin; the engine is already running without the plugin.
  printf 'ZOOM_ANIMATION_SPEED=0.10\nZOOM_TRACKING=margin\nZOOM_EDGE_MARGIN=0.30\n' \
    > "$WORK/user.conf"
  engine 'return HyprZoom.reload()' > /dev/null
  expect_equal "margin falls back to edge before the plugin is loaded" \
    "$(status_value tracking_effective)" "edge"
  expect_no_config_errors "margin configured, plugin absent"
  # No manual HyprZoom.reload(): Hyprland reloads the config after a plugin load and the engine
  # re-applies (the plugin cannot do it itself, it is not listed yet while its init runs).
  nested ctl plugin load "$PLUGIN_SO" > /dev/null
  expect_command "engine sees the plugin that loaded later (no manual reload)" \
    wait_until 10 plugin_is_loaded
  expect_equal "margin is active after the late plugin load" \
    "$(status_value tracking_effective)" "margin"
  expect_equal "plugin edge_margin is the configured 0.30" \
    "$(printf '%.2f' "$(option_value plugin:hyprzoom:edge_margin)")" "0.30"
  expect_no_config_errors "plugin loaded later"
  check_no_config_errors "with the plugin"
  expect_equal "margin survives a Hyprland reload" "$(status_value tracking_effective)" "margin"
  nested ctl plugin unload "$PLUGIN_SO" > /dev/null
  expect_command "engine notices the unloaded plugin (no manual reload)" \
    wait_until 10 plugin_is_missing
  expect_equal "margin falls back to edge after the plugin unloaded" \
    "$(status_value tracking_effective)" "edge"
  expect_no_config_errors "plugin unloaded"
  printf 'ZOOM_ANIMATION_SPEED=0.10\n' > "$WORK/user.conf"
  engine 'return HyprZoom.reload()' > /dev/null
}

# filter_is_active — test whether the engine reports the filter as switched on.
# Args:    none
# Returns: 0 when filter_active=on; 1 otherwise (also while the engine is reloading)
# Globals: none
filter_is_active() {
  [[ "$(status_value filter_active)" == on ]]
}

# check_reload_restores — a Hyprland reload keeps zoom, filter and binds (E10).
# Args:    none
# Returns: 0 always; prints results
# Globals: none
check_reload_restores() {
  engine 'HyprZoom.set_zoom(3) return HyprZoom.filter("grayscale")' > /dev/null
  nested ctl reload > /dev/null
  # The Lua state restarts; wait until the restored filter shows up in the status.
  wait_until 10 filter_is_active
  expect_equal "zoom survives reload" "$(status_value zoom)" "3.00"
  expect_equal "compositor zoom_factor restored" \
    "$(printf '%.2f' "$(option_value cursor:zoom_factor)")" "3.00"
  expect_equal "filter survives reload" "$(status_value filter)" "grayscale"
  expect_contains "shader applied after reload" "$(option_value decoration:screen_shader)" ".frag"
  expect_equal "scroll_event_delay re-applied after reload" \
    "$(option_value binds:scroll_event_delay)" "0"
  expect_equal "still exactly one bind on SUPER+ALT+mouse_up" \
    "$(nested ctl -j binds | jq '[.[] | select(.key == "mouse_up" and .modmask == 72)] | length')" \
    "1"
  engine 'HyprZoom.filter("off") return HyprZoom.reset()' > /dev/null
}

# scroll_log_lines — count the mouse-report lines the logging terminal received.
# Args:    $1 log file
# Returns: 0 always; stdout: number of lines that are not the READY marker
# Globals: none
scroll_log_lines() {
  grep -vc '^READY' "$1" || true
}

# send_control_notch — send unmodified notches until the client's log shows one.
# Args:    $1 wayland display; $2 log file of the mouse logger
# Returns: 0 when a notch reached the client within three attempts; 1 otherwise
# Globals: reads HERE
send_control_notch() {
  # The first motion gives the new window pointer focus; later attempts cover slow mapping.
  for _ in 1 2 3; do
    python3 "$HERE/virtual_pointer.py" "$1" move:3,0 sleep:150 move:-3,0 sleep:150 up sleep:300
    [[ "$(scroll_log_lines "$2")" -gt 0 ]] && return 0
  done
  return 1
}

# check_scroll_notches — real SUPER+ALT+wheel notches: all zoom, none leaks to the client.
# Args:    none
# Returns: 0 always; prints results
# Globals: reads WORK, HERE
check_scroll_notches() {
  local log="$WORK/mouse.log" display
  display="$(nested wl)"
  : > "$log"
  # A terminal in mouse-reporting mode shows every notch that reaches a client.
  nested run foot -e python3 "$HERE/mouse_logger.py" "$log"
  wait_until 10 grep -q READY "$log"
  nested ctl dispatch 'hl.dsp.cursor.move({x=640,y=360})' > /dev/null
  # Control: a plain notch without modifiers MUST reach the client, or the probe is blind.
  expect_command "control: unmodified notch reaches the client" \
    send_control_notch "$display" "$log"
  : > "$log"
  hold_super_alt_and_scroll "$display" down*20
  expect_equal "20 fast SUPER+ALT+scroll notches all zoom" "$(status_value zoom)" "6.73"
  expect_equal "no notch leaked to the client" "$(scroll_log_lines "$log")" "0"
  hold_super_alt_and_scroll "$display" up*20
  expect_equal "20 fast notches up return to 1.00" "$(status_value zoom)" "1.00"
  nested ctl dispatch 'hl.dsp.window.close()' > /dev/null
}

# hold_super_alt_and_scroll — press SUPER+ALT, send wheel steps, release.
# Args:    $1 wayland display; remaining: virtual_pointer.py steps
# Returns: 0 always
# Globals: reads HERE
hold_super_alt_and_scroll() {
  local display="$1"
  shift
  # wtype holds the modifiers for 2.5 s in the background while the notches are sent.
  WAYLAND_DISPLAY="$display" wtype -M logo -M alt -s 2500 -m alt -m logo &
  sleep 0.8
  python3 "$HERE/virtual_pointer.py" "$display" move:3,0 sleep:100 "$@"
  wait
  sleep 0.3
}

# show_pattern — display the colour pattern fullscreen in the nested instance.
# Args:    none
# Returns: 0 when the window is up; 1 otherwise
# Globals: reads WORK
show_pattern() {
  python3 "$PIXELS" make "$WORK/pattern.png"
  nested run imv -f "$WORK/pattern.png"
  sleep 2.5
}

# run_plugin_section — build the plugin and run its lifecycle checks, or say why not.
# Args:    none
# Returns: 0 always; prints results or a SKIP line
# Globals: reads WORK
run_plugin_section() {
  local build_status=0
  build_plugin || build_status=$?
  if [[ "$build_status" -eq 77 ]]; then
    echo "SKIP plugin lifecycle: hyprland headers not installed"
  elif [[ "$build_status" -ne 0 ]]; then
    record_result FAIL "plugin build failed (see $WORK/plugin-build.log)"
  else
    check_plugin_lifecycle
  fi
}

# summarize — print the totals and return the overall status.
# Args:    none
# Returns: 0 when nothing failed; 1 otherwise
# Globals: reads PASS_COUNT, FAIL_COUNT
summarize() {
  echo "engine nested test: $PASS_COUNT passed, $FAIL_COUNT failed"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

# main — run all checks in a nested Hyprland.
# Args:    none
# Returns: 0 when everything passed or the test was skipped; 1 otherwise
# Globals: none
main() {
  local reason
  # SKIP (not fail) where the test cannot run at all, with a clear reason.
  if reason="$(should_skip)"; then
    echo "SKIP engine nested test: $reason"
    return 0
  fi
  write_nested_config
  trap stop_nested EXIT
  start_nested || { echo "FAIL nested Hyprland or engine did not start"; return 1; }
  check_engine_loaded
  check_no_config_errors
  check_binds
  check_external_unbind
  check_zoom_steps
  check_rapid_notches
  check_tracking_modes
  check_scroll_notches
  show_pattern
  check_zoom_pixels
  check_filters
  check_smart_invert_contrast
  check_filter_adjustments
  check_user_shader
  check_only_when_zoomed
  check_filter_held_during_zoom_out
  check_reload_restores
  run_plugin_section
  summarize
}

main "$@"
