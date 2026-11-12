"""Application-wide constants: identifiers, timings and the few presentation thresholds."""

# Application id from contract C8; it is also the Wayland app id and the icon name.
APP_ID = "io.github.artibex.HyprlandZoom"
# Human-readable application name for the window title and the about dialog.
APP_NAME = "Zoom Settings"
# Project page shown in the about dialog and in the plugin hint.
PROJECT_URL = "https://github.com/artibex/hyprland-zoom"

# Slider changes are sent to zoomctl only after the slider rested this long (milliseconds).
DEBOUNCE_MILLISECONDS = 250
# The live status line is refreshed this often while the window is visible (seconds).
STATUS_REFRESH_SECONDS = 1
# A zoomctl call that runs longer than this is killed and reported as an error (seconds).
COMMAND_TIMEOUT_SECONDS = 15

# "Try it": zoom level, duration of the zoom test and of the filter preview (seconds).
ZOOM_TEST_FACTOR = 2.0
ZOOM_TEST_SECONDS = 5
FILTER_PREVIEW_SECONDS = 10

# Float settings with a value range up to this span get a slider, wider ones a spin box.
SLIDER_MAX_SPAN = 5.0
# Enum settings with at most this many presented options may be shown as a choice list.
CHOICE_LIST_MAX_OPTIONS = 8

# Environment variables that point the app at a different zoomctl or share directory.
ENV_ZOOMCTL_BIN = "ZOOMCTL_BIN"
ENV_SHARE_DIR = "ZOOMCTL_SHARE_DIR"
# Installed location of the shared data (schema, engine, ui) and the zoomctl command name.
DEFAULT_SHARE_DIR = "/usr/share/hyprland-zoom"
DEFAULT_ZOOMCTL = "zoomctl"
