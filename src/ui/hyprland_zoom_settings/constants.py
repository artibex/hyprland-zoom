"""Application-wide constants: identifiers, timings, layout sizes and installation texts."""

# Application id from contract C8; it is also the Wayland app id and the icon name.
APP_ID = "io.github.artibex.HyprlandZoom"
# Human-readable application name: window title, launcher entry and about dialog.
APP_NAME = "Hyprland Zoom"
# Project page shown in the about dialog.
PROJECT_URL = "https://github.com/artibex/hyprland-zoom"

# Slider changes are sent to zoomctl only after the slider rested this long (milliseconds).
DEBOUNCE_MILLISECONDS = 250
# The live status line is refreshed this often while the window is visible (seconds).
STATUS_REFRESH_SECONDS = 1
# The configuration is re-read on every Nth status refresh to notice edits made elsewhere.
CONFIG_POLL_TICKS = 3
# A zoomctl call that runs longer than this is killed and reported as an error (seconds).
COMMAND_TIMEOUT_SECONDS = 15
# Key presses this soon after the capture dialog opened are ignored (held Enter repeats).
KEY_CAPTURE_GRACE_MILLISECONDS = 300

# "Try it": zoom level, duration of the zoom test and of the filter preview (seconds).
ZOOM_TEST_FACTOR = 2.0
ZOOM_TEST_SECONDS = 5
FILTER_PREVIEW_SECONDS = 10

# Float settings with a value range up to this span get a slider, wider ones a spin box.
SLIDER_MAX_SPAN = 5.0
# Enum settings with at most this many presented options may be shown as a choice list.
CHOICE_LIST_MAX_OPTIONS = 8

# Layout: below this width (in text-scaled units) the page list and the page content are
# shown one after the other instead of side by side.
COLLAPSE_CONDITION = "max-width: 560sp"
# Preferred window size at normal text size; it grows with the text scale (see layout.py).
BASE_WIDTH = 820
BASE_HEIGHT = 640
# A default window never covers more than this fraction of the monitor.
MONITOR_FRACTION = 0.9
# Outputs smaller than this are no real screens (a nested compositor's host window).
MIN_USABLE_MONITOR = (800, 600)
# GTK reports the font resolution in 1/1024 dpi; 96 dpi is the unscaled reference.
XFT_DPI_DIVISOR = 1024
REFERENCE_DPI = 96

# Environment variables that point the app at a different zoomctl or share directory.
ENV_ZOOMCTL_BIN = "ZOOMCTL_BIN"
ENV_SHARE_DIR = "ZOOMCTL_SHARE_DIR"
# Installed location of the shared data (schema, engine, ui) and the zoomctl command name.
# The entry script keeps its own copy: it needs the path before this package is importable.
DEFAULT_SHARE_DIR = "/usr/share/hyprland-zoom"
DEFAULT_ZOOMCTL = "zoomctl"

# Installing the optional margin plugin: the commands in order and the shipped guide.
PLUGIN_INSTALL_COMMANDS = (
    "sudo pacman -S hyprpm",
    "hyprpm add https://github.com/artibex/hyprland-zoom",
    "hyprpm enable hyprzoom",
    "hyprpm reload",
)
PLUGIN_GUIDE_PATH = "/usr/share/doc/hyprland-zoom/plugin.md"
