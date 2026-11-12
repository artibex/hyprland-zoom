[Technical documentation](https://artibex.github.io/hyprland-zoom/)

# hyprland-zoom

Accessibility zoom for [Hyprland](https://hyprland.org), modelled on the screen zoom of macOS:
hold a key and scroll to magnify the screen, keep the pointer where you want it in the zoomed
view, switch on a color filter, and try every setting out live in a settings window.

- **Zoom on every scroll notch.** Fast scrolling zooms smoothly; no notch is swallowed or
  passed on to the window underneath.
- **Pointer tracking.** The pointer stays in the middle of the view, or the view only moves
  when the pointer gets close to the edge — with a margin you can adjust.
- **Color filters.** Invert, dark-mode style *smart invert*, grayscale, high contrast and
  color-blindness transforms, each with strength, contrast, brightness and saturation.
- **Settings app with a *Try it* bar.** Change a value, feel the difference at once.
- **Made for Arch and Omarchy.** Installs as a package, avoids Omarchy's key bindings, and
  keeps your zoom when Omarchy reloads the configuration.

<!-- Screenshots (to be added): -->
<!-- 1. Settings window, Zoom page (light and dark) -->
<!-- 2. Settings window, Pointer tracking page with the margin slider -->
<!-- 3. Settings window, Color filters page while a preview runs (Keep / Revert) -->
<!-- 4. Desktop zoomed to 3x, before and after smart invert -->
<!-- 5. Shortcuts page with the keycap strip -->

## Requirements

- Arch Linux or a derivative (Omarchy works out of the box).
- **Hyprland 0.55 or newer with the Lua config** (`~/.config/hypr/hyprland.lua`). Older or
  hyprlang-only setups get a reduced fallback: zoom and tracking work, color filters and live
  preview do not.
- Installed automatically with the package: `python`, `python-gobject`, `gtk4`, `libadwaita`,
  `bash`, `util-linux`.
- Optional, for the adjustable pointer margin: `hyprpm` and a compiler toolchain
  (see [the plugin](docs/plugin.md)).

## Install

**From a release** (a built package is attached to every
[release](https://github.com/artibex/hyprland-zoom/releases); `sha256sums` is next to it):

```bash
sudo pacman -U hyprland-zoom-0.2.0-1-any.pkg.tar.zst
```

**Build it yourself** from a clone (needs `base-devel`; `BUILDDIR` keeps the repository's own
`src/` directory out of makepkg's way):

```bash
git clone https://github.com/artibex/hyprland-zoom.git
cd hyprland-zoom
BUILDDIR=/tmp/hyprland-zoom-build makepkg -si
```

## First steps

```bash
zoomctl setup      # adds one line to ~/.config/hypr/hyprland.lua (backup included, safe to repeat)
hyprctl reload     # or log out and in
zoomctl doctor     # everything should say [ok  ]
```

The package hook runs `zoomctl setup` for you when it can. Now hold `SUPER + ALT` and scroll.

| Action | Default shortcut |
|---|---|
| Zoom in / out | `SUPER + ALT` + scroll wheel (scroll down zooms in) |
| Zoom in / out with the keyboard | `SUPER + ALT + I` / `SUPER + ALT + O` |
| Toggle zoom (reset ⇄ last level) | `SUPER + ALT + 0` or `SUPER + ALT` + middle click |
| Color filter on / off | `SUPER + ALT + C` |
| Open the settings window | `SUPER + ALT + Z` |

Every key, the modifiers and the scroll direction can be changed in the settings window. See
[usage](docs/usage.md#shortcuts) for what happens with Omarchy's own binds.

## What you can do

### Pointer tracking

*Settings → Pointer tracking*, or `zoomctl tracking <mode>`:

| Mode | Behavior |
|---|---|
| `centered` | The pointer stays in the middle of the zoomed view (default). |
| `edge` | The view stands still until the pointer reaches the edge. |
| `margin` | Like `edge`, with a protective margin you choose (needs the plugin). |
| `follow` | The view slides proportionally with the pointer. |

### Color filters

`SUPER + ALT + C` switches the chosen filter on and off; pick the filter and fine-tune it under
*Settings → Color filters*. *Smart invert* turns bright screens dark but keeps colors
recognizable.

### Fast scrolling

Nothing to do: hyprland-zoom sets Hyprland's `scroll_event_delay` to 0. If a notch still leaks
to the window underneath, see [troubleshooting](docs/troubleshooting.md).

## Optional: the `hyprzoom` plugin

Without it, `margin` tracking behaves like `edge` (Hyprland's fixed 5 % margin) and the
settings window says so. With it you get a margin slider from 0.00 to 0.45. The plugin is built
on your machine by `hyprpm` because plugins are tied to the exact Hyprland build; it supports
Hyprland 0.56.x and 0.57.x. Install steps, autostart and update behavior:
[docs/plugin.md](docs/plugin.md).

## Configure

| Way | How |
|---|---|
| Settings window | `zoomctl ui` or `SUPER + ALT + Z` — changes apply live |
| Command line | `zoomctl set step 0.15`, `zoomctl get tracking`, `zoomctl reset-config` |
| Config file | `~/.config/zoomctl/zoom.conf` (`KEY=VALUE` lines); system defaults in `/etc/zoomctl.conf` |

All settings with ranges and defaults: [docs/configuration.md](docs/configuration.md).

## Update and uninstall

Install a newer package the same way as the first one; `/etc/zoomctl.conf` is kept if you
changed it, and a 0.1 include line in `hyprland.lua` is migrated automatically. Reload Hyprland
afterwards. If you use the plugin, run `hyprpm update && hyprpm reload` after every Hyprland
update.

```bash
sudo pacman -Rns hyprland-zoom     # or: zoomctl uninstall
```

The hook removes the lines it added to your Hyprland config (after saving a backup). Your own
settings in `~/.config/zoomctl/zoom.conf` stay.

## Troubleshooting

Run `zoomctl doctor` first. The most common problems:

- **Nothing happens.** `zoomctl setup`, then `hyprctl reload`.
- **One scroll notch zooms, the next scrolls the page.** `zoomctl status` must show
  `scroll_event_delay_ms  0`; the engine line must be the last one in `hyprland.lua`
  (`scroll_event_delay`).
- **`hyprctl keyword` is rejected.** Lua configs do not accept it; use `zoomctl` or
  `hyprctl eval`.
- **The zoom resets when the configuration reloads.** Keep *Keep zoom on config reload* on; a new
  Hyprland session starts unzoomed on purpose.
- **A shortcut also does something in Omarchy.** Bind collisions are handled by the Omarchy
  takeover; see [troubleshooting](docs/troubleshooting.md#shortcut-collisions-with-omarchy-or-your-own-binds).
- **The margin has no effect or the plugin vanished after a Hyprland update.**
  `hyprpm update && hyprpm reload`.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Documentation

| Document | Content |
|---|---|
| [Technical documentation](https://artibex.github.io/hyprland-zoom/) | Generated reference: every script, setting, command, workflow |
| [docs/usage.md](docs/usage.md) | Shortcuts, settings window, tracking, filters, `zoomctl` |
| [docs/configuration.md](docs/configuration.md) | Every setting, config files, upgrading from 0.1 |
| [docs/plugin.md](docs/plugin.md) | The optional `hyprzoom` plugin |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms and fixes |
| [docs/packaging.md](docs/packaging.md) | Package layout, building, releasing, CI |
| [docs/architecture.md](docs/architecture.md) | Design decisions and contracts |
| [docs/roadmap.md](docs/roadmap.md) | What is next |
| [CHANGELOG.md](CHANGELOG.md) | What changed |

## Contributing

`make check lint qa test` runs the same checks as CI; `make docs` builds the technical
documentation into `public/`. See [docs/packaging.md](docs/packaging.md#quality-gate-and-ci).

## License

MIT, see [LICENSE](LICENSE).
