# Makefile — builds plugin/hyprzoom.so against the installed Hyprland headers.
#
# `hyprpm` runs `make -C plugin` (see ../hyprpm.toml) in the repository checkout; the pkg-config
# search path then points at the headers matching the running Hyprland (0.56.x or 0.57.x, the
# sources pick the right hook signature from the headers, see api_version.hpp). Plugins must be
# built with the compiler and C++ standard Hyprland itself uses (C++26, `-std=c++2c`).

# Compiler: same family Hyprland was built with (Arch builds Hyprland with GCC).
CXX      ?= g++
# Libraries whose headers Hyprland's public headers pull in.
PKGS     := hyprland pixman-1 libdrm pangocairo libinput libudev wayland-server xkbcommon
# The plugin version has one source, the repository's VERSION file (hyprpm builds inside the
# clone, so ../VERSION exists). Override on the command line for a copy outside the repository.
HYPRZOOM_VERSION ?= $(strip $(shell cat ../VERSION 2>/dev/null))
ifeq ($(HYPRZOOM_VERSION),)
$(error ../VERSION not found or empty: build inside the repository or pass HYPRZOOM_VERSION=x.y.z)
endif
# Release builds carry no debug info (hyprpm ships whatever `make` produces); `make DEBUG=1`
# opts in.
CXXFLAGS ?= -O2
ifeq ($(DEBUG),1)
CXXFLAGS += -g
endif
# --no-gnu-unique keeps the plugin unloadable (dlclose) with libstdc++ statics.
CXXFLAGS += -shared -fPIC --no-gnu-unique -std=c++2c -Wall -Wextra -DWLR_USE_UNSTABLE \
            -DHYPRZOOM_VERSION='"$(HYPRZOOM_VERSION)"' \
            $(shell pkg-config --cflags $(PKGS)) $(EXTRA_CXXFLAGS)
# Hook for tests and packagers: extra flags that cannot clobber the required ones above.
EXTRA_CXXFLAGS ?=
# Everything the .so consists of, in dependency order.
SOURCES  := main.cpp zoom_hook.cpp
HEADERS  := api_version.hpp camera_math.hpp hook_target.hpp hyprland_includes.hpp \
            plugin_state.hpp zoom_hook.hpp

# Default target: the loadable plugin.
all: hyprzoom.so

# One translation unit set, no object files: the plugin is tiny. The Makefile itself is a
# prerequisite so a flag change rebuilds.
hyprzoom.so: $(SOURCES) $(HEADERS) Makefile
	$(CXX) $(CXXFLAGS) $(SOURCES) -o $@

# Remove build output.
clean:
	rm -f hyprzoom.so

# Print the version the build embeds (used by the repository tests).
print-version:
	@echo $(HYPRZOOM_VERSION)

.PHONY: all clean print-version
