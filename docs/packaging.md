# Packaging, releasing and CI

hyprland-zoom ships as one Arch package, `hyprland-zoom`, built from this repository. The
`Makefile` installs everything; the `PKGBUILD` only calls it.

## Installed files

| Path | Content |
|---|---|
| `/usr/bin/zoomctl` | command line client |
| `/usr/bin/hyprland-zoom-settings` | settings app (entry script) |
| `/usr/share/hyprland-zoom/lib/*.sh` | shell libraries of `zoomctl` |
| `/usr/share/hyprland-zoom/hyprland-zoom.lua` | engine entry file, loaded from the user's `hyprland.lua` |
| `/usr/share/hyprland-zoom/lua/hyprland-zoom/*.lua` | engine modules |
| `/usr/share/hyprland-zoom/shaders/*.glsl` | color-filter shader templates |
| `/usr/share/hyprland-zoom/settings.schema` | the single source of settings, ranges and defaults |
| `/usr/share/hyprland-zoom/hyprland-bindings.lua` | shim for 0.1 installs (loads the engine) |
| `/usr/share/hyprland-zoom/hyprland-bindings.conf` | binds for legacy hyprlang configs |
| `/usr/share/hyprland-zoom/ui/hyprland_zoom_settings/*.py` | settings app package |
| `/usr/share/hyprland-zoom/VERSION` | the packaged version |
| `/usr/share/applications/io.github.artibex.HyprlandZoom.desktop` | launcher entry |
| `/usr/share/icons/hicolor/{scalable,symbolic}/apps/*.svg` | application icons |
| `/etc/zoomctl.conf` | system defaults, all commented out (`backup=`) |
| `/usr/share/doc/hyprland-zoom/` | README, CHANGELOG and `docs/*.md` |
| `/usr/share/licenses/hyprland-zoom/LICENSE` | licence |

The plugin (`plugin/`) is deliberately **not** packaged: plugins are tied to the exact
Hyprland build, so `hyprpm` builds it on the user's machine ([plugin.md](plugin.md)).

`make install` collects files by directory globs (`src/lib/*.sh`, `src/lua/hyprland-zoom/*.lua`,
`src/shaders/*.glsl`, `src/ui/hyprland_zoom_settings/*.py`, `docs/*.md`, `data/icons/**.svg`),
so a new library, module, shader or document needs no edit in the Makefile or the PKGBUILD.
`tests/repo/test_repo.py` installs into a staging directory and fails when a file of this
layout is missing or an unexpected one appears.

## Dependencies

| Kind | Packages |
|---|---|
| `depends` | `bash`, `coreutils`, `gawk`, `grep`, `sed`, `util-linux` (`flock`), `hyprland>=0.55`, `python`, `python-gobject`, `gtk4`, `libadwaita` |
| `checkdepends` | `lua` (engine unit tests; `glslang` additionally compiles the generated shaders when installed) |
| `optdepends` | `hyprpm`, `cmake`, `meson`, `cpio`, `gcc`, `pkgconf` — only to build the optional plugin |

## Building

From a clone. `makepkg` would otherwise use `./src`, this repository's code directory, as its
`$srcdir`; `BUILDDIR` moves its scratch space away:

```bash
BUILDDIR=/tmp/hyprland-zoom-build makepkg -si     # build, run check(), install
BUILDDIR=/tmp/hyprland-zoom-build makepkg -f --nocheck --nodeps    # just the package
```

`check()` runs `make test-core` (bash suites, Lua unit tests). The package is `arch=('any')`;
the PKGBUILD has no `source=` because it packages the checkout it lives in. An AUR copy would
use a tagged source tarball and its checksum instead; the file list is identical.

Local development without installing: run `src/zoomctl` from the checkout (it finds
`src/lib`, `config/settings.schema` and `src/ui` relative to itself); `ZOOMCTL_SHARE_DIR`
points components at another share directory, for example a `make install DESTDIR=...` tree.

## The install hook

`install/post_install.sh` is the package's `install=` scriptlet:

- `post_install` / `post_upgrade` run the same wiring as `zoomctl setup` for the installing
  user: append `dofile("/usr/share/hyprland-zoom/hyprland-zoom.lua")` to `hyprland.lua`
  (migrating a 0.1 include line, backup first) or add the `source =` line to a legacy
  `hyprland.conf`. Without a usable home directory (a plain root transaction) it prints what
  to do instead.
