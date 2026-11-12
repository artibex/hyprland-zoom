# The `hyprzoom` plugin (optional)

hyprland-zoom works without it. The plugin only adds one thing: **an adjustable protective
margin** for the "move the view when the pointer gets close to the edge" camera. Install it if
you want Apple-style *"keep the pointer at or near the centre"* (large margin) or *"only move
when the pointer reaches the edge"* (small margin) with a slider instead of two fixed modes.

| Without the plugin | With the plugin |
|---|---|
| `centered`, `edge` (fixed 5 % margin), `follow` | all of these plus `margin` with `0.00`–`0.45` |
| `margin` silently behaves like `edge`; `zoomctl status` reports the effective mode | `margin` uses your value |

## What the margin means

Edge margin = the width of the border zone *per side*, as a fraction of the zoomed view. While
the pointer is inside the remaining safe box, the view stands still; as soon as it enters the
border zone, the view moves just far enough to keep it on the border of the safe box.

| `edge_margin` | Feels like |
|---|---|
| `0.00` | The view only moves when the pointer touches the very edge of the screen. |
| `0.05` | Hyprland's built-in behaviour (default; identical numbers, verified). |
| `0.15` | Comfortable: the pointer stays in the inner 70 % of the view. |
| `0.30` | The pointer stays in the middle 40 %. |
| `0.45` | Nearly centred: the pointer stays in the middle 10 %. |

Details worth knowing:

- Zooming in with the pointer **away** from the middle starts without the margin (otherwise the
  view would jump). The margin engages as soon as the pointer enters the safe box once — move it
  towards the middle after zooming in. This is Hyprland's own anti-jerk rule, kept on purpose.
- The margin acts on the *detached camera* modes (`cursor:zoom_detached_camera = true`), which
  is what the `edge` and `margin` tracking modes select. With `cursor:zoom_rigid = true` the view
  never follows the pointer, whatever the margin.
- Values outside `0.00`–`0.45` are clamped.

## Requirements

- Hyprland **0.55 or newer** with the Lua config (built and tested against 0.56.2).
- `hyprpm` (Arch/Omarchy: `sudo pacman -S hyprpm`) and its build tools: `git cmake cpio pkgconf
  gcc` (the `base-devel` group covers most of them).
- `nm` from `binutils` **at runtime**: the plugin asks Hyprland for the address of one internal
  function, and Hyprland finds it by running `nm` on itself. Without `nm` the plugin refuses to
  load (see Troubleshooting).

## Install

```bash
hyprpm update                                            # fetches the headers of your Hyprland
hyprpm add https://github.com/artibex/hyprland-zoom      # clones and builds the plugin
hyprpm enable hyprzoom                                   # marks it as "load automatically"
hyprpm reload                                            # loads it into the running session
```

Check it: `hyprpm list` shows `hyprzoom` as enabled, `hyprctl plugin list` shows it as loaded,
and `zoomctl status` reports `plugin=loaded`.

### Load it at every login (Omarchy and other Lua configs)

`hyprpm enable` only records the wish; something has to run `hyprpm reload` after Hyprland has
started. On Omarchy put this into `~/.config/hypr/autostart.lua` (loaded after Omarchy's
defaults, survives Omarchy updates):

```lua
-- Load the plugins that `hyprpm enable` selected (hyprzoom).
hl.on("hyprland.start", function()
  hl.exec_cmd("hyprpm reload -n")
end)
```

`-n` shows a Hyprland notification if loading fails. With the legacy hyprlang config the
equivalent line is `exec-once = hyprpm reload -n`.

A plugin loaded this way survives `hyprctl reload`, i.e. Omarchy's theme and config reloads
(verified in a nested Hyprland, together with the margin value).

## Configure

Through the settings app or `zoomctl` (recommended — the engine passes the value on):

```bash
zoomctl tracking margin
zoomctl set edge-margin 0.20
```

Or directly in the Lua config:

```lua
hl.config({ plugin = { hyprzoom = { edge_margin = 0.20 } } })
```

| Option | Type | Default | Meaning |
|---|---|---|---|
| `plugin:hyprzoom:edge_margin` (Lua: `plugin.hyprzoom.edge_margin`) | float 0.00–0.45 | `0.05` | Margin per side, fraction of the zoomed view. |
| `plugin:hyprzoom:enabled` (Lua: `plugin.hyprzoom.enabled`) | bool | `true` | `false` hands the camera back to Hyprland's own code without unloading. |

