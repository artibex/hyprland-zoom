# Packaging Notes

This project is intentionally simple to package for Arch Linux.

## Installed Files

- `/usr/bin/zoomctl` - the command line controller
- `/usr/share/hyprland-zoom/lib/` - modular shell helpers (math, config, state, Hyprland integration, install wiring)
- `/etc/zoomctl.conf` - default system config
- `/usr/share/hyprland-zoom/hyprland-bindings.conf` - example Hyprland binds
- `/usr/share/doc/hyprland-zoom/` - docs and reference material

## Runtime State

Saved toggle state is stored in `XDG_RUNTIME_DIR/zoomctl/last_zoom` by default so it stays local to the session and disappears automatically after logout.

## Dependencies

Only `bash` and `hyprland` are required at runtime.

## Rationale

Keeping the zoom control logic in a shell script avoids a background daemon and makes the behavior easy to inspect, modify, and debug.