"""Parse ``zoomctl`` porcelain output (``KEY=VALUE`` lines) and describe the engine status."""

# dataclasses carry the typed status, typing documents optional numbers.
from dataclasses import dataclass
from typing import Dict, Optional

# Engine states from contract C6, plus our own marker for "zoomctl did not answer".
ENGINE_MISSING = "missing"
ENGINE_UNREACHABLE = "unreachable"
PLUGIN_LOADED = "loaded"


def parse_key_values(text: str) -> Dict[str, str]:
    """Parse ``KEY=VALUE`` lines.

    Args:
        text: Porcelain output; blank lines, comments and lines without ``=`` are ignored.

    Returns:
        Mapping key -> value in output order (later duplicates win).
    """
    pairs: Dict[str, str] = {}
    for line in text.splitlines():
        # Only the first '=' separates key and value; values may contain '='.
        key, separator, value = line.partition("=")
        key = key.strip()
        if separator and key and not key.startswith("#"):
            pairs[key] = value.strip()
    return pairs


def _to_float(text: str) -> Optional[float]:
    """Read a float, tolerating junk.

    Args:
        text: Candidate number.

    Returns:
        The number, or None when it cannot be parsed.
    """
    # Status output must never crash the UI, so bad numbers become "unknown".
    try:
        return float(text)
    except ValueError:
        return None


@dataclass(frozen=True)
class EngineStatus:
    """Typed view of ``zoomctl status --porcelain`` (contract C6)."""

    engine: str = ENGINE_UNREACHABLE
    version: str = ""
    hyprland: str = ""
    zoom: Optional[float] = None
    saved_zoom: Optional[float] = None
    tracking: str = ""
    tracking_effective: str = ""
    plugin: str = "missing"
    filter: str = ""
    filter_active: bool = False

    @property
    def plugin_loaded(self) -> bool:
        """Tell whether the hyprzoom plugin is active.

        Returns:
            True when status reports ``plugin=loaded``.
        """
        # Anything but "loaded" (including an unreachable engine) counts as not available.
        return self.plugin == PLUGIN_LOADED

    @property
    def engine_missing(self) -> bool:
        """Tell whether the engine still has to be set up.

        Returns:
            True when status reports ``engine=missing``.
        """
        # The banner with the "Set up" action keys off this value only.
        return self.engine == ENGINE_MISSING


def parse_status(text: str) -> EngineStatus:
    """Build an EngineStatus from porcelain output; unknown keys are ignored.

    Args:
        text: Output of ``zoomctl status --porcelain``.

    Returns:
        The status; missing fields keep their defaults.
    """
    pairs = parse_key_values(text)
    return EngineStatus(
        engine=pairs.get("engine", ENGINE_UNREACHABLE),
        version=pairs.get("version", ""),
        hyprland=pairs.get("hyprland", ""),
        zoom=_to_float(pairs.get("zoom", "")),
        saved_zoom=_to_float(pairs.get("saved_zoom", "")),
        tracking=pairs.get("tracking", ""),
        tracking_effective=pairs.get("tracking_effective", pairs.get("tracking", "")),
        plugin=pairs.get("plugin", "missing"),
        filter=pairs.get("filter", ""),
        filter_active=pairs.get("filter_active", "off") == "on",
    )


def describe_status(status: EngineStatus) -> str:
    """Compose the one-line live status shown under the settings.

    Args:
        status: Current engine status.

    Returns:
        For example ``Zoom 1.50× · Tracking: centered · Engine: lua``.
    """
    # An unreachable CLI gets an explicit sentence instead of a row of empty fields.
    if status.engine == ENGINE_UNREACHABLE:
        return "zoomctl is not answering"
    zoom_text = "unknown" if status.zoom is None else f"{status.zoom:.2f}×"
    tracking = status.tracking_effective or status.tracking or "unknown"
    # A configured mode that differs from the effective one is called out (plugin missing).
    if status.tracking and status.tracking != tracking:
        tracking = f"{tracking} (configured: {status.tracking})"
    filter_state = f"{status.filter or 'none'} {'on' if status.filter_active else 'off'}"
    return (
        f"Zoom {zoom_text} · Tracking: {tracking} · Filter: {filter_state}"
        f" · Engine: {status.engine}"
    )
