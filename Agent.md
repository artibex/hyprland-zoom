# Agent Plan: Hyprland Zoom MVP to Arch Package

## Goal
Build a small, installable Arch Linux package for Hyprland that provides a polished zoom tool with good UX, minimal dependencies, and a modular codebase that is easy to understand and maintain.

The current MVP config in `zoom-mvp.conf` shows the intended user actions:
- zoom in with mouse wheel up and a keyboard shortcut
- zoom out with mouse wheel down and a keyboard shortcut
- toggle reset with mouse click and a keyboard shortcut
- preserve and restore the previous zoom value

## Product Direction
The first version should feel like a real tool, not a one-off config snippet. It should:
- work cleanly on Hyprland
- stay lightweight
- expose simple user-facing controls
- keep the zoom logic separate from Hyprland keybinding glue
- make future features easy to add without rewriting the core

## Core Principles
- Minimal dependencies: prefer shell, Hyprland’s existing tooling, and standard Arch packages only when needed.
- Modular design: separate control logic, config parsing, state handling, and Hyprland integration.
- Dynamic behavior: user settings should change the experience without code edits.
- Clear defaults: the package should work immediately after install.
- Safe state handling: restore previous zoom reliably and clamp values to valid ranges.

## Proposed MVP Architecture

### 1. Command Line Controller
Create a small command line entry point such as `zoomctl` that owns the zoom behavior.

Responsibilities:
- read the current zoom value from Hyprland
- zoom in by a configurable step
- zoom out by a configurable step
- toggle between the default zoom and the last stored zoom
- clamp values to safe bounds
- print useful errors when Hyprland is unavailable

### 2. Config Layer
Add a simple config file that lets users customize the experience without modifying code.

Config examples:
- zoom step size
- minimum and maximum zoom values
- reset behavior
- optional keybinding presets
- optional mouse binding presets
- optional feedback settings

Keep the config format simple so it can be parsed with minimal tooling.

### 3. State Handling
Persist the last zoom value only when needed for toggle reset behavior.

State requirements:
- remember the pre-reset zoom value
- restore it when reset is toggled again
- avoid stale or corrupted values
- keep storage local to the user session

### 4. Hyprland Integration
Provide a Hyprland-focused integration layer that ships example bindings and documentation.

This layer should:
- bind mouse and keyboard actions to `zoomctl`
- avoid duplicating zoom math inside the config file
- make it easy to copy or include into a user config

### 5. Packaging Layer
Ship this as an Arch package with a clean install layout.

Package outputs should include:
- the main executable
- a default config file
- documentation for Hyprland setup
- optional example bindings inspired by `zoom-mvp.conf`

## Suggested Repository Structure

```text
hyprland-zoom/
  PKGBUILD
  .SRCINFO
  README.md
  Agent.md
  src/
    zoomctl
    lib/
      config.sh
      hyprland.sh
      state.sh
      math.sh
  config/
    zoom.conf
    hyprland-bindings.conf
  docs/
    usage.md
    packaging.md
  install/
    post_install.sh
```

This can be simplified for the MVP, but the code should still be organized around these concerns.

## MVP Scope

### Must Have
- installable Arch package
- zoom in and zoom out with rapid scrooling without a hitch or slow down and toggle reset
- the mouse cursour is in the center of the screen (optinally toggable)
- Hyprland-compatible bindings
- configurable zoom step and bounds
- minimal runtime dependencies

### Nice to Have Later
- on-screen zoom feedback
- animated transitions if feasible without heavy dependencies
- profile presets for different monitor sizes
- per-window or per-workspace behavior
- notification integration
- GUI helper for settings

## Implementation Plan

### Phase 1: Define the behavior
- translate `zoom-mvp.conf` into explicit behavior rules
- decide the zoom step model and clamp range
- define toggle reset semantics exactly
- decide where the persistent state lives

### Phase 2: Build the core script
- implement a `zoomctl` entry point
- isolate read/write helpers for Hyprland interaction
- isolate math and value clamping
- add config loading
- add a small state file helper

### Phase 3: Add package structure
- create `PKGBUILD`
- install the executable, config, and docs
- verify package metadata and file layout

### Phase 4: Hyprland integration
- ship example bind snippets
- document how to include them in `hyprland.conf`
- keep the integration optional and user-controlled

### Phase 5: Polish and harden
- validate invalid config values
- ensure reset behavior survives edge cases
- document defaults and customization
- add tests for the logic that can be tested without Hyprland

## Dependency Strategy
Use the least dependencies possible.

Preferred approach:
- shell script for orchestration
- `hyprctl` for Hyprland communication
- `awk`, `grep`, `sed`, and `printf` only if needed
- no large runtime frameworks
- no background daemon unless later UX work proves it necessary

If a dependency is needed, it must justify itself by removing complexity or improving reliability.

## Quality Bar
The package is successful if a user can:
- install it on Arch
- add one include line or a few binds in Hyprland
- get predictable zoom controls immediately
- customize the behavior from a config file
- understand the codebase quickly because each responsibility is separated
- A eye friendly, easy to use UI to change settings

## Open Design Questions
- Should state be stored in a user cache file or a runtime directory file?
- Should the reset behavior be purely toggle-based or also support a hard reset command?
- Should the package provide only the controller, or also ship a ready-to-include Hyprland config snippet?
- Is the UI goal “invisible and fast” or should it include optional feedback from day one?

## Immediate Next Step
Convert the MVP behavior from `zoom-mvp.conf` into a small shell-based control core, then wrap it in an Arch package with a default config and example Hyprland bindings.