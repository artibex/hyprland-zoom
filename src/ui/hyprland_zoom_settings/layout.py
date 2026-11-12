"""Layout helpers: the text scale of the desktop and the window size that follows from it.

Window sizes are in pixels while text grows with the user's text scale, so a fixed default
size that is comfortable at 100 % text is cramped at 164 %. The default size therefore grows
with the scale (never beyond the monitor).
"""

# typing documents the size tuple.
from typing import Optional, Tuple

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import (  # noqa: E402
    BASE_HEIGHT, BASE_WIDTH, MONITOR_FRACTION, REFERENCE_DPI, XFT_DPI_DIVISOR,
)


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


def default_window_size(
    scale: float, monitor: Optional[Tuple[int, int]]
) -> Tuple[int, int]:
    """Choose the window size that fits the text scale and the monitor.

    Args:
        scale: Text scale (1.0 = normal).
        monitor: Monitor size in pixels, or None when unknown.

    Returns:
        ``(width, height)``; larger text gets a proportionally larger window, but never more
        than ``MONITOR_FRACTION`` of the monitor.
    """
    # Smaller than normal text does not shrink the window below its base size.
    factor = max(1.0, scale)
    width, height = round(BASE_WIDTH * factor), round(BASE_HEIGHT * factor)
    if monitor is None:
        return width, height
    # The window must stay reachable: it is capped to a share of the monitor.
    return (min(width, round(monitor[0] * MONITOR_FRACTION)),
            min(height, round(monitor[1] * MONITOR_FRACTION)))
