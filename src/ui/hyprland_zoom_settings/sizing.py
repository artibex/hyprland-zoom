"""Window sizing: the default window size that follows from the text scale (no GTK needed)."""

# typing documents the optional monitor size.
from typing import Optional, Tuple

from .constants import BASE_HEIGHT, BASE_WIDTH, MONITOR_FRACTION


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
