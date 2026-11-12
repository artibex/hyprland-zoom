"""Key capture helpers: map GDK key names to Hyprland key names and build display strings.

Pure Python on purpose: the GTK key controller hands over a keysym *name* (what
``Gdk.keyval_name`` returns), everything after that is testable without a display.
"""

# typing documents the optional results.
from typing import Dict, Optional

from .schema import KIND_KEY, SettingsSchema, SettingSpec
from .values import parse_modifiers

# Keysym names of pure modifier keys; pressing one alone must not complete a capture.
MODIFIER_KEYSYM_NAMES = frozenset({
    "Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Meta_L", "Meta_R",
    "Super_L", "Super_R", "Hyper_L", "Hyper_R", "Caps_Lock", "Num_Lock", "Scroll_Lock",
    "ISO_Level3_Shift", "ISO_Level5_Shift", "Mode_switch",
})
# GDK reports Shift+Tab as this keysym; Hyprland knows the key as TAB.
_KEYSYM_RENAMES = {"ISO_Left_Tab": "TAB"}
# The keysym that cancels a capture (it therefore cannot be bound itself).
CANCEL_KEYSYM_NAME = "Escape"
# Hyprland modifier names mapped to GTK accelerator modifier syntax (display only).
_ACCELERATOR_MODIFIERS = {
    "SUPER": "<Super>", "CTRL": "<Control>", "ALT": "<Alt>", "SHIFT": "<Shift>",
}


def hyprland_key_name(keysym_name: Optional[str]) -> Optional[str]:
    """Convert a GDK keysym name to the key name Hyprland binds understand.

    Args:
        keysym_name: Result of ``Gdk.keyval_name`` (e.g. ``i``, ``Return``, ``F5``).

    Returns:
        Upper-case key name such as ``I``, ``RETURN``, ``F5``; None for modifier keys,
        unknown keys and the cancel key.
    """
    # Unknown keys and lone modifiers cannot be bound.
    if not keysym_name or keysym_name in MODIFIER_KEYSYM_NAMES:
        return None
    if keysym_name == CANCEL_KEYSYM_NAME:
        return None
    # xkb keysym lookups in Hyprland are case-insensitive, upper case is the canonical style.
    return _KEYSYM_RENAMES.get(keysym_name, keysym_name).upper()


def accelerator_text(modifiers: str, key_name: str) -> str:
    """Build a GTK accelerator string to draw a shortcut with ``Gtk.ShortcutLabel``.

    Args:
        modifiers: Stored modifier text, e.g. ``SUPER + ALT``.
        key_name: Hyprland key name; empty means the bind is disabled.

    Returns:
        For example ``<Super><Alt>i``; an empty string for a disabled bind.
    """
    # A disabled bind has nothing to draw.
    if not key_name:
        return ""
    names = parse_modifiers(modifiers) or []
    prefix = "".join(_ACCELERATOR_MODIFIERS[name] for name in names)
    # GTK expects keysym names in their GDK spelling; lower case matches letters and digits.
    return f"{prefix}{key_name.lower()}"


def find_key_conflict(
    schema: SettingsSchema, config: Dict[str, str], edited_key: str, key_name: str
) -> Optional[SettingSpec]:
    """Find another shortcut that already uses a key.

    Args:
        schema: The settings schema (provides the key-typed settings).
        config: Effective configuration, key -> text.
        edited_key: Schema key being changed (it never conflicts with itself).
        key_name: Candidate Hyprland key name.

    Returns:
        The conflicting setting, or None. An empty candidate never conflicts.
    """
    # Disabling a bind cannot collide with anything.
    if not key_name:
        return None
    for spec in schema.specs:
        # Only other key-typed settings compete for the same modifiers + key chord.
        if spec.kind != KIND_KEY or spec.key == edited_key:
            continue
        if config.get(spec.key, spec.default).upper() == key_name.upper():
            return spec
    return None
