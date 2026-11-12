"""Parse ``zoomctl`` porcelain output (``KEY=VALUE`` lines) and describe the engine status."""

# dataclasses carry the typed status, typing documents optional numbers.
from dataclasses import dataclass
from typing import Dict, Optional

from .presentation import FALLBACK_NOTES, TRACKING_PHRASES, option_label

# Engine states from contract C6, plus our own marker for "zoomctl did not answer".
ENGINE_LUA = "lua"
ENGINE_LEGACY = "legacy"
ENGINE_MISSING = "missing"
ENGINE_UNREACHABLE = "unreachable"
# Plugin state word of contract C6.
PLUGIN_LOADED = "loaded"
# What zoomctl reports as the compositor version when it cannot reach Hyprland.
HYPRLAND_UNKNOWN = "unknown"
# The tracking mode that needs the optional plugin, and what Hyprland does without it.
MARGIN_MODE = "margin"
FALLBACK_MODE = "edge"

# What the window has to tell the user about the engine, derived in ``EngineStatus.state``.
STATE_READY = "ready"
STATE_COMPATIBILITY = "compatibility"
STATE_NEEDS_SETUP = "needs-setup"
STATE_NO_HYPRLAND = "no-hyprland"
# zoomctl itself did not answer.
STATE_NO_ZOOMCTL = "no-zoomctl"


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
    # Callers get a plain dict they can look keys up in.
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
    # Zoom levels are None while unknown (status unreachable).
    zoom: Optional[float] = None
    saved_zoom: Optional[float] = None
    tracking: str = ""
    # Effective mode differs from the configured one without the plugin.
    tracking_effective: str = ""
    plugin: str = "missing"
    filter: str = ""
    # Filter on/off as a real boolean for the status line.
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
        """Tell whether the engine is reported as missing.

        Returns:
            True when status reports ``engine=missing``.
        """
        # Kept for callers that only care about the raw engine word.
        return self.engine == ENGINE_MISSING

    @property
    def state(self) -> str:
        """Classify the situation for the window (banner, buttons, status line).

        Returns:
            One of the ``STATE_*`` constants.
        """
        if self.engine == ENGINE_UNREACHABLE:
            return STATE_NO_ZOOMCTL
        # The normal case: the Lua engine answers.
        if self.engine == ENGINE_LUA:
            return STATE_READY
        # Without a reachable compositor no setup can help, so it is told apart.
        if self.hyprland == HYPRLAND_UNKNOWN:
            return STATE_NO_HYPRLAND
        return STATE_NEEDS_SETUP if self.engine == ENGINE_MISSING else STATE_COMPATIBILITY


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


def format_zoom(zoom: Optional[float]) -> str:
    """Write a zoom level the way people say it.

    Args:
        zoom: Zoom factor, or None when unknown.

    Returns:
        For example ``1.5×`` or ``2×``; ``unknown`` for None.
    """
    # Trailing zeros are noise in a sentence: "1.50×" reads worse than "1.5×".
    if zoom is None:
        return "unknown"
    return f"{zoom:.2f}".rstrip("0").rstrip(".") + "×"


def describe_status(status: EngineStatus, received: bool = True) -> str:
    """Compose the one-line live status shown under the settings.

    Args:
        status: Current engine status.
        received: False until the first answer arrived (shows a neutral text).

    Returns:
        For example ``Zoom 1.5× · Pointer centered · Smart invert on``.
    """
    # Before the first answer nothing is known, which is not an error.
    if not received:
        return "Checking…"
    unusable = {
        STATE_NO_ZOOMCTL: "zoomctl is not answering",
        STATE_NO_HYPRLAND: "Hyprland is not reachable",
        STATE_NEEDS_SETUP: "The zoom engine is not set up",
    }.get(status.state)
    # A state that cannot show details is reported as one plain sentence.
    if unusable:
        return unusable
    parts = [f"Zoom {format_zoom(status.zoom)}", _tracking_phrase(status), _filter_phrase(status)]
    # The engine is mentioned only when it is not the normal one.
    if status.state == STATE_COMPATIBILITY:
        parts.append("Compatibility mode (limited)")
    return " · ".join(parts)


def _tracking_phrase(status: EngineStatus) -> str:
    """Word the tracking mode Hyprland is really using.

    Args:
        status: Current engine status.

    Returns:
        A short phrase such as ``Pointer centered``.
    """
    # The effective mode is what the user experiences; the configured one is on its page.
    mode = status.tracking_effective or status.tracking
    return TRACKING_PHRASES.get(mode, "Pointer tracking unknown")


def _filter_phrase(status: EngineStatus) -> str:
    """Word the color filter state.

    Args:
        status: Current engine status.

    Returns:
        ``Smart invert on`` while a filter runs, otherwise ``Color filter off``.
    """
    # An inactive filter is just "off": its name would suggest it is running.
    if not status.filter_active:
        return "Color filter off"
    return f"{option_label('FILTER', status.filter)} on"


@dataclass(frozen=True)
class TrackingNotice:
    """Plain-language explanation of a tracking mode Hyprland does not use as configured.

    Attributes:
        title: One short sentence.
        body: The reason, in one or two sentences.
        needs_plugin: True when installing the hyprzoom plugin would resolve it.
    """

    title: str
    body: str
    needs_plugin: bool = False


def tracking_notice(configured: str, status: EngineStatus) -> Optional[TrackingNotice]:
    """Explain a tracking mode that Hyprland does not use as configured.

    Args:
        configured: The tracking mode from the configuration.
        status: Current engine status.

    Returns:
        The notice, or None when nothing needs explaining.
    """
    # Nothing is known before the engine answers, so there is nothing to explain.
    if status.state != STATE_READY:
        return None
    # Margin without its plugin has its own explanation and a fix.
    if configured == MARGIN_MODE and not status.plugin_loaded:
        return _missing_plugin_notice()
    effective = status.tracking_effective
    # Agreeing modes (or an unknown one) need no words.
    if not effective or effective == configured:
        return None
    wanted, using = (option_label("ZOOM_TRACKING", mode) for mode in (configured, effective))
    return TrackingNotice(
        f"Hyprland is using {using}", f"{wanted} is selected, but Hyprland uses {using}."
    )


def _missing_plugin_notice() -> TrackingNotice:
    """Word the notice for margin mode without the hyprzoom plugin.

    Returns:
        The notice; its body names the mode Hyprland falls back to.
    """
    # Without the plugin Hyprland uses edge mode with its fixed margin (contract E5); the
    # reported effective mode may lag behind a change made a moment ago, so it is not used.
    label = option_label("ZOOM_TRACKING", FALLBACK_MODE)
    note = FALLBACK_NOTES.get(FALLBACK_MODE, "")
    return TrackingNotice(
        "Margin mode needs the hyprzoom plugin",
        f"Margin is selected, but Hyprland is using {label}{note} because the plugin "
        "is not loaded.",
        needs_plugin=True,
    )
