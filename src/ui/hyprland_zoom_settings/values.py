"""Validate and format setting values the way the schema (contract C1) defines them.

``zoomctl set`` stays the authoritative validator; this module only keeps obviously invalid
input from spawning a process and gives the widgets one place for formatting rules.
"""

# math rejects NaN/infinity, re checks key names, dataclasses carry the verdict.
import math
import re
from dataclasses import dataclass
from typing import Dict, List, Optional

# Kind constants decide which check a setting gets.
from .schema import (
    KIND_BOOL,
    KIND_ENUM,
    KIND_FLOAT,
    KIND_INT,
    KIND_KEY,
    SettingSpec,
)

# Canonical on/off texts and the accepted input aliases (contract C1).
BOOL_ON = "on"
BOOL_OFF = "off"
_TRUE_ALIASES = {"on", "1", "true", "yes"}
_FALSE_ALIASES = {"off", "0", "false", "no"}
# Modifier names in zoomctl's canonical order (validate.sh), with the aliases that map onto
# them; one order everywhere keeps a saved value identical to what zoomctl would write.
MODIFIER_ORDER = ("SUPER", "CTRL", "ALT", "SHIFT")
_MODIFIER_ALIASES = {
    "SUPER": "SUPER", "WIN": "SUPER", "META": "SUPER", "MOD4": "SUPER",
    "CTRL": "CTRL", "CONTROL": "CTRL",
    "ALT": "ALT", "MOD1": "ALT",
    "SHIFT": "SHIFT",
}
MODS_SEPARATOR = " + "
# A Hyprland key name is a keysym name: letters, digits and underscores only.
_KEY_NAME = re.compile(r"^[A-Za-z0-9_]{1,32}$")


@dataclass(frozen=True)
class ValueCheck:
    """Verdict of a validation.

    Attributes:
        ok: True when the input is acceptable.
        canonical: Canonical text form (empty when not ok).
        error: Human-readable reason (empty when ok).
    """

    ok: bool
    canonical: str = ""
    error: str = ""


def format_float(number: float, digits: int = 2) -> str:
    """Format a float in the canonical stored form.

    Args:
        number: Value to format.
        digits: Decimal places (the schema uses two).

    Returns:
        For example ``1.50``.
    """
    # Normalising negative zero avoids a stored "-0.00".
    text = f"{number:.{digits}f}"
    return text[1:] if text.startswith("-") and float(text) == 0 else text


def parse_bool(text: str) -> Optional[bool]:
    """Interpret a boolean text including the CLI aliases.

    Args:
        text: ``on/off/1/0/true/false/yes/no`` in any case.

    Returns:
        True or False, or None when the text is not a boolean.
    """
    # Aliases are matched case-insensitively after trimming.
    word = text.strip().lower()
    if word in _TRUE_ALIASES:
        return True
    return False if word in _FALSE_ALIASES else None


def bool_text(flag: bool) -> str:
    """Render a boolean in canonical form.

    Args:
        flag: Value to render.

    Returns:
        ``on`` or ``off``.
    """
    # The canonical form is what zoomctl stores.
    return BOOL_ON if flag else BOOL_OFF


def parse_modifiers(text: str) -> Optional[List[str]]:
    """Split a modifier list into canonical names.

    Args:
        text: Modifiers joined with ``+`` (spaces optional), e.g. ``SUPER + ALT``.

    Returns:
        Distinct canonical names in canonical order, or None when a name is unknown.
    """
    names = set()
    for token in text.split("+"):
        # Empty tokens (from a blank text) are ignored; unknown names make the list invalid.
        word = token.strip().upper()
        if not word:
            continue
        if word not in _MODIFIER_ALIASES:
            # A name outside the four known modifiers makes the whole list invalid.
            return None
        names.add(_MODIFIER_ALIASES[word])
    return [name for name in MODIFIER_ORDER if name in names]


def modifiers_text(names: List[str]) -> str:
    """Join modifier names into the stored form.

    Args:
        names: Canonical modifier names.

    Returns:
        For example ``SUPER + ALT``.
    """
    # Canonical order keeps the stored text stable no matter which toggle was set first.
    ordered = [name for name in MODIFIER_ORDER if name in names]
    return MODS_SEPARATOR.join(ordered)


def _check_number(spec: SettingSpec, text: str) -> ValueCheck:
    """Validate a float or int against the spec's range.

    Args:
        spec: Numeric setting.
        text: Candidate value.

    Returns:
        The verdict with the canonical text.
    """
    try:
        number = float(text.strip())
    except ValueError:
        return ValueCheck(False, error=f"'{text}' is not a number")
    # NaN and infinity pass float() but are never valid settings.
    if not math.isfinite(number):
        return ValueCheck(False, error=f"'{text}' is not a finite number")
    is_int = spec.kind == KIND_INT
    if is_int and number != int(number):
        # Ints must not be silently truncated.
        return ValueCheck(False, error=f"{spec.label} must be a whole number")
    # Floats are stored with two decimals, so the range applies to the rounded value.
    number = float(int(number)) if is_int else round(number, 2)
    # Numeric specs always carry bounds; the defaults only satisfy the type checker.
    low = spec.minimum if spec.minimum is not None else -math.inf
    high = spec.maximum if spec.maximum is not None else math.inf
    if not low <= number <= high:
        low_text, high_text = format_float(low), format_float(high)
        # The message names the schema range.
        return ValueCheck(False, error=f"{spec.label} must be between {low_text} and {high_text}")
    return ValueCheck(True, str(int(number)) if is_int else format_float(number))


