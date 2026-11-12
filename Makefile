# hyprland-zoom — build, check, test, QA, docs and install targets.
#
# `make install DESTDIR=<staging> PREFIX=/usr` is what the PKGBUILD calls. Files are picked up
# by directory globs, so a new Lua module, shader, library or UI module needs no edit here.
# Per-user wiring (the include line in hyprland.lua) is never done by `make`; that is
# `zoomctl setup`, run by the package hook or by the user.

# Where everything goes; DESTDIR is the staging root of a package build.
PREFIX      ?= /usr
DESTDIR     ?=
# The system config lives in /etc even for a /usr prefix (pacman backup= handles it).
SYSCONFDIR  ?= /etc
# Output directory of `make docs` (ignored by git).
DOCS_OUT    ?= public
# Tools; override on the command line when yours are named differently.
PYTHON      ?= python3
LUAC        ?= luac
# A local shellcheck wins, else the pip wheel through uv (CI installs the distro package).
SHELLCHECK  ?= $(shell command -v shellcheck 2>/dev/null || echo uvx --from shellcheck-py shellcheck)

# Application id of the settings app: names the desktop file and the icons (contract C8).
APP_ID      = io.github.artibex.HyprlandZoom

# Installed locations derived from the variables above.
BINDIR      = $(DESTDIR)$(PREFIX)/bin
SHAREDIR    = $(DESTDIR)$(PREFIX)/share/hyprland-zoom
APPDIR      = $(DESTDIR)$(PREFIX)/share/applications
ICONDIR     = $(DESTDIR)$(PREFIX)/share/icons/hicolor
DOCDIR      = $(DESTDIR)$(PREFIX)/share/doc/hyprland-zoom
LICENSEDIR  = $(DESTDIR)$(PREFIX)/share/licenses/hyprland-zoom

# Python syntax check that writes nothing: compile() only parses, so no __pycache__ appears.
define SYNTAX_CHECK
import sys
for name in sys.argv[1:]:
    compile(open(name, encoding='utf-8').read(), name, 'exec')
endef
export SYNTAX_CHECK