The value can be set before the plugin is loaded; Hyprland applies it once the plugin
registers its options, and again after every config reload. The settings schema's own default
(`ZOOM_EDGE_MARGIN`, 0.15) is what the engine passes on while `margin` tracking is selected.

## Updates

Plugins are tied to the exact Hyprland build. After every Hyprland update:

```bash
hyprpm update        # re-fetches headers and rebuilds the plugin when needed
hyprpm reload
```

If you forget, the plugin refuses to load with a version-mismatch notification and you simply
get the native modes until you update. `hyprpm update` is cheap when nothing changed. When
Hyprland changes the internal function that is hooked, the plugin refuses to load instead of
guessing; update hyprland-zoom (`hyprpm update`), and if there is no release for your Hyprland
yet, tracking `margin` keeps working as `edge`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `zoomctl status` says `plugin=missing`, margin has no effect | Not loaded. `hyprpm list`, then `hyprpm reload`; add the autostart snippet above. |
| Notification "built for a different Hyprland version" | Hyprland was updated: `hyprpm update && hyprpm reload`. |
| Notification "not hooked: expected exactly one 'zoomWithDetachedCamera' symbol … found 0" | Either `nm` (binutils) is missing, or this Hyprland release renamed/removed the function. Run `nm -D $(readlink -f $(which Hyprland)) \| grep zoomWithDetachedCamera`: empty means a Hyprland change, wait for a plugin update; an error means install `binutils`. |
| `hyprpm add` / `update` fails to build | Run `hyprpm update -v`; most often a missing build tool (`cmake`, `cpio`, `pkgconf`, `git`, `gcc`) or a Hyprland release newer than the plugin. |
| The view jumps after zooming in | Should not happen; report it with `hyprctl version` and your `edge_margin`. |
| Nothing changes with `margin` tracking | Check `hyprctl getoption cursor:zoom_detached_camera` is `1` and `cursor:zoom_rigid` is `0`; `zoomctl status` shows the `tracking_effective` mode the engine really applied. |

Logs: `hyprctl plugin list`, and Hyprland's log (`$XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log`)
contain the exact reason when a plugin fails to load.

## Uninstall

```bash
hyprpm disable hyprzoom
hyprpm remove hyprland-zoom
```

Remove the autostart snippet if you added it, and `zoomctl tracking edge` if you used `margin`.
Nothing else changes: no files outside hyprpm's cache are touched, and Hyprland's camera code
is restored the moment the plugin is unloaded.

## How it works (for the curious and for reviewers)

- Hyprland computes the detached camera in `CMonitorZoomController::zoomWithDetachedCamera`
  with a literal `scaleFromCenter(.9)`. The plugin hooks that function (a trampoline hook found
  by symbol name; it must find **exactly one** matching symbol with the expected demangled
  name, otherwise it refuses to load and shows an error notification).
- The replacement is the same algorithm with the box scale `1 - 2 × edge_margin`, including the
  anti-jerk flag and the rigid guard. It lives in `plugin/camera_math.hpp` (no Hyprland types).
  With margin `0.05` it is numerically identical to Hyprland's code: `tests/plugin/run.sh`
  replays 12 000 random frames through a verbatim copy of Hyprland's function and demands
  agreement.
- Reading/writing the controller's private camera members is done by compiling the Hyprland
  headers with `private` turned into `public`, in exactly one header
  (`plugin/hyprland_includes.hpp`).
- Everything else (final clamp to the monitor, anchor, animation) stays Hyprland's.

## Development

```bash
make -C plugin                    # builds plugin/hyprzoom.so against the installed headers
tests/plugin/run.sh               # unit tests, native equivalence, manifest, schema, build
HYPRZOOM_TEST_NESTED_OK=1 tests/plugin/nested_test.py   # live test in a NESTED Hyprland
```

The nested test never touches your session's compositor: it starts a separate Hyprland as a
window of the current one (it flashes up for about a minute), loads the plugin there, measures
the zoom camera from screenshots for margins 0.05 / 0.25 / 0.40, and checks `enabled=false`,
unload/reload, `hyprctl reload`, adding a monitor while zoomed, and the refusal path. Never load
the plugin into your live session while developing.

Releases: add one `commit_pins` row per tested Hyprland release to `hyprpm.toml`
(`["<full Hyprland commit hash>", "<hyprland-zoom commit>"]`), so `hyprpm` builds a revision
known to work with the user's Hyprland.
