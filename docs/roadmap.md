# Roadmap

What exists is described in the [README](../README.md) and the [changelog](../CHANGELOG.md).
This page lists what is still open. Nothing here is promised for a date.

## Product goals still open

- **On-screen feedback**: a small overlay with the current zoom level and filter name, off by
  default.
- **Per-monitor and per-workspace zoom**: remember a zoom level per monitor or workspace
  instead of one global level.
- **Profiles**: named presets (for example *reading* with `smart-invert` and a large margin,
  *presentation* with `centered` and no filter) switchable from the settings window.
- **Notification integration**: optional notification on filter or tracking changes.
- **Animated filter transitions**: fade between filtered and unfiltered instead of a hard
  switch.

## Technical follow-ups

- **Plugin and newer Hyprland**: the `hyprzoom` plugin hooks one private function that
  Hyprland 0.57 changed. It supports 0.56.x only; a port (or a native Hyprland option for the
  margin) would make `margin` tracking work without a plugin.
- **hyprpm pins**: `hyprpm.toml` has no `commit_pins` yet; add one row per tested Hyprland
  release when tagging.
- **hyprpm end-to-end test in CI**: the manifest and build are tested, `hyprpm add/enable`
  itself has not been run in automation.
- **HiDPI and fractional scaling**: the plugin's camera maths multiplies by the monitor scale
  like Hyprland does, but only scale 1 was measured live.
- **Screen sharing**: colour filters use Hyprland's screen shader, which PipeWire/portal
  capture probably ignores. Needs a decision: document, or offer a share-safe mode.
- **Key capture on non-Latin layouts**: the settings window only reads the first keyboard
  layout when recording a shortcut.
- **Lua test doubles**: `tests/lua/stub_host.lua` has no function headers; adding them would
  let the code-quality gate cover the whole Lua tree.
- **AUR**: a release PKGBUILD with a source tarball and checksums, generated from the tagged
  release.

## Completed in 0.2

Lua engine inside Hyprland, atomic fast scrolling, settings schema as single source, settings
app with live try-out, tracking modes and the optional margin plugin, eight colour filters,
Omarchy-aware shortcuts, zoom restore across reloads, CLI rewrite, packaging, CI and generated
technical documentation.
