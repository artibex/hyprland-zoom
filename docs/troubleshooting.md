# Troubleshooting

Start with `zoomctl doctor`. It checks Hyprland, the Lua engine, the include line in your
config, the settings, the plugin, duplicate binds and the live scroll delay, and prints one
line per check. Include its output and `zoomctl status` when you report a problem.

## Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| Nothing happens on `SUPER + ALT` + scroll | The engine is not loaded | `zoomctl setup`, then `hyprctl reload`; `zoomctl doctor` shows which check fails |
| One notch zooms, the next one scrolls the page | Hyprland's scroll event delay | [see below](#one-notch-zooms-the-next-scrolls-the-window-below) |
| `hyprctl keyword …` does nothing, my script stopped working | Lua configs reject `keyword` | [see below](#hyprctl-keyword-is-rejected) |
| Zoom snaps back to 1.0 when the config reloads | State lost on reload | [see below](#zoom-resets-when-the-config-reloads) |
| A shortcut also does something else | Bind collision (Omarchy and others) | [see below](#shortcut-collisions-with-omarchy-or-your-own-binds) |
| Tracking `margin` behaves like `edge` | The `hyprzoom` plugin is not loaded | [plugin docs](plugin.md#troubleshooting) |
| The plugin stopped working after a Hyprland update | Plugins are tied to one Hyprland build | `hyprpm update && hyprpm reload` |
| The settings window does not open | Missing GTK pieces or running as root | [see below](#the-settings-window-does-not-open) |
| `color filters are not supported on the legacy config` | hyprlang config without the Lua engine | Use a Lua config (Hyprland 0.55+) and run `zoomctl setup` |
| `Hyprland is not reachable` | `zoomctl` runs outside the session | Run it from a terminal inside Hyprland |

## One notch zooms, the next scrolls the window below

Hyprland ignores further scroll events for `binds:scroll_event_delay` (300 ms by default)
after a bind fired — and passes them on to the focused window. hyprland-zoom sets the delay to
0 when the engine loads (`SCROLL_EVENT_DELAY_MS`). If you still see it:

1. `zoomctl status` must print `scroll_event_delay_ms  0`. A different number means another
   piece of config sets `binds.scroll_event_delay` after the engine, or you set
   `SCROLL_EVENT_DELAY_MS` to something else (*Advanced* page).
2. Make sure the `dofile(".../hyprland-zoom.lua")` line is the **last** line of `hyprland.lua`
   (`zoomctl setup` appends it there). Whatever loads later wins.
3. The engine is not loaded at all (`zoomctl doctor`): the old 0.1 binds still run through
   `zoomctl` and lose notches. Run `zoomctl setup` and reload.

## `hyprctl keyword` is rejected

With a Lua config (`hyprland.lua`, Hyprland 0.55+) `hyprctl keyword` is not accepted, so
scripts that still use `hyprctl keyword cursor:zoom_factor 2` silently do nothing — this is
also what broke early 0.1 builds of hyprland-zoom on such setups. Use `zoomctl zoom 2`, or talk
to Hyprland the Lua way:

```bash
hyprctl eval 'hl.config({ cursor = { zoom_factor = 2 } })'
```

hyprland-zoom 0.2 does this for you; `keyword` is only used on the legacy hyprlang config.

## Zoom resets when the config reloads

A Hyprland reload (Omarchy does one on every config save and theme change) resets all options
and the Lua state. hyprland-zoom saves zoom level and filter state to
`$XDG_RUNTIME_DIR/hyprland-zoom/state` and restores them when the engine loads again. If the
zoom is still lost:

- *Keep zoom on config reload* (`ZOOM_RESTORE_ON_RELOAD`, *Advanced* page) is off.
- You started a new Hyprland session: the state belongs to the Hyprland instance that wrote it
  and is deliberately ignored by the next one.
- `$XDG_RUNTIME_DIR` is not writable, so the state file cannot be saved.

## Shortcut collisions with Omarchy or your own binds

Omarchy binds `SUPER + ALT` + scroll to cycle through grouped windows, and `SUPER + CTRL + Z` /
`SUPER + CTRL + ALT + Z` to its own zoom. With *Take over Omarchy zoom keys*
(`BIND_TAKEOVER_OMARCHY`, default on) hyprland-zoom removes the first and takes over the other
two, so only one zoom engine runs. Hyprland can remove a bind only together with **every** bind
on the same key combination, including your own.

- To keep Omarchy's behavior, turn the takeover off and give hyprland-zoom other modifiers
  (*Shortcuts → Modifier keys*, for example `SUPER + CTRL`).
- `zoomctl doctor` lists key combinations that are bound twice.
- The 0.1 default keys `K`, `J`, `L` collided with Omarchy's tmux and layout binds; 0.2 uses
  `I`, `O`, `0`, `C` and `Z`. Keys you changed yourself are kept.

## The settings window does not open

- `hyprland-zoom-settings` needs `python-gobject`, `gtk4` and `libadwaita` (all are package
  dependencies). Start it from a terminal to see the error: `hyprland-zoom-settings`.
- It refuses to run as root; run it as your normal user.
- It needs a running Wayland session. A second start only raises the open window.
- *"No engine"* banner: click *Set up*, or run `zoomctl setup` and reload Hyprland.

## Filters

- A screen shader of your own (`decoration.screen_shader`) is remembered when a filter is
  switched on and restored when it is switched off. While a filter is on, yours is not shown.
- Screen sharing through PipeWire/portals may show the unfiltered image.
- *Only while zoomed* keeps the filter off at zoom 1.00 on purpose.

## `zoomctl` complains

| Message | Meaning |
|---|---|
| `'9' is not valid for ZOOM_STEP: expected a number from 0.01 to 2.00` | The value is outside the range shown in the [configuration reference](configuration.md#all-settings). Nothing was saved. |
| `ZOOM_MIN (3.00) <= ZOOM_RESET (1.00) <= ZOOM_MAX (10.00) must hold` | Change the other bound first. |
| `saved; Hyprland is not reachable, so nothing was applied live` | The setting is stored and applies on the next reload. |
| `could not take the zoom lock within 5s` (legacy path only) | Another `zoomctl` held the lock for 5 s; run the command again. |

## Uninstalling

`sudo pacman -Rs hyprland-zoom` (or `zoomctl uninstall`) removes the package and the lines
that `zoomctl setup` added to `hyprland.lua` / `hyprland.conf`, after saving a backup next to
the file. Your own settings in `~/.config/zoomctl/zoom.conf` stay; delete the file if you do
not need it.

## Development and CI

Problems met while building 0.2, kept here so they are recognized when they come back.

| Symptom | Cause | Fix |
|---|---|---|
| Fast scroll notches zoom only once per ~300 ms and the rest scroll the window | Hyprland's `binds.scroll_event_delay` (default 300 ms) hands later notches to the client | The engine sets it from `SCROLL_EVENT_DELAY_MS` (default 0) |
| 20 quick `zoomctl in` calls end at 1.1–1.2 instead of 3.0 (0.1 MVP) | Each call read, computed and wrote the zoom through `hyprctl` in its own process (race) | Zoom math runs inside Hyprland's Lua state; the legacy path serializes with `flock` |
| Red config-error bar after every reload | `plugin.hyprzoom.*` keys were set without the plugin; 0.56 records unknown keys as errors | Plugin keys are set only while the plugin is loaded |
| Hyprland crashes when a changed shortcut plan is applied | `remove()` on a bind handle that another unbind already expired dereferences a null pointer in 0.56.2 | Expired handles (`tostring()` check) are skipped |
| `zoomctl setup` creates backups although nothing changed (CI only) | `cmp` (diffutils) is not part of a bare Arch install | Content comparison via `sha256sum` (coreutils) |
| Plugin build: `IHyprRenderer has no member named m_renderData` | Arch moved to Hyprland 0.57, which changed the hooked function | The plugin picks the 0.56 or 0.57 code path at compile time |
| GUI suite errors in `makepkg` check() or the generic test job | PyGObject/GTK/`python3` not installed there | `tests/gui/run.sh` exits 77 (skip) and names the missing piece |
| GUI test `Directory not empty` on cleanup (CI only) | A fake `zoomctl` was still writing when the test removed its temp dir | Fakes hold a shared lock; cleanup waits for it |
| namcap errors for `glib2`, `hicolor-icon-theme` | The UI imports GLib/Gio and installs hicolor icons | Both are runtime dependencies in the PKGBUILD |
