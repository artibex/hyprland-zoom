# Usage

`zoomctl` is a small shell controller for Hyprland's `cursor:zoom_factor` option.

## Commands

- `zoomctl in` increases the zoom by the configured step.
- `zoomctl out` decreases the zoom by the configured step.
- `zoomctl toggle` stores the current zoom and resets to `ZOOM_RESET`, or restores the stored value when already reset.
- `zoomctl reset` clears the stored value and returns to `ZOOM_RESET`.
- `zoomctl status` prints the current zoom, bounds, and state location.
- `zoomctl config` prints the active configuration.
- `zoomctl set <key> <value>` changes a single setting and saves it immediately - no editor, no menu.
- `zoomctl get <key>` prints the active value of a single setting.
- `zoomctl configure` prompts for every setting one at a time (menu-driven, uses `zenity`/`yad` when available).
- `zoomctl edit-config` opens the user config in `$EDITOR`.
- `zoomctl setup` adds the packaged `hyprland-bindings.conf` include to `~/.config/hypr/hyprland.conf`.
- `zoomctl ui` opens an interactive menu for zoom actions, settings, and uninstall.
- `zoomctl uninstall` removes the package when `sudo`, `doas`, or `pkexec` is available.

## Changing settings

The fastest way to change a setting is `zoomctl set`:

```bash
zoomctl set step 0.25          # zoom step per scroll/keypress
zoomctl set min 1              # minimum zoom
zoomctl set max 6              # maximum zoom
zoomctl set reset 1            # zoom factor used by reset/toggle
zoomctl set center-cursor on   # or: off
```

Each call validates the value, saves it to `~/.config/zoomctl/zoom.conf` alongside your other settings, and prints the value that took effect. Invalid input (a non-numeric step, a min greater than the current max, an unrecognized key) is rejected with an error and nothing is written. `zoomctl get <key>` reads a single value back, which is handy in scripts.

`center-cursor` accepts `on`/`off`, `true`/`false`, `yes`/`no`, or the raw `1`/`0` - use whichever reads naturally.

If you'd rather be walked through every setting at once, `zoomctl configure` does that interactively.

## Configuration

The package installs a default config at `/etc/zoomctl.conf`.

Per-user overrides live in `~/.config/zoomctl/zoom.conf`, and that's the file `zoomctl set`/`zoomctl configure` write to.

The `zoomctl ui` command will use `wofi`, `rofi`, `fuzzel`, or `bemenu` when available. If none of those are installed, it falls back to a numbered terminal menu.

Supported keys, and the short names accepted by `zoomctl set`/`zoomctl get`:

- `ZOOM_STEP` (`step`)
- `ZOOM_MIN` (`min`, `minimum`)
- `ZOOM_MAX` (`max`, `maximum`)
- `ZOOM_RESET` (`reset`)
- `ZOOM_CENTER_CURSOR` (`center-cursor`, `center`, `cursor`)
- `ZOOMCTL_STATE_DIR` (config file only, not exposed through `set`/`get`)

## Hyprland Setup

Source `/usr/share/hyprland-zoom/hyprland-bindings.conf` from your Hyprland config, or copy the bind lines into your own file.

The package's install hook adds this include automatically for the invoking user during install and upgrade, and removes it again on uninstall. If you want to trigger the same wiring yourself, run `zoomctl setup` at any time. If you need to direct that behavior at a specific user's home directory, set `ZOOMCTL_TARGET_HOME` before invoking the install hook, `zoomctl setup`, or `zoomctl uninstall`.

`zoomctl` itself sources the shared implementation from `/usr/share/hyprland-zoom/lib/setup.sh` (kept in the repo as `src/lib/setup.sh`). `install/post_install.sh` intentionally carries its own copy of the same logic instead of sourcing that file: pacman deletes a package's installed files *before* running its `post_remove` scriptlet, so the uninstall hook cannot depend on anything the package itself ships - it has to be fully self-contained. If you change the Hyprland-include behavior, update both files.

The uninstall hook is shipped in `install/post_install.sh` as `post_remove`, which is why it is referenced through `PKGBUILD`'s `install=...` field rather than as a separate package command.

The example binds mirror the MVP flow from `zoom-mvp.conf` while keeping the zoom math inside `zoomctl`.