# Source groups, found by glob so that new files are picked up automatically.
SHELL_SOURCES  = src/zoomctl $(wildcard src/lib/*.sh) install/post_install.sh
SHELL_TESTS    = $(wildcard tests/*.sh tests/lib/*.sh tests/gui/*.sh tests/lua/*.sh \
                 tests/plugin/*.sh tests/integration/*.sh tests/repo/*.sh) \
                 tests/fixtures/fake-hyprctl
LUA_SOURCES    = $(shell find src config tests -name '*.lua' 2>/dev/null)
# The gate and its unit tests treat these python files as part of the code base.
PYTHON_SOURCES = $(shell git ls-files '*.py' 2>/dev/null | grep -v 'techdoc/fixtures/')
# Python scripts without .py suffix: the comment checker only reads *.py, so they are copied.
PYTHON_SCRIPTS = src/ui/hyprland-zoom-settings tests/gui/fixtures/fake-zoomctl

.PHONY: help all check lint qa test test-core test-gui test-plugin test-repo docs \
        docs-sync install uninstall clean

# Default target: list what can be done.
help:
	@echo "make check      syntax of every bash, Lua and python file, desktop file, docs tables"
	@echo "make lint       shellcheck over the shell sources and test scripts"
	@echo "make qa         coding-standard gate (techdoc R1-R8 + python comment runs)"
	@echo "make test       every test suite (core, gui, plugin units, repository checks)"
	@echo "make docs       generated technical documentation into DOCS_OUT (default public/)"
	@echo "make docs-sync  refresh the generated settings tables of docs/configuration.md"
	@echo "make install    install into DESTDIR (default /) below PREFIX (default /usr)"

# Nothing to compile: the plugin is built by hyprpm on the user's machine.
all:
	@echo "Nothing to build. Run 'make install' (optionally with PREFIX and DESTDIR)."

# Syntax-check every script without running it, plus the generated docs and the desktop file.
check:
	bash -n $(SHELL_SOURCES) $(SHELL_TESTS)
	$(LUAC) -p $(LUA_SOURCES)
# compile() only parses, so no __pycache__ appears in the working tree.
	$(PYTHON) -c "$$SYNTAX_CHECK" $(PYTHON_SOURCES) $(PYTHON_SCRIPTS)
# The desktop file check is skipped (loudly) when the validator is not installed.
	if command -v desktop-file-validate >/dev/null 2>&1; then \
	  desktop-file-validate data/$(APP_ID).desktop; \
	else echo "SKIP desktop-file-validate not installed"; fi
	$(PYTHON) tools/techdoc/techdoc.py settings-doc --check

# shellcheck: -x follows sourced libraries; the exclusions are cross-file tables (SC2034) and
# associative-array subscripts (SC2004), the same set as tests/run.sh.
lint:
	$(SHELLCHECK) -x -e SC1090,SC1091,SC2034,SC2004 $(SHELL_SOURCES) $(SHELL_TESTS)

# The coding-standard gate: techdoc covers shell, python docstrings and Lua headers, the
# comment-run checker covers python statements without an intent comment.
qa:
	$(PYTHON) tools/techdoc/techdoc.py check
	$(PYTHON) tools/qa/comment-runs.py $(PYTHON_SOURCES)
# Extensionless python scripts are checked through a .py copy.
	status=0; for script in $(PYTHON_SCRIPTS); do \
	  copy="$$(mktemp --suffix=.py)"; cp "$$script" "$$copy"; \
	  $(PYTHON) tools/qa/comment-runs.py "$$copy" || status=1; rm -f "$$copy"; \
	done; exit $$status

# Every suite; each is also available on its own below.
test: test-core test-gui test-plugin test-repo

# Bash suites, shellcheck (when installed) and the Lua unit tests.
test-core:
	bash tests/run.sh

# The settings app on a headless GTK Broadway display (needs gtk4, libadwaita, python-gobject).
test-gui:
	bash tests/gui/run.sh

# Plugin unit tests and native-equivalence test; the .so build is the CI plugin job.
test-plugin:
	bash tests/plugin/run.sh --no-build

# Tests of the repository itself: the techdoc tool and the packaging / docs consistency checks.
test-repo:
	cd tools/techdoc && $(PYTHON) -m unittest
	$(PYTHON) -m unittest discover -s tests/repo -p 'test_*.py'

# The technical documentation site; rule violations never fail it (see quality.html).
docs:
	$(PYTHON) tools/techdoc/techdoc.py build --out $(DOCS_OUT)

# Regenerate the settings tables inside docs/configuration.md from config/settings.schema.
docs-sync:
	$(PYTHON) tools/techdoc/techdoc.py settings-doc

# Install everything the package ships. Directory globs keep this target stable when files
# are added; `install -D` creates the parent directories.
install:
	install -Dm755 src/zoomctl                           $(BINDIR)/zoomctl
	install -Dm755 src/ui/hyprland-zoom-settings         $(BINDIR)/hyprland-zoom-settings
# Shell libraries of zoomctl.
	for file in src/lib/*.sh; do \
	  install -Dm644 "$$file" "$(SHAREDIR)/lib/$$(basename "$$file")" || exit 1; done
# Lua engine: entry file plus its modules in <share>/lua/hyprland-zoom/.
	install -Dm644 src/lua/hyprland-zoom.lua             $(SHAREDIR)/hyprland-zoom.lua
	for file in src/lua/hyprland-zoom/*.lua; do \
	  install -Dm644 "$$file" "$(SHAREDIR)/lua/hyprland-zoom/$$(basename "$$file")" \
	    || exit 1; done
# GLSL shader templates, the settings schema and the bind files.
	for file in src/shaders/*.glsl; do \
	  install -Dm644 "$$file" "$(SHAREDIR)/shaders/$$(basename "$$file")" || exit 1; done
	install -Dm644 config/settings.schema                $(SHAREDIR)/settings.schema
	install -Dm644 config/hyprland-bindings.lua          $(SHAREDIR)/hyprland-bindings.lua
	install -Dm644 config/hyprland-bindings.conf         $(SHAREDIR)/hyprland-bindings.conf
	install -Dm644 VERSION                               $(SHAREDIR)/VERSION
# The settings app package (no __pycache__: only *.py is copied).
	for file in src/ui/hyprland_zoom_settings/*.py; do \
	  install -Dm644 "$$file" \
	    "$(SHAREDIR)/ui/hyprland_zoom_settings/$$(basename "$$file")" || exit 1; done
# Desktop file and icons, laid out like the source tree below data/.
	install -Dm644 data/$(APP_ID).desktop                $(APPDIR)/$(APP_ID).desktop
	cd data/icons/hicolor && find . -type f -name '*.svg' | while read -r file; do \
	  install -Dm644 "$$file" "$(ICONDIR)/$$file" || exit 1; done
# System defaults (a pacman backup= file) and the documentation.
	install -Dm644 config/defaults.conf                  $(DESTDIR)$(SYSCONFDIR)/zoomctl.conf
	install -Dm644 README.md                             $(DOCDIR)/README.md
	install -Dm644 CHANGELOG.md                          $(DOCDIR)/CHANGELOG.md
	for file in docs/*.md; do \
	  install -Dm644 "$$file" "$(DOCDIR)/$$(basename "$$file")" || exit 1; done
	install -Dm644 LICENSE                               $(LICENSEDIR)/LICENSE

# Remove what `install` put in place (not the user's own config in ~/.config/zoomctl).
uninstall:
	rm -f  $(BINDIR)/zoomctl $(BINDIR)/hyprland-zoom-settings
	rm -rf $(SHAREDIR) $(DOCDIR) $(LICENSEDIR)
	rm -f  $(APPDIR)/$(APP_ID).desktop
	rm -f  $(ICONDIR)/scalable/apps/$(APP_ID).svg
	rm -f  $(ICONDIR)/symbolic/apps/$(APP_ID)-symbolic.svg
	rm -f  $(DESTDIR)$(SYSCONFDIR)/zoomctl.conf

# Generated output only; nothing tracked is touched.
clean:
	rm -rf $(DOCS_OUT)