def _check_bool(text: str) -> ValueCheck:
    """Validate a boolean.

    Args:
        text: Candidate value.

    Returns:
        The verdict with ``on``/``off`` as canonical text.
    """
    # parse_bool knows all CLI aliases.
    flag = parse_bool(text)
    if flag is None:
        return ValueCheck(False, error=f"'{text}' is not on or off")
    return ValueCheck(True, bool_text(flag))


def _check_enum(spec: SettingSpec, text: str) -> ValueCheck:
    """Validate an enum value.

    Args:
        spec: Enum setting.
        text: Candidate value.

    Returns:
        The verdict with the lowercase choice as canonical text.
    """
    # Enum choices are lowercase in the schema.
    lowered = text.lower()
    if lowered not in spec.choices:
        return ValueCheck(False, error=f"{spec.label} must be one of: {', '.join(spec.choices)}")
    return ValueCheck(True, lowered)


def _check_key(text: str) -> ValueCheck:
    """Validate a Hyprland key name (empty disables the bind).

    Args:
        text: Candidate value.

    Returns:
        The verdict with the upper-case key name as canonical text.
    """
    # An empty key is legal: it switches the bind off.
    if text and not _KEY_NAME.match(text):
        return ValueCheck(False, error=f"'{text}' is not a valid key name")
    return ValueCheck(True, text.upper())


def _check_modifiers(text: str) -> ValueCheck:
    """Validate a modifier list; at least one modifier is required.

    Args:
        text: Candidate value.

    Returns:
        The verdict with ``SUPER + ALT`` style canonical text.
    """
    # Bare keys without a modifier would hijack normal typing, so they are refused.
    names = parse_modifiers(text)
    if not names:
        return ValueCheck(False, error="Choose at least one of SUPER, CTRL, ALT, SHIFT")
    return ValueCheck(True, modifiers_text(names))


def check_value(spec: SettingSpec, text: str) -> ValueCheck:
    """Validate a candidate value for a setting.

    Args:
        spec: The setting.
        text: Candidate value as text.

    Returns:
        The verdict; ``canonical`` is the text to hand to ``zoomctl set``.
    """
    # Numbers have their own range logic; the other kinds are small text checks.
    word = text.strip()
    if spec.kind in (KIND_FLOAT, KIND_INT):
        return _check_number(spec, word)
    if spec.kind == KIND_BOOL:
        # Each kind has its own small checker.
        return _check_bool(word)
    if spec.kind == KIND_ENUM:
        return _check_enum(spec, word)
    # The schema parser admits no other kinds than key and mods here.
    return _check_key(word) if spec.kind == KIND_KEY else _check_modifiers(word)


def float_digits(spec: SettingSpec) -> int:
    """Decimal places a widget should show for a setting.

    Args:
        spec: The setting.

    Returns:
        0 for integers, 2 for floats (the canonical stored precision).
    """
    # Matches the canonical form so the widget never shows more precision than is stored.
    return 0 if spec.kind == KIND_INT else 2


# Settings of the cross-field rule MIN <= RESET <= MAX (contract C1), lowest first.
ZOOM_ORDER_KEYS = ("ZOOM_MIN", "ZOOM_RESET", "ZOOM_MAX")


def check_zoom_order(
    labels: Dict[str, str], values: Dict[str, str], key: str, canonical: str
) -> str:
    """Check the rule ``ZOOM_MIN <= ZOOM_RESET <= ZOOM_MAX`` for a pending change.

    Args:
        labels: Human label per schema key (for the message).
        values: Current effective configuration.
        key: Setting being changed.
        canonical: Its new canonical value.

    Returns:
        An empty string when the rule holds (or the change is unrelated), otherwise a
        sentence naming both settings by their labels.
    """
    # Only the three zoom limits take part in the rule.
    if key not in ZOOM_ORDER_KEYS:
        return ""
    candidate = {**values, key: canonical}
    try:
        low, middle, high = (float(candidate[name]) for name in ZOOM_ORDER_KEYS)
    except (KeyError, ValueError):
        # Unreadable neighbours cannot be judged here; zoomctl stays the authority.
        return ""
    pairs = ((ZOOM_ORDER_KEYS[0], low, ZOOM_ORDER_KEYS[1], middle),
             (ZOOM_ORDER_KEYS[1], middle, ZOOM_ORDER_KEYS[2], high))
    for lower_key, lower, upper_key, upper in pairs:
        # The first violated pair is reported with its current values.
        if lower > upper:
            return (f"{labels[lower_key]} ({format_float(lower)}) can't be above "
                    f"{labels[upper_key]} ({format_float(upper)})")
    return ""
