"""Presentation-only tables: page titles/icons, option labels, explanations, units and phrases.

Keys, types, defaults and ranges come from the schema (contract E3); this module only decides
how a page, an enum option or a number is *worded* and which enum settings are drawn as
choice lists. Anything not listed here falls back to a generated label, so a new schema
entry still works. All user-visible text is US English (contract E13).
"""

# dataclasses keep the tables typed; typing documents the tuple shapes.
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class GroupInfo:
    """How one schema GROUP appears as a page.

    Attributes:
        group: Group id from the schema.
        title: Page title.
        icon: Symbolic icon name from the standard icon theme.
        description: One-sentence summary (tooltip and accessible description of the page).
    """

    group: str
    title: str
    icon: str
    # Shown as tooltip of the sidebar entry; may be empty for unknown groups.
    description: str


@dataclass(frozen=True)
class DisplayUnit:
    """How a numeric setting is shown when its stored unit is not the one people think in.

    Attributes:
        suffix: Unit text appended to the row title, for example ``ms``.
        factor: Displayed number = stored number * factor (and the reverse when saving).
        digits: Decimal places shown, or None to use the schema precision.
        step: Spin step in displayed units, or None for the default step.
    """

    suffix: str
    factor: float = 1.0
    digits: Optional[int] = None
    step: Optional[float] = None


# Page order in the window; ids the schema adds later are appended after these.
GROUPS: Tuple[GroupInfo, ...] = (
    GroupInfo("zoom", "Zoom", "zoom-in-symbolic",
              "How far and how fast the screen magnifies."),
    GroupInfo("tracking", "Pointer tracking", "input-mouse-symbolic",
              "How the zoomed view follows the mouse pointer."),
    GroupInfo("filter", "Color filters", "applications-graphics-symbolic",
              "Invert, darken or tint the screen for comfort and contrast."),
    GroupInfo("shortcuts", "Shortcuts", "input-keyboard-symbolic",
              "Keys and mouse actions that control the zoom."),
    GroupInfo("advanced", "Advanced", "preferences-other-symbolic",
              "Behavior that rarely needs changing."),
)

# Enum settings drawn as a list of explained choices instead of a drop-down.
CHOICE_LIST_KEYS = frozenset(
    {"ZOOM_TRACKING", "FILTER", "ZOOM_STEP_MODE", "BIND_SCROLL_DIRECTION"}
)

# The short question above a choice list (never the page title, never the schema help).
CHOICE_QUESTIONS: Dict[str, str] = {
    "ZOOM_TRACKING": "How should the view follow the pointer?",
    "FILTER": "Which color filter should be used?",
    "ZOOM_STEP_MODE": "How should one zoom step work?",
    "BIND_SCROLL_DIRECTION": "Which scroll direction zooms in?",
}

# Short label and one-sentence explanation of every known enum option, per setting key.
OPTION_TEXT: Dict[str, Dict[str, Tuple[str, str]]] = {
    "ZOOM_TRACKING": {
        "centered": ("Centered", "The pointer stays in the middle of the zoomed view."),
        "edge": ("Edge", "The view moves when the pointer reaches the edge of the screen."),
        "margin": (
            "Margin",
            "Like edge, with an adjustable protective margin around the view.",
        ),
        "follow": ("Follow", "The view slides proportionally with the pointer."),
    },
    "ZOOM_STEP_MODE": {
        "multiply": ("Multiply", "Even steps at every zoom level (recommended)."),
        "add": ("Add", "Always the same fixed amount per step."),
    },
    "BIND_SCROLL_DIRECTION": {
        "down-in": ("Scroll down zooms in", "Scrolling towards you zooms in, as in version 0.1."),
        "up-in": ("Scroll up zooms in", "Scrolling away from you zooms in."),
    },
    "FILTER": {
        "invert": ("Invert", "Swaps light and dark; colors become their opposites."),
        "smart-invert": (
            "Smart invert",
            "Dark mode for bright screens; colors stay recognizable.",
        ),
        "grayscale": ("Grayscale", "Removes all color."),
        "grayscale-invert": ("Inverted grayscale", "Grayscale with light and dark swapped."),
        "high-contrast": ("High contrast", "Pushes light and dark apart for readability."),
        "protanopia": ("Protanopia", "Color transform for red-weak color vision."),
        "deuteranopia": ("Deuteranopia", "Color transform for green-weak color vision."),
        "tritanopia": ("Tritanopia", "Color transform for blue-weak color vision."),
    },
}

