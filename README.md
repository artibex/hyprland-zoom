# hyprland-zoom

A small Arch-packaged zoom controller for Hyprland.

It replaces the inline MVP math in `zoom-mvp.conf` with a shell-based `zoomctl` command, a user-editable config file, and a reusable Hyprland bind snippet shipped as `hyprland-bindings.conf`.

## What it does

- zoom in and out with a configurable step
- toggle between the reset value and the last saved zoom
- clamp zoom values to safe bounds
- keep runtime state in the user session directory
- optionally recenter the cursor after a zoom action
- open an interactive menu for zoom, settings, and uninstall actions
- auto-add the Hyprland include line during install when the user context is available

## Quick Start

1. Install the Arch package.
2. Run `zoomctl setup` (or let the install hook do it automatically) to wire the keybinds into `~/.config/hypr/hyprland.conf`.
3. Customize with `zoomctl set <key> <value>`, e.g. `zoomctl set step 0.25` or `zoomctl set center-cursor on`.

## Commands

- `zoomctl in`
- `zoomctl out`
- `zoomctl toggle`
- `zoomctl reset`
- `zoomctl status`
- `zoomctl config`
- `zoomctl set <key> <value>`
- `zoomctl get <key>`
- `zoomctl configure`
- `zoomctl edit-config`
- `zoomctl setup`
- `zoomctl ui`
- `zoomctl uninstall`

See [docs/usage.md](docs/usage.md) for the full list of setting keys accepted by `set`/`get`.

## Project Layout

- `src/zoomctl` is the command entry point.
- `src/lib/` contains the zoom math, config parsing, state handling, Hyprland integration, and the shared Hyprland-config wiring used by both `zoomctl setup` and the package install hooks.
- `config/` contains the default config (`defaults.conf`) and the example Hyprland binds (`hyprland-bindings.conf`).
- `docs/` contains usage and packaging notes.

## Development

Run the pure-shell test file with:

```bash
bash tests/zoomctl.sh
```
