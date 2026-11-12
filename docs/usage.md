# Using hyprland-zoom

This page explains day-to-day use. Installing is covered in the [README](../README.md); every
setting is listed in the [configuration reference](configuration.md).

## First steps

```bash
zoomctl setup      # wires the engine into ~/.config/hypr/hyprland.lua (safe to repeat)
hyprctl reload     # or log out and in; Omarchy reloads on every config save anyway
zoomctl doctor     # checks Hyprland, the engine, the include line, binds and the plugin
```

Then hold `SUPER + ALT` and scroll. The package install hook runs `zoomctl setup` for you when
it can find your home directory; running it again changes nothing.

## Shortcuts

All shortcuts share one set of modifier keys (default `SUPER + ALT`). Every key can be changed
or disabled in the settings window (*Shortcuts*) and with `zoomctl set`.

| Action | Default | Setting |
|---|---|---|
| Zoom in / out | `SUPER + ALT` + scroll wheel (down zooms in) | `BIND_SCROLL`, `BIND_SCROLL_DIRECTION` |
| Zoom in / out, keyboard (repeats when held) | `SUPER + ALT + I` / `SUPER + ALT + O` | `BIND_KEY_IN`, `BIND_KEY_OUT` |
| Toggle zoom (reset ⇄ last level) | `SUPER + ALT + 0` or `SUPER + ALT` + middle click | `BIND_KEY_TOGGLE`, `BIND_MOUSE_TOGGLE` |
| Color filter on / off | `SUPER + ALT + C` | `BIND_KEY_FILTER` |
| Open the settings window | `SUPER + ALT + Z` | `BIND_KEY_SETTINGS` |

The defaults were checked against Omarchy's own binds. Two of Omarchy's binds would still fire
on the same keys, so with `BIND_TAKEOVER_OMARCHY` on (default) the engine

- removes Omarchy's `SUPER + ALT + scroll` (cycling windows of a group), and
- routes Omarchy's own zoom keys `SUPER + CTRL + Z` (zoom in) and `SUPER + CTRL + ALT + Z`
  (reset) to hyprland-zoom, so two zoom engines never fight over the same option.

Hyprland can only remove a bind together with everything else on that key combination. If you
use `SUPER + ALT + scroll` for something of your own, turn the takeover off and change the
modifiers instead.

## Fast scrolling

Every scroll notch zooms. Hyprland normally ignores further wheel events for 300 ms after a
bind fired and hands them to the window underneath, which made the old behavior "one notch
zooms, the next one scrolls the page". hyprland-zoom sets that delay to 0
(`SCROLL_EVENT_DELAY_MS`). Zooming also happens inside the compositor, so scrolling quickly
cannot lose steps.

The step is a percentage by default: 0.10 means each notch changes the zoom by 10 % of the
current level, which feels even at 1.5x and at 8x. Prefer a fixed amount? Set *Step mode* to
`add`.

## The settings window

Open it with `SUPER + ALT + Z`, `zoomctl ui` or from your application launcher
(*Zoom Settings*). Every change applies immediately and is saved.

| Page | What it controls |
|---|---|
| **Zoom** | step size and mode, minimum / maximum / reset level, animation speed, smooth images |
| **Pointer tracking** | how the view follows the pointer, and the margin |
| **Color filters** | which filter, its strength, contrast, brightness and saturation |
| **Shortcuts** | modifier keys, keys, scroll direction, Omarchy takeover |
| **Advanced** | keep zoom on config reload, scroll event delay, *Restore defaults…* |

The **Try it** bar at the bottom is always visible:

- *Zoom to 2× for 5 s* zooms in so you can feel the animation and tracking settings, then
  restores your previous level.
- *Preview filter for 10 s* switches the selected filter on with *Keep* and *Revert* buttons
  and a countdown. The filter only stays on if you press *Keep*.

If a value is refused (for example a zoom maximum below the minimum) the control jumps back
and a message explains why. If no engine is loaded, a banner offers *Set up*.

## Pointer tracking

How the zoomed view reacts to the mouse pointer (`ZOOM_TRACKING`):

| Mode | Behavior |
|---|---|
| `centered` (default) | The pointer stays in the middle of the zoomed view. |
| `edge` | The view stands still until the pointer reaches the edge (Hyprland's own 5 % margin). |
| `margin` | Like `edge`, but you choose the protective margin (`ZOOM_EDGE_MARGIN`, 0.00–0.45 of the view per side). Needs the optional [plugin](plugin.md). |
| `follow` | The view slides proportionally with the pointer. |

Without the plugin `margin` behaves like `edge`; `zoomctl status` shows the mode that is
really in effect (`tracking_effective`) and the settings window says so next to the slider.

## Color filters

Filters are applied to the final image, after the zoom. `SUPER + ALT + C` switches the chosen
filter on and off; `zoomctl filter smart-invert` picks one and switches it on.

| Filter | Use |
|---|---|
| `smart-invert` (default) | Dark mode for bright screens; colors stay recognizable. |
| `invert` | Swaps light and dark, colors become their opposites. |
| `grayscale`, `grayscale-invert` | Removes color; the second also swaps light and dark. |
| `high-contrast` | Pushes light and dark apart for readability. |
| `protanopia`, `deuteranopia`, `tritanopia` | Color transforms for red-, green- and blue-weak color vision. |

Fine-tune with *Filter strength* (blend with the original image), *Contrast*, *Brightness* and
*Saturation*. *Only while zoomed* applies the filter only while the screen is magnified. A
screen shader you set yourself is remembered and restored when the filter is switched off.

Filters use Hyprland's screen shader; screen sharing through PipeWire/portals may show the
unfiltered image.

## `zoomctl` in short

```text
zoomctl in [n]                zoom in by n notches (default 1)
zoomctl out [n]               zoom out by n notches
zoomctl zoom 2.5              jump to a factor (1.00-10.00)
zoomctl toggle                switch between the reset zoom and the last level
zoomctl reset                 go back to the reset zoom
zoomctl filter [name]         on, off, toggle (default) or a filter name
zoomctl tracking <mode>       centered, edge, margin or follow
zoomctl set <key> <value>     validate, save and apply one setting
zoomctl get <key>             print the effective value
zoomctl unset <key>           drop your override of one setting
zoomctl reset-config          drop all of your overrides
zoomctl config                show the effective configuration (--porcelain, --template)
zoomctl preview KEY=VALUE...  try settings live without saving; `preview --end` undoes it
zoomctl status                show the zoom state (--porcelain for scripts)
zoomctl doctor                check the installation and the Hyprland wiring
zoomctl setup                 add the include line to hyprland.lua
zoomctl ui                    open the settings window (alias: configure)
zoomctl edit-config           open your config file in $EDITOR
zoomctl uninstall             remove the package (asks first; --yes skips the question)
zoomctl version               print the version
zoomctl help                  print this list
```

Exit status: 0 success, 1 error (message on stderr), 2 wrong usage. The complete, generated
command list is on the technical documentation site.

Bind `zoomctl` to your own keys if you like; in a Lua config:

```lua
hl.bind("SUPER + ALT + M", hl.dsp.exec_cmd("zoomctl zoom 3"))
```

## Legacy hyprlang configs

Hyprland before 0.55, or a `hyprland.conf` without Lua, works in a reduced mode: the same
shortcuts and settings, but no color filters and no live preview, and every action starts a
`zoomctl` process. `zoomctl setup` adds a `source =` line instead of the Lua include.
`zoomctl doctor` tells you which mode you are in.
