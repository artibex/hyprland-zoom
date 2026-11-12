"""Layout helpers: the text scale of the desktop and the window size that follows from it.

Window sizes are in pixels while text grows with the user's text scale, so a fixed default
size that is comfortable at 100 % text is cramped at 164 %; ``sizing.default_window_size``
turns the scale read here into a size (kept GTK-free so it can be unit tested).
"""

# typing documents the size tuple.
from typing import Optional, Tuple

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import REFERENCE_DPI, XFT_DPI_DIVISOR  # noqa: E402


def text_scale(settings: Optional[Gtk.Settings] = None) -> float:
    """Read the desktop's text scale (1.0 = 96 dpi).

    Args:
        settings: GTK settings to read (defaults to the current display's).

    Returns:
        The font resolution relative to 96 dpi; 1.0 when the setting is unavailable.
    """
    settings = settings or Gtk.Settings.get_default()
    if settings is None:
        return 1.0
    # GTK stores the resolution in 1/1024 dpi; a negative value means "not configured".
    dpi = settings.get_property("gtk-xft-dpi")
    return dpi / XFT_DPI_DIVISOR / REFERENCE_DPI if dpi > 0 else 1.0


def monitor_size(display: Optional[Gdk.Display]) -> Optional[Tuple[int, int]]:
    """Find the size of the first monitor.

    Args:
        display: The display, or None.

    Returns:
        ``(width, height)`` in pixels, or None when no monitor is known (e.g. Broadway).
    """
    if display is None:
        return None
    monitors = display.get_monitors()
    # An empty list or a monitor without geometry means "unknown".
    if monitors is None or monitors.get_n_items() == 0:
        return None
    geometry = monitors.get_item(0).get_geometry()
    return (geometry.width, geometry.height) if geometry.width > 0 else None
