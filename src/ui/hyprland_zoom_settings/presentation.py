"""Presentation-only tables: page titles/icons, option labels and explanations.

Keys, types, defaults and ranges come from the schema (contract E3); this module only decides
how a page or an enum option is *worded* and which enum settings are drawn as choice lists.
Anything not listed here falls back to a generated label, so a new schema entry still works.
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
        description: One-sentence page introduction.
    """

    group: str
    title: str
    icon: str
    description: str


# Page order in the window; ids the schema adds later are appended after these.
GROUPS: Tuple[GroupInfo, ...] = (
    GroupInfo("zoom", "Zoom", "zoom-in-symbolic",
              "How far and how fast the screen magnifies."),
    GroupInfo("tracking", "Pointer tracking", "input-mouse-symbolic",
              "How the zoomed view follows the mouse pointer."),
    GroupInfo("filter", "Colour filters", "applications-graphics-symbolic",
              "Invert, darken or tint the screen for comfort and contrast."),
    GroupInfo("shortcuts", "Shortcuts", "input-keyboard-symbolic",
              "Keys and mouse actions that control the zoom."),
    GroupInfo("advanced", "Advanced", "preferences-other-symbolic",
              "Behaviour that rarely needs changing."),
)

# Enum settings drawn as a list of explained choices instead of a drop-down.
CHOICE_LIST_KEYS = frozenset({"ZOOM_TRACKING", "FILTER"})

# Short label and one-sentence explanation of every known enum option, per setting key.
OPTION_TEXT: Dict[str, Dict[str, Tuple[str, str]]] = {
    "ZOOM_TRACKING": {
        "centered": ("Centred", "The pointer stays in the middle of the zoomed view."),
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
    "FILTER": {
        "invert": ("Invert", "Swaps light and dark, colours become their opposites."),
        "smart-invert": (
            "Smart invert",
            "Dark mode for bright screens; colours stay recognisable.",
        ),
        "grayscale": ("Grayscale", "Removes all colour."),
        "grayscale-invert": ("Inverted grayscale", "Grayscale with light and dark swapped."),
        "high-contrast": ("High contrast", "Pushes light and dark apart for readability."),
        "protanopia": ("Protanopia", "Colour transform for red-weak colour vision."),
        "deuteranopia": ("Deuteranopia", "Colour transform for green-weak colour vision."),
        "tritanopia": ("Tritanopia", "Colour transform for blue-weak colour vision."),
    },
}

# Enum option that needs the optional hyprzoom plugin to behave as described.
PLUGIN_ONLY_OPTIONS = {("ZOOM_TRACKING", "margin")}


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
            ordered.append(GroupInfo(group, humanise(group), "preferences-other-symbolic", ""))
    return ordered


def humanise(identifier: str) -> str:
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
    return text[0] if text else humanise(option)


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