# Status-line wording of the effective tracking mode.
TRACKING_PHRASES: Dict[str, str] = {
    "centered": "Pointer centered",
    "edge": "View moves at the edge",
    "margin": "View moves at a margin",
    "follow": "View follows the pointer",
}

# What Hyprland does by itself when a mode cannot be used (for the plugin notice).
FALLBACK_NOTES: Dict[str, str] = {"edge": " with a fixed 5 % margin"}

# Settings whose stored unit differs from the unit shown to people.
DISPLAY_UNITS: Dict[str, DisplayUnit] = {
    # Stored in tenths of a second; people think in milliseconds.
    "ZOOM_ANIMATION_SPEED": DisplayUnit("ms", factor=100.0, digits=0, step=10.0),
    "SCROLL_EVENT_DELAY_MS": DisplayUnit("ms"),
}


def ordered_groups(schema_group_ids: List[str]) -> List[GroupInfo]:
    """Order the pages: known groups in presentation order, unknown ones afterwards.

    Args:
        schema_group_ids: Group ids in order of first appearance in the schema.

    Returns:
        GroupInfo per group id the schema uses (unknown ids get a generated title).
    """
    known = {info.group: info for info in GROUPS}
    ordered = [known[group] for group in known if group in schema_group_ids]
    # A group the schema introduced after this app was written still gets a page.
    for group in schema_group_ids:
        if group not in known:
            ordered.append(GroupInfo(group, humanize(group), "preferences-other-symbolic", ""))
    return ordered


def humanize(identifier: str) -> str:
    """Turn an identifier into a readable label.

    Args:
        identifier: For example ``smart-invert``.

    Returns:
        For example ``Smart invert``.
    """
    # Dashes and underscores separate words in schema identifiers.
    words = identifier.replace("-", " ").replace("_", " ").strip()
    return words[:1].upper() + words[1:]


def option_label(key: str, option: str) -> str:
    """Label of an enum option.

    Args:
        key: Schema key of the enum setting.
        option: Option value.

    Returns:
        The hand-written label, or a generated one for unknown options.
    """
    # Unknown options (new schema entries) degrade to a generated label.
    text = OPTION_TEXT.get(key, {}).get(option)
    return text[0] if text else humanize(option)


def option_description(key: str, option: str) -> Optional[str]:
    """Explanation of an enum option.

    Args:
        key: Schema key of the enum setting.
        option: Option value.

    Returns:
        The one-sentence explanation, or None when there is none.
    """
    # Options without a hand-written text simply show no subtitle.
    text = OPTION_TEXT.get(key, {}).get(option)
    return text[1] if text else None


def choice_question(key: str, fallback: str) -> str:
    """Heading of a choice list.

    Args:
        key: Schema key of the enum setting.
        fallback: Text used when no question was written (the schema label).

    Returns:
        The short question, or the fallback.
    """
    # A missing question degrades to the schema label, never to an empty heading.
    return CHOICE_QUESTIONS.get(key, fallback)


def display_unit(key: str) -> Optional[DisplayUnit]:
    """Look up how a numeric setting is displayed.

    Args:
        key: Schema key.

    Returns:
        The unit description, or None when the stored form is shown as it is.
    """
    # Most settings need no conversion.
    return DISPLAY_UNITS.get(key)
