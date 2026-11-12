#!/usr/bin/env bash
# test-setup.sh — suite: `zoomctl setup` wiring and migration, and the pacman hooks of
# install/post_install.sh (post_install, post_upgrade, post_remove) incl. the sync guard.
set -u

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/test-lib.sh"
test_init setup

# Locations inside the sandbox (ZOOMCTL_TARGET_HOME points at the sandbox home).
HYPR_DIR="$TEST_SANDBOX/home/.config/hypr"
LUA_FILE="$HYPR_DIR/hyprland.lua"
CONF_FILE="$HYPR_DIR/hyprland.conf"
ENGINE_LINE="dofile(\"$TEST_SANDBOX/share/hyprland-zoom.lua\")"
OLD_LUA_LINE='dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua")'
CONF_LINE="source = $TEST_SANDBOX/share/hyprland-bindings.conf"

# fresh_hypr — empty the Hyprland config directory.
# Args:    none
# Returns: 0 always
# Globals: removes and recreates HYPR_DIR
fresh_hypr() {
  rm -rf "$HYPR_DIR"
  mkdir -p "$HYPR_DIR"
}

# count_lines — count the lines of a file that equal a text exactly.
# Args:    $1 file; $2 exact line
# Returns: 0 always; stdout: the count
# Globals: none
count_lines() {
  grep -cFx -- "$2" "$1" || true
}

# count_backups — count the backup copies next to a config file.
# Args:    $1 config file
# Returns: 0 always; stdout: the count
# Globals: none
count_backups() {
  find "$(dirname -- "$1")" -maxdepth 1 -name "$(basename -- "$1").zoomctl-bak-*" | wc -l
}

# test_lua_setup — Lua wiring: appended include, backup, conf kept in sync, idempotency.
# Args:    none
# Returns: 0 always
# Globals: none
test_lua_setup() {
  fresh_hypr
  printf -- '-- my config\nhl.config({})\n' > "$LUA_FILE"
  printf '# legacy\n' > "$CONF_FILE"
  run_zoomctl setup
  assert_status 0 "setup lua: exit status"
  assert_file_content "$LUA_FILE" $'-- my config\nhl.config({})\n'"$ENGINE_LINE" \
    "setup lua: include appended after the user's lines"
  assert_file_content "$CONF_FILE" $'# legacy\n'"$CONF_LINE" "setup lua: legacy conf include kept in sync"
  assert_eq 1 "$(count_backups "$LUA_FILE")" "setup lua: one backup before the edit"
  assert_eq $'-- my config\nhl.config({})' "$(cat "$LUA_FILE".zoomctl-bak-*)" \
    "setup lua: backup holds the original"
  assert_contains "$ZC_ERR" "backup of" "setup lua: backup announced"
  run_zoomctl setup
  assert_eq 1 "$(count_lines "$LUA_FILE" "$ENGINE_LINE")" "setup lua: idempotent (one include)"
  assert_eq 1 "$(count_lines "$CONF_FILE" "$CONF_LINE")" "setup lua: idempotent conf (one include)"
  assert_eq 1 "$(count_backups "$LUA_FILE")" "setup lua: no new backup when nothing changes"
  assert_contains "$ZC_OUT" "already present" "setup lua: says it is already wired"
}

# test_migration_01 — the 0.1 dofile line is replaced in place, not duplicated.
# Args:    none
# Returns: 0 always
# Globals: none
test_migration_01() {
  fresh_hypr
  printf -- '-- top\n%s\nhl.config({})\n' "$OLD_LUA_LINE" > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" $'-- top\n'"$ENGINE_LINE"$'\nhl.config({})' \
    "migration: 0.1 line replaced at the same position"
  assert_eq 1 "$(count_backups "$LUA_FILE")" "migration: backup made"
  assert_not_contains "$(<"$LUA_FILE")" "hyprland-bindings.lua" "migration: no 0.1 reference left"
  fresh_hypr
  printf 'dofile("%s/hyprland-bindings.lua")\n' "$TEST_SANDBOX/share" > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$ENGINE_LINE" "migration: 0.1 line with the configured share dir"
  fresh_hypr
  printf '%s\n%s\n' "$OLD_LUA_LINE" "$ENGINE_LINE" > "$LUA_FILE"
  run_zoomctl setup
  assert_eq 1 "$(count_lines "$LUA_FILE" "$ENGINE_LINE")" "migration: 0.1 plus 0.2 line collapse into one"
  assert_not_contains "$(<"$LUA_FILE")" "hyprland-bindings.lua" "migration: duplicate 0.1 line removed"
  fresh_hypr
  printf -- '-- %s\ndofile("/home/me/other/hyprland-bindings.lua")\n' "$OLD_LUA_LINE" > "$LUA_FILE"
  run_zoomctl setup
  assert_contains "$(<"$LUA_FILE")" "-- $OLD_LUA_LINE" "migration: commented-out line untouched"
  assert_contains "$(<"$LUA_FILE")" 'dofile("/home/me/other/hyprland-bindings.lua")' \
    "migration: the user's own bindings file untouched"
  assert_eq 1 "$(count_lines "$LUA_FILE" "$ENGINE_LINE")" "migration: engine line added next to foreign includes"
}

