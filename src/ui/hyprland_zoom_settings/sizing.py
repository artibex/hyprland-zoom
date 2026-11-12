"""Window sizing: the default window size that follows from the text scale (no GTK needed)."""

# typing documents the optional monitor size.
from typing import Iterable, Optional, Tuple

from .constants import BASE_HEIGHT, BASE_WIDTH, MIN_USABLE_MONITOR, MONITOR_FRACTION


def smallest_usable_monitor(sizes: Iterable[Tuple[int, int]]) -> Optional[Tuple[int, int]]:
    """Pick the monitor size the default window must fit on.

    Args:
        sizes: ``(width, height)`` of every monitor, in pixels.

    Returns:
        The smallest size that is still a real screen (tiny outputs such as a nested
        compositor's host window are ignored), or None when there is none.
    """
    # The window may open on any monitor, so the smallest real one sets the limit.
    usable = [size for size in sizes
              if size[0] >= MIN_USABLE_MONITOR[0] and size[1] >= MIN_USABLE_MONITOR[1]]
    return min(usable, key=lambda size: size[0] * size[1]) if usable else None


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
