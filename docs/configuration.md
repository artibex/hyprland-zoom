# Configuration reference

hyprland-zoom has one list of settings. The settings window, `zoomctl` and the config files
all use the same keys, defaults and ranges; they come from `config/settings.schema`, installed
as `/usr/share/hyprland-zoom/settings.schema`. The tables below are generated from that file
(`make docs-sync`), so they cannot go out of date.

## Three ways to change a setting

| Way | When to use it |
|---|---|
| **Settings window** (`zoomctl ui`, or `SUPER + ALT + Z`) | The normal way. Changes apply live; the *Try it* bar lets you test them. |
| **`zoomctl set KEY VALUE`** | Scripts and quick changes. Validates, saves and applies at once. |
| **Config file** | Dotfile managers and system-wide defaults. Read on every Hyprland reload. |

```bash
zoomctl set step 0.15            # short name: lower case, no ZOOM_ prefix
zoomctl set ZOOM_STEP 0.15       # the full key works as well
zoomctl get tracking             # print the effective value
zoomctl unset step               # drop your override, fall back to the default
zoomctl reset-config             # drop all of your overrides
zoomctl config                   # the effective configuration and where each value comes from
zoomctl config --porcelain       # KEY=VALUE lines for scripts
```

`zoomctl set` refuses invalid values with a message that names the allowed range, and refuses
a combination that breaks `ZOOM_MIN <= ZOOM_RESET <= ZOOM_MAX`.

## Config files

Effective value = built-in default, overridden by the system file, overridden by your file.

| Layer | Path | Written by |
|---|---|---|
| Built-in default | `/usr/share/hyprland-zoom/settings.schema` | the package |
| System | `/etc/zoomctl.conf` (every line commented out; the package keeps your edits) | you, as root |
| User | `~/.config/zoomctl/zoom.conf` (`$XDG_CONFIG_HOME` is honoured) | `zoomctl set`, the settings window |

Format: `KEY=VALUE`, one per line, `#` for comments, no quotes. Booleans are `on`/`off`
(`1`, `0`, `true`, `false`, `yes`, `no` are accepted as input). Floats are stored with two
decimals. An unknown key or an invalid value produces a warning (`zoomctl doctor` lists them)
and never stops the compositor: the invalid line is ignored and the next layer applies.

`zoomctl set` rewrites the user file in a canonical form (no comments, schema order). Edit it
by hand with `zoomctl edit-config` if you prefer; hand-written comments survive until the next
`zoomctl set`.

```ini
# ~/.config/zoomctl/zoom.conf
ZOOM_STEP=0.15
ZOOM_TRACKING=margin
ZOOM_EDGE_MARGIN=0.25
FILTER=smart-invert
```

### Environment variables

| Variable | Meaning |
|---|---|
| `ZOOMCTL_USER_CONFIG` | Use this file instead of `~/.config/zoomctl/zoom.conf`. |
| `ZOOMCTL_SYSTEM_CONFIG` | Use this file instead of `/etc/zoomctl.conf`. |
| `ZOOMCTL_SHARE_DIR` | Use this directory instead of `/usr/share/hyprland-zoom` (schema, libraries, Lua engine, shaders). For checkouts and tests. |
| `ZOOMCTL_STATE_DIR` | Runtime state (zoom level, active filter, generated shaders) instead of `$XDG_RUNTIME_DIR/hyprland-zoom`. |

## Upgrading from 0.1

- `ZOOM_CENTER_CURSOR=1` still works and means `ZOOM_TRACKING=centered`; `0` means `edge`.
  A file that still contains `ZOOM_CENTER_CURSOR` keeps its old meaning of `ZOOM_STEP`
  (fixed amount, `ZOOM_STEP_MODE=add`) until `zoomctl set` rewrites it with explicit keys.
  New installs zoom by a percentage (`multiply`, default), which feels even at every level.
- `zoomctl setup` replaces the 0.1 line `dofile(".../hyprland-bindings.lua")` in
  `hyprland.lua` by the engine line and keeps a timestamped backup next to the file.
