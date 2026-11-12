# Changelog

All notable changes to hyprland-zoom. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.2.0] - unreleased

A rewrite around an engine that runs inside Hyprland, a settings app, pointer tracking modes
and color filters.

### Added
- **Settings window** (`hyprland-zoom-settings`, `zoomctl ui`, `SUPER + ALT + Z`): GTK 4 /
  libadwaita, generated from the settings schema, live apply, a *Try it* bar (test zoom,
  filter preview with Keep / Revert), *Restore defaults…*.
- **Pointer tracking** (`ZOOM_TRACKING`): `centered`, `edge`, `margin` (adjustable
  protective margin, needs the optional plugin) and `follow`.
- **Optional `hyprzoom` plugin** (`plugin/`, built by `hyprpm`): makes the edge margin of
  Hyprland's zoom camera configurable (0.00–0.45). Hyprland 0.56.x only.
- **Color filters**: invert, smart invert, grayscale, inverted grayscale, high contrast and
  protanopia / deuteranopia / tritanopia transforms, with strength, contrast, brightness and
  saturation; optionally only while zoomed.
- **Lua engine** (`hyprland-zoom.lua`) loaded from `hyprland.lua`: zoom steps are atomic
  inside the compositor, scroll and key binds are Lua functions.
- Percentage zoom steps (`ZOOM_STEP_MODE=multiply`, default) next to fixed steps (`add`).
- Zoom level and filter survive Hyprland config reloads (`ZOOM_RESTORE_ON_RELOAD`).
- Omarchy awareness: default keys avoid Omarchy's binds; Omarchy's group-scroll and zoom binds
  are taken over (`BIND_TAKEOVER_OMARCHY`).
- `zoomctl` commands `set`, `get`, `unset`, `reset-config`, `config --porcelain|--template`,
  `preview`, `tracking`, `filter`, `status --porcelain`, `doctor`.
- One settings schema (`config/settings.schema`) for CLI, engine and settings window; the
  `/etc/zoomctl.conf` template and the reference in `docs/configuration.md` are generated from
  it.
- Packaging and project infrastructure: `Makefile`, GitHub Actions (CI, documentation on
  GitHub Pages, tagged releases), generated technical documentation and a code-quality gate
  (`tools/techdoc`).

### Changed
- **Fast scrolling works**: `binds.scroll_event_delay` is set to 0 (`SCROLL_EVENT_DELAY_MS`),
  so no notch is swallowed and passed on to the window underneath, and concurrent notches no
  longer lose steps.
- Default shortcuts: `SUPER + ALT` + scroll, `I` / `O`, `0`, middle click, `C`, `Z`. The 0.1 keys
  `K`, `J`, `L` collided with Omarchy.
- `zoomctl setup` writes `dofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")` at the end of
  `hyprland.lua` and migrates the 0.1 `hyprland-bindings.lua` line (timestamped backup).
- `zoomctl configure` is now an alias of `zoomctl ui`; the terminal and launcher menus
  (wofi, rofi, fuzzel, bemenu) are gone.
- New runtime dependencies: `python`, `python-gobject`, `gtk4`, `libadwaita`, `util-linux`,
  `hyprland>=0.55`.
- Documentation is English and organised as README, `docs/usage.md`, `docs/configuration.md`,
  `docs/troubleshooting.md`, `docs/packaging.md`, `docs/plugin.md`.

### Compatibility
- 0.1 settings keep working: `ZOOM_CENTER_CURSOR` maps to `ZOOM_TRACKING`
  (`centered` / `edge`) and implies the fixed-step mode for files that still use it.
- Legacy hyprlang configs keep a reduced fallback (no filters, no live preview).

## [0.1.0]

- First packaged version: shell-based `zoomctl` (zoom in / out / toggle / reset with bounds),
  state in the runtime directory, `/etc/zoomctl.conf` and a per-user config, Hyprland include
  installed by the package hook, Hyprland 0.55+ Lua-config support.