# test_setup_edge_cases — fresh home, no trailing newline, Lua without conf, empty file, modes.
# Args:    none
# Returns: 0 always
# Globals: none
test_setup_edge_cases() {
  rm -rf "$HYPR_DIR"
  run_zoomctl setup
  assert_file_content "$CONF_FILE" "$CONF_LINE" "edge: fresh home gets a legacy conf with the include"
  assert_no_file "$LUA_FILE" "edge: no Lua config invented"
  fresh_hypr
  printf -- '-- no trailing newline' > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" $'-- no trailing newline\n'"$ENGINE_LINE" \
    "edge: include never glued to the last line"
  assert_no_file "$CONF_FILE" "edge: Lua-only setup does not create hyprland.conf"
  fresh_hypr
  : > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$ENGINE_LINE" "edge: empty Lua file"
  fresh_hypr
  printf 'monitor = ,preferred,auto,1' > "$CONF_FILE"
  run_zoomctl setup
  assert_file_content "$CONF_FILE" $'monitor = ,preferred,auto,1\n'"$CONF_LINE" \
    "edge: conf without trailing newline"
  chmod 600 "$CONF_FILE"
  run_zoomctl setup
  assert_eq 600 "$(stat -c '%a' "$CONF_FILE")" "edge: conf mode preserved"
  fresh_hypr
  printf -- '-- cfg\n' > "$LUA_FILE"
  chmod 640 "$LUA_FILE"
  run_zoomctl setup
  assert_eq 640 "$(stat -c '%a' "$LUA_FILE")" "edge: Lua file mode preserved"
  assert_eq "hyprland.lua" "$(find "$HYPR_DIR" -maxdepth 1 -type f ! -name '*zoomctl-bak*' -printf '%f\n')" "edge: no temp draft left behind"
}

# run_hook — run one scriptlet function in a clean bash with the sandbox environment.
# Args:    $1 function name (post_install|post_upgrade|post_remove)
# Returns: 0 always; sets HOOK_OUT
# Globals: reads TEST_ENV
run_hook() {
  HOOK_OUT="$("${TEST_ENV[@]}" bash -c "source '$TEST_ROOT/install/post_install.sh'; $1" 2>&1 </dev/null)"
}

# test_hooks — post_install, post_upgrade and post_remove behave like the CLI wiring.
# Args:    none
# Returns: 0 always
# Globals: none
test_hooks() {
  fresh_hypr
  printf -- '-- cfg\n' > "$LUA_FILE"
  run_hook post_install
  assert_contains "$(<"$LUA_FILE")" "$ENGINE_LINE" "hook: post_install wires the engine"
  assert_contains "$HOOK_OUT" "installed and wired" "hook: post_install success message"
  assert_not_contains "$HOOK_OUT" "backup of" "hook: backup notice not printed into the transaction"
  fresh_hypr
  printf -- '%s\nhl.config({})\n' "$OLD_LUA_LINE" > "$LUA_FILE"
  run_hook post_upgrade
  assert_file_content "$LUA_FILE" "$ENGINE_LINE"$'\nhl.config({})' "hook: post_upgrade migrates the 0.1 line"
  run_hook post_upgrade
  assert_eq 1 "$(count_lines "$LUA_FILE" "$ENGINE_LINE")" "hook: post_upgrade is idempotent"
  printf '%s\n' "$CONF_LINE" > "$CONF_FILE"
  run_hook post_remove
  assert_not_contains "$(<"$LUA_FILE")" "hyprland-zoom.lua" "hook: post_remove drops the engine line"
  assert_contains "$(<"$LUA_FILE")" "hl.config({})" "hook: post_remove keeps the user's lines"
  assert_no_file "$CONF_FILE" "hook: post_remove deletes a conf that only held our include"
  assert_contains "$HOOK_OUT" "has been removed" "hook: post_remove message"
  fresh_hypr
  printf '%s\n%s\n' "$OLD_LUA_LINE" "hl.config({})" > "$LUA_FILE"
  run_hook post_remove
  assert_file_content "$LUA_FILE" "hl.config({})" "hook: post_remove also drops a leftover 0.1 line"
}

# test_hook_without_target — no user to wire: manual instructions, still exit 0.
# Args:    none
# Returns: 0 always
# Globals: none
test_hook_without_target() {
  local output
  output="$(env -i PATH=/usr/bin:/bin HOME=/root bash -c \
    "source '$TEST_ROOT/install/post_install.sh'; post_install; echo rc=\$?" 2>&1 </dev/null)"
  assert_contains "$output" "Could not automatically update" "hook: no target home -> manual instructions"
  assert_contains "$output" 'dofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")' \
    "hook: instructions name the Lua line"
  assert_contains "$output" "rc=0" "hook: still exits 0"
}

# test_wiring_block_in_sync — the duplicated wiring block must be byte-identical.
# Args:    none
# Returns: 0 always
# Globals: none
test_wiring_block_in_sync() {
  local extract='/shared wiring block: begin/,/shared wiring block: end/p'
  assert_eq "$(sed -n "$extract" "$TEST_ROOT/src/lib/setup.sh")" \
    "$(sed -n "$extract" "$TEST_ROOT/install/post_install.sh")" \
    "post_install.sh wiring block equals src/lib/setup.sh"
  if bash -n "$TEST_ROOT/install/post_install.sh"; then
    pass "post_install.sh parses"
  else
    fail "post_install.sh parses"
  fi
}

test_lua_setup
test_migration_01
test_setup_edge_cases
test_hooks
test_hook_without_target
test_wiring_block_in_sync
test_finish