- The default shortcuts changed so that they no longer collide with Omarchy (see
  [usage](usage.md#shortcuts)); the scroll direction is unchanged (scroll down zooms in).

## All settings

<!-- BEGIN GENERATED SETTINGS (python3 tools/techdoc/techdoc.py settings-doc) -->

### Zoom

| Key | `zoomctl set` name | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `ZOOM_STEP` | `step` | `0.10` | 0.01 to 2.00 | **Zoom step.** How much one scroll notch or key press zooms. In multiply mode 0.10 means 10 % of the current zoom. |
| `ZOOM_STEP_MODE` | `step-mode` | `multiply` | multiply, add | **Step mode.** multiply: even steps at every zoom level (recommended). add: always the same fixed amount. |
| `ZOOM_MIN` | `min` | `1.00` | 1.00 to 10.00 | **Minimum zoom.** Zooming out stops here. 1.00 is the normal, unzoomed screen. |
| `ZOOM_MAX` | `max` | `10.00` | 1.00 to 10.00 | **Maximum zoom.** Zooming in stops here. Hyprland supports up to 10x. |
| `ZOOM_RESET` | `reset` | `1.00` | 1.00 to 10.00 | **Reset zoom.** Zoom level used by reset and as the "off" side of the toggle. |
| `ZOOM_ANIMATION_SPEED` | `animation-speed` | `1.50` | 0.10 to 20.00 | **Animation duration.** Duration of the zoom animation in tenths of a second. Smaller is faster; 0.10 is practically instant. |
| `ZOOM_SMOOTH_IMAGES` | `smooth-images` | `on` | on, off | **Smooth images.** Smooth the magnified image. Turn off for crisp, pixel-exact magnification. |

### Pointer tracking

| Key | `zoomctl set` name | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `ZOOM_TRACKING` | `tracking` | `centered` | centered, edge, margin, follow | **Pointer tracking.** centered: the pointer stays in the middle of the zoomed view. edge: the view moves when the pointer reaches the edge. margin: like edge with an adjustable margin (needs the hyprzoom plugin). follow: the view slides proportionally with the pointer. |
| `ZOOM_EDGE_MARGIN` | `edge-margin` | `0.15` | 0.00 to 0.45 | **Edge margin.** Width of the protective margin per side as a fraction of the zoomed view. Used by the margin mode. |

### Colour filters

| Key | `zoomctl set` name | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `FILTER` | `filter` | `smart-invert` | invert, smart-invert, grayscale, grayscale-invert, high-contrast, protanopia, deuteranopia, tritanopia | **Colour filter.** Which filter the filter shortcut switches on. smart-invert turns bright screens dark but keeps colours recognisable. |
| `FILTER_ACTIVE` | `filter-active` | `off` | on, off | **Filter active.** Whether the colour filter is currently switched on. |
| `FILTER_ONLY_WHEN_ZOOMED` | `filter-only-when-zoomed` | `off` | on, off | **Only while zoomed.** Apply the colour filter only while the screen is zoomed in. |
| `FILTER_INTENSITY` | `filter-intensity` | `1.00` | 0.00 to 1.00 | **Filter strength.** Blend between the original image (0.00) and the full filter (1.00). |
| `FILTER_CONTRAST` | `filter-contrast` | `1.00` | 0.50 to 3.00 | **Contrast.** 1.00 keeps the contrast; higher values separate light and dark more strongly. |
| `FILTER_BRIGHTNESS` | `filter-brightness` | `0.00` | -0.50 to 0.50 | **Brightness.** Shifts the overall brightness after the filter. |
| `FILTER_SATURATION` | `filter-saturation` | `1.00` | 0.00 to 2.00 | **Saturation.** 0.00 removes colour, 1.00 keeps it, 2.00 doubles it. |

### Shortcuts

| Key | `zoomctl set` name | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `BIND_MODIFIERS` | `bind-modifiers` | `SUPER + ALT` | SUPER, SHIFT, CTRL, ALT joined by " + " | **Modifier keys.** Modifier keys held for every zoom shortcut, joined with " + ". |
| `BIND_SCROLL` | `bind-scroll` | `on` | on, off | **Zoom with the scroll wheel.** Modifiers + scroll wheel zooms in and out. |
| `BIND_SCROLL_DIRECTION` | `bind-scroll-direction` | `down-in` | down-in, up-in | **Scroll direction.** down-in: scrolling down (towards you) zooms in, as in version 0.1. up-in: scrolling up (away from you) zooms in. |
| `BIND_MOUSE_TOGGLE` | `bind-mouse-toggle` | `on` | on, off | **Toggle with middle click.** Modifiers + middle mouse button toggles the zoom. |
| `BIND_KEY_IN` | `bind-key-in` | `I` | a Hyprland key name, empty disables | **Zoom in key.** Key that zooms in (held down it repeats). Empty disables it. |
| `BIND_KEY_OUT` | `bind-key-out` | `O` | a Hyprland key name, empty disables | **Zoom out key.** Key that zooms out (held down it repeats). Empty disables it. |
| `BIND_KEY_TOGGLE` | `bind-key-toggle` | `0` | a Hyprland key name, empty disables | **Toggle zoom key.** Switches between the reset zoom and the last zoom level. |
| `BIND_KEY_FILTER` | `bind-key-filter` | `C` | a Hyprland key name, empty disables | **Toggle filter key.** Switches the colour filter on and off. |
| `BIND_KEY_SETTINGS` | `bind-key-settings` | `Z` | a Hyprland key name, empty disables | **Open settings key.** Opens the hyprland-zoom settings window. |
| `BIND_TAKEOVER_OMARCHY` | `bind-takeover-omarchy` | `on` | on, off | **Take over Omarchy zoom keys.** Routes Omarchy's own zoom keys to hyprland-zoom and frees modifiers + scroll from Omarchy's group cycling. |

### Advanced

| Key | `zoomctl set` name | Default | Allowed values | Meaning |
|---|---|---|---|---|
| `ZOOM_RESTORE_ON_RELOAD` | `restore-on-reload` | `on` | on, off | **Keep zoom on config reload.** Restore the zoom level and filter after Hyprland reloads its configuration. |
| `SCROLL_EVENT_DELAY_MS` | `scroll-event-delay-ms` | `0` | 0 to 300 | **Scroll event delay.** Hyprland ignores further scroll notches for this long and passes them to the window instead. 0 lets fast scrolling zoom smoothly. |
<!-- END GENERATED SETTINGS -->

## Plugin options

The optional `hyprzoom` plugin has two Hyprland options of its own, set for you by
`ZOOM_TRACKING` and `ZOOM_EDGE_MARGIN`; see [plugin.md](plugin.md#configure).
