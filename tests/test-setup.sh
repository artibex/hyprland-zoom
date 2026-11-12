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
# Globals: reads TEST_ENV, ZC_EXTRA_ENV
run_hook() {
  HOOK_OUT="$("${TEST_ENV[@]}" "${ZC_EXTRA_ENV[@]}" bash -c \
    "source '$TEST_ROOT/install/post_install.sh'; $1" 2>&1 </dev/null)"
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

# test_first_config — a user without any Hyprland config gets the file the installed release reads.
# Args:    none
# Returns: 0 always
# Globals: none
test_first_config() {
  rm -rf "$HYPR_DIR"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$ENGINE_LINE" "first config: Hyprland 0.56 gets hyprland.lua"
  assert_eq 644 "$(stat -c '%a' "$LUA_FILE")" "first config: new file is 0644, never writable by others"
  assert_no_file "$CONF_FILE" "first config: no hyprland.conf next to it"
  rm -rf "$HYPR_DIR"
  printf '0.54.3\n' > "$FAKE_DIR/version"
  run_zoomctl setup
  assert_file_content "$CONF_FILE" "$CONF_LINE" "first config: Hyprland 0.54 gets hyprland.conf"
  assert_no_file "$LUA_FILE" "first config: no Lua config for a release that cannot read it"
  rm -rf "$HYPR_DIR" "$FAKE_DIR/version"
  set_fake_mode unreachable
  printf '0.56.0\n' > "$FAKE_DIR/binary_version"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$ENGINE_LINE" "first config: no session, the Hyprland binary says 0.56"
  rm -rf "$HYPR_DIR" "$FAKE_DIR/binary_version"
  run_zoomctl setup
  assert_file_content "$CONF_FILE" "$CONF_LINE" "first config: version unknown -> the conf every release reads"
  set_fake_mode engine
}

# test_include_shapes — annotated, semicolon, paren-less and single-quoted includes all count.
# Args:    none
# Returns: 0 always
# Globals: none
test_include_shapes() {
  local engine_path="$TEST_SANDBOX/share/hyprland-zoom.lua" shape
  for shape in "dofile(\"$engine_path\") -- zoom" "dofile(\"$engine_path\");" \
    "dofile \"$engine_path\"" "dofile('$engine_path')" "  dofile ( \"$engine_path\" ) ; -- x"; do
    fresh_hypr
    printf -- '-- top\n%s\n' "$shape" > "$LUA_FILE"
    run_zoomctl setup
    assert_file_content "$LUA_FILE" $'-- top\n'"$shape" "include shape [$shape]: left as it is"
    assert_eq 0 "$(count_backups "$LUA_FILE")" "include shape [$shape]: no backup, no rewrite"
  done
  for shape in 'dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua"); -- old' \
    'dofile "/usr/share/hyprland-zoom/hyprland-bindings.lua"' \
    "dofile('/usr/share/hyprland-zoom/hyprland-bindings.lua') -- x"; do
    fresh_hypr
    printf '%s\nhl.config({})\n' "$shape" > "$LUA_FILE"
    run_zoomctl setup
    assert_file_content "$LUA_FILE" "$ENGINE_LINE"$'\nhl.config({})' "0.1 shape [$shape]: migrated in place"
  done
}

# test_custom_engine_path — a user's own engine include is left alone, nothing is added.
# Args:    none
# Returns: 0 always
# Globals: none
test_custom_engine_path() {
  local custom='dofile("/home/dev/src/hyprland-zoom/src/lua/hyprland-zoom.lua")'
  fresh_hypr
  printf -- '-- dev\n%s\n' "$custom" > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" $'-- dev\n'"$custom" "custom engine: file byte-identical"
  assert_eq 0 "$(count_backups "$LUA_FILE")" "custom engine: no backup"
  fresh_hypr
  printf '%s\ndofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")\n' "$custom" > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$custom" "custom engine: a second package load is dropped"
  fresh_hypr
  printf '%s\n' "$custom" > "$LUA_FILE"
  run_hook post_remove
  assert_file_content "$LUA_FILE" "$custom" "custom engine: uninstall keeps the user's own line"
  fresh_hypr
  printf 'dofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")\n' > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" "$ENGINE_LINE" "package path: rewritten to the share dir"
}

# test_trailing_return — the include goes before a top-level `return`, and luac guards the result.
# Args:    none
# Returns: 0 always
# Globals: none
test_trailing_return() {
  fresh_hypr
  printf 'local M = {}\nM.x = 1\nreturn M\n' > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" $'local M = {}\nM.x = 1\n'"$ENGINE_LINE"$'\nreturn M' \
    "return: include inserted before the trailing return"
  fresh_hypr
  printf 'local function f()\nreturn 1\nend\nf()\n' > "$LUA_FILE"
  run_zoomctl setup
  assert_file_content "$LUA_FILE" $'local function f()\nreturn 1\nend\nf()\n'"$ENGINE_LINE" \
    "return: an unindented return inside a function is not top level"
  command -v luac >/dev/null 2>&1 || { pass "luac: not installed here (syntax guard skipped)"; return 0; }
  fresh_hypr
  printf 'hl.config({\n' > "$LUA_FILE"
  run_zoomctl setup
  assert_status 1 "luac: an edit that would not parse is refused"
  assert_contains "$ZC_ERR" "would not parse" "luac: the reason is named"
  assert_file_content "$LUA_FILE" 'hl.config({' "luac: the original is untouched"
  assert_eq 0 "$(count_backups "$LUA_FILE")" "luac: no backup of a refused edit"
  assert_eq "hyprland.lua" "$(ls -A "$HYPR_DIR")" "luac: no draft left behind"
}

# test_symlinked_wiring — dotfile symlinks stay links, the target is edited, modes stay sane.
# Args:    none
# Returns: 0 always
# Globals: none
test_symlinked_wiring() {
  local dots="$TEST_SANDBOX/dots"
  fresh_hypr
  rm -rf "$dots"
  mkdir -p "$dots"
  printf -- '-- cfg\n' > "$dots/hyprland.lua"
  printf '# conf\n' > "$dots/hyprland.conf"
  chmod 640 "$dots/hyprland.lua"
  ln -s "$dots/hyprland.lua" "$LUA_FILE"
  ln -s "$dots/hyprland.conf" "$CONF_FILE"
  run_zoomctl setup
  assert_status 0 "symlink setup: exit status"
  assert_symlink "$LUA_FILE" "$dots/hyprland.lua" "symlink setup: hyprland.lua is still a link"
  assert_symlink "$CONF_FILE" "$dots/hyprland.conf" "symlink setup: hyprland.conf is still a link"
  assert_file_content "$dots/hyprland.lua" $'-- cfg\n'"$ENGINE_LINE" "symlink setup: the target got the include"
  assert_file_content "$dots/hyprland.conf" $'# conf\n'"$CONF_LINE" "symlink setup: the conf target too"
  assert_eq 640 "$(stat -c '%a' "$dots/hyprland.lua")" "symlink setup: the target mode is kept"
  assert_eq 644 "$(stat -c '%a' "$dots/hyprland.conf")" "symlink setup: never the link's 777"
  run_hook post_remove
  assert_symlink "$LUA_FILE" "$dots/hyprland.lua" "symlink remove: link kept while lines remain"
  assert_file_content "$dots/hyprland.lua" '-- cfg' "symlink remove: only our line is gone"
}

# test_conf_ownership — only our own `source =` line counts; a user's similar line is theirs.
# Args:    none
# Returns: 0 always
# Globals: none
test_conf_ownership() {
  local foreign='source = /home/me/hyprland-bindings.conf'
  fresh_hypr
  printf '%s\n' "$foreign" > "$CONF_FILE"
  run_zoomctl setup
  assert_file_content "$CONF_FILE" "$foreign"$'\n'"$CONF_LINE" "conf: a foreign bindings file does not count as ours"
  run_hook post_remove
  assert_file_content "$CONF_FILE" "$foreign" "conf: uninstall removes our line and keeps the user's own"
  fresh_hypr
  printf '%s # zoom\n' "$CONF_LINE" > "$CONF_FILE"
  run_zoomctl setup
  assert_eq 1 "$(grep -c 'hyprland-bindings.conf' "$CONF_FILE")" "conf: a trailing comment does not hide our line"
}

# install_root_stubs — fake id (uid 0) and chown (records its arguments) for the root hook path.
# Args:    none
# Returns: 0 always; writes $TEST_SANDBOX/rootbin and clears the chown log
# Globals: reads TEST_SANDBOX, FAKE_DIR
install_root_stubs() {
  local stub_dir="$TEST_SANDBOX/rootbin"
  mkdir -p "$stub_dir"
  # shellcheck disable=SC2016  # the stub expands its own arguments, when it runs
  printf '#!/bin/sh\ncase "$1" in -u) echo 0 ;; -gn) echo testers ;; *) /usr/bin/id "$@" ;; esac\n' \
    > "$stub_dir/id"
  printf '#!/bin/sh\necho "$*" >> "%s/chown.log"\n' "$FAKE_DIR" > "$stub_dir/chown"
  chmod +x "$stub_dir/id" "$stub_dir/chown"
  : > "$FAKE_DIR/chown.log"
}

# test_root_hook — as root the hook hands files back, uses unguessable backup names, and refuses links.
# Args:    none
# Returns: 0 always
# Globals: none
test_root_hook() {
  local dots="$TEST_SANDBOX/dots" chown_log
  install_root_stubs
  ZC_EXTRA_ENV=("PATH=$TEST_SANDBOX/rootbin:$TEST_SANDBOX/bin:/usr/bin:/bin" ZOOMCTL_TARGET_USER=tester)
  fresh_hypr
  printf -- '-- cfg\n' > "$LUA_FILE"
  run_hook post_install
  chown_log="$(<"$FAKE_DIR/chown.log")"
  assert_contains "$chown_log" "-h tester:testers $LUA_FILE" "root hook: the edited file is chowned to the user (no -h-less chown)"
  assert_contains "$chown_log" ".zoomctl-bak-" "root hook: the backup is handed to the user too"
  assert_eq 1 "$(find "$HYPR_DIR" -maxdepth 1 -name '*.zoomctl-bak-*-??????' | grep -c .)" \
    "root hook: backup name carries a random part"
  fresh_hypr
  mkdir -p "$dots"
  printf 'secret\n' > "$dots/target"
  ln -s "$dots/target" "$LUA_FILE"
  run_hook post_install
  assert_file_content "$dots/target" "secret" "root hook: a symlinked hyprland.lua is never followed"
  assert_contains "$HOOK_OUT" "Could not automatically update" "root hook: falls back to instructions"
  fresh_hypr
  rm -rf "$dots/hypr"
  mkdir -p "$dots/hypr"
  printf -- '-- cfg\n' > "$dots/hypr/hyprland.lua"
  rm -rf "$HYPR_DIR"
  ln -s "$dots/hypr" "$HYPR_DIR"
  run_hook post_install
  assert_file_content "$dots/hypr/hyprland.lua" '-- cfg' "root hook: a symlinked config directory is refused"
  ZC_EXTRA_ENV=()
  rm -f "$HYPR_DIR"
  mkdir -p "$HYPR_DIR"
}

# test_target_home_guards — root's own home and unknown sudo users are never a target.
# Args:    none
# Returns: 0 always
# Globals: none
test_target_home_guards() {
  ZC_EXTRA_ENV=(ZOOMCTL_TARGET_HOME= HOME=/root)
  run_lib_function zoomctl_target_home
  assert_status 1 "target home: HOME=/root is no target"
  assert_eq "" "$ZC_OUT" "target home: nothing printed for root's home"
  ZC_EXTRA_ENV=(ZOOMCTL_TARGET_HOME= SUDO_USER=nosuchuser9)
  run_lib_function zoomctl_target_home
  assert_status 1 "target home: an unresolvable SUDO_USER is refused"
  assert_eq "" "$ZC_OUT" "target home: no path (not /.config) for an unknown user"
  run_zoomctl setup
  assert_status 1 "setup: an unresolvable SUDO_USER fails"
  assert_contains "$ZC_ERR" "no usable home directory" "setup: the real cause is named"
  ZC_EXTRA_ENV=(ZOOMCTL_TARGET_HOME= HOME="$TEST_SANDBOX/home")
  run_lib_function zoomctl_target_home
  assert_eq "$TEST_SANDBOX/home" "$ZC_OUT" "target home: a normal HOME is used"
  ZC_EXTRA_ENV=()
}

test_lua_setup
test_migration_01
test_setup_edge_cases
test_first_config
test_include_shapes
test_custom_engine_path
test_trailing_return
test_symlinked_wiring
test_conf_ownership
test_hooks
test_root_hook
test_target_home_guards
test_hook_without_target
test_wiring_block_in_sync
test_finish
