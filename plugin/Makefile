# Makefile — builds plugin/hyprzoom.so against the installed Hyprland headers.
#
# `hyprpm` runs `make -C plugin` (see ../hyprpm.toml) in the repository checkout; the pkg-config
# search path then points at the headers matching the running Hyprland. Plugins must be built
# with the compiler and C++ standard Hyprland itself uses (C++26 in 0.56, `-std=c++2c`).

# Compiler: same family Hyprland was built with (Arch builds Hyprland with GCC).
CXX      ?= g++
# Libraries whose headers Hyprland's public headers pull in.
PKGS     := hyprland pixman-1 libdrm pangocairo libinput libudev wayland-server xkbcommon
# --no-gnu-unique keeps the plugin unloadable (dlclose) with libstdc++ statics.
CXXFLAGS ?= -O2 -g
CXXFLAGS += -shared -fPIC --no-gnu-unique -std=c++2c -Wall -Wextra -DWLR_USE_UNSTABLE \
            $(shell pkg-config --cflags $(PKGS))
# Everything the .so consists of, in dependency order.
SOURCES  := main.cpp zoom_hook.cpp
HEADERS  := camera_math.hpp hyprland_includes.hpp plugin_state.hpp zoom_hook.hpp

# Default target: the loadable plugin.
all: hyprzoom.so

# One translation unit set, no object files: the plugin is tiny.
hyprzoom.so: $(SOURCES) $(HEADERS)
	$(CXX) $(CXXFLAGS) $(SOURCES) -o $@

# Remove build output.
clean:
	rm -f hyprzoom.so

.PHONY: all clean