- `post_remove` removes those lines again.

The scriptlet deliberately carries its own copy of the wiring code (the "shared wiring block",
kept byte-identical with `src/lib/setup.sh` by the setup test): pacman deletes a package's
files **before** it runs `post_remove`, so the hook cannot depend on anything the package
ships.

## The version

`VERSION` is the single source. It is mirrored, and checked by `tests/repo`, in:

| Place | Form |
|---|---|
| `PKGBUILD` | `pkgver=0.2.0` |
| `.SRCINFO` | generated: `makepkg --printsrcinfo > .SRCINFO` |
| `src/lib/common.sh` | `ZOOMCTL_VERSION='0.2.0'` |
| `src/lua/hyprland-zoom/api.lua` | `M.VERSION = "0.2.0"` |
| `plugin/main.cpp` | the plugin's version string |

## Releasing

1. Bump `VERSION` and the four mirrors above; add the section to `CHANGELOG.md`.
2. `makepkg --printsrcinfo > .SRCINFO`.
3. For a Hyprland release you tested the plugin against, add a pin to `hyprpm.toml`:
   `["<full Hyprland commit hash>", "<hyprland-zoom commit that builds against it>"]`.
4. `make check lint qa test` and push; wait for CI.
5. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`. The release workflow checks that
   tag, `VERSION` and `pkgver` agree, builds the package in a clean Arch container and attaches
   `hyprland-zoom-<version>-<rel>-any.pkg.tar.zst` and `sha256sums` to a GitHub release whose
   notes are the changelog section.

## Quality gate and CI

Local commands (all of them run in CI):

| Command | What it does |
|---|---|
| `make check` | syntax of every bash, Lua and python file, `desktop-file-validate`, generated settings tables up to date |
| `make lint` | shellcheck (`uvx --from shellcheck-py shellcheck` when not installed) |
| `make qa` | the coding-standard gate: `tools/techdoc/techdoc.py check` (rules R1–R8) and `tools/qa/comment-runs.py` for python |
| `make test` | `test-core` (bash + Lua), `test-gui` (settings app on GTK Broadway), `test-plugin` (plugin unit tests), `test-repo` (techdoc tests, versions, install layout, workflows, docs) |
| `make docs` | the generated technical documentation into `public/` |
| `make docs-sync` | refresh the settings tables in `docs/configuration.md` |

Tests that need a Wayland session (`tests/integration/`, `tests/plugin/nested_test.py`) start a
nested Hyprland and are local only.

GitHub Actions (`.github/workflows/`, actions pinned to major versions, minimal
`permissions`, `concurrency` and timeouts everywhere):

| Workflow | Trigger | Jobs |
|---|---|---|
| `ci.yml` | push, pull request | `static` (check, lint, qa, repository tests; ubuntu) · `tests` (bash + Lua, Arch container) · `gui` (Arch container, Broadway) · `package` (makepkg with `check()`, `.SRCINFO` diff, namcap, `pacman -U`, run, remove) · `plugin` (Arch container with the `hyprland` headers: unit tests and a real build of `hyprzoom.so`) |
| `docs.yml` | push | builds the technical documentation (artifact on every branch); pushes to `main` and `beta` publish it on GitHub Pages |
| `release.yml` | tag `v*` | builds the package, attaches it with `sha256sums` to a GitHub release |

The plugin job builds against whatever Hyprland Arch currently ships. The plugin supports
0.56.x and 0.57.x (picked at compile time); a red `plugin` job after a Hyprland update is the signal that the hook needs porting
(see the [roadmap](roadmap.md)).

GitHub Pages must be switched to *GitHub Actions* as its source once
(*Settings → Pages*); the site then lives at https://artibex.github.io/hyprland-zoom/.

## Generated technical documentation

`tools/techdoc` (stdlib only, documented in its own README) reads the repository and writes a
static site: every shell and python script with its contract headers, the Lua engine and the
C++ plugin, the settings reference from `config/settings.schema`, the CLI reference parsed from
`zoomctl help`, the CI workflows and the gate verdict. It runs without executing any
repository code.

## Runtime state

Zoom level, filter state and generated shaders live in `$XDG_RUNTIME_DIR/hyprland-zoom/`
(`ZOOMCTL_STATE_DIR` overrides it) and disappear with the session. The 0.1 file
`$XDG_RUNTIME_DIR/zoomctl/last_zoom` is read once when present.
