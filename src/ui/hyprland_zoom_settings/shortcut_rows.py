"""Shortcut rows: the modifier toggles and the key rows with their capture dialog.

Both rows stack their controls below the text so they keep fitting at large text sizes; the
controls wrap onto further lines when the window is narrow.
"""

# typing documents the mappings and lists.
from typing import Dict, List

import gi

gi.require_version("Gtk", "4.0")
# Both toolkits are pinned before any import from gi.repository.
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from .key_capture import KeyCaptureDialog  # noqa: E402
from .keys import MODIFIER_CAP_NAMES, chord_parts, find_key_conflict  # noqa: E402
from .row_base import (  # noqa: E402
    RowContext, SettingRow, StackedRow, children_of, label_accessibly,
)
from .schema import SettingSpec  # noqa: E402
from .values import MODIFIER_ORDER, modifiers_text, parse_modifiers  # noqa: E402

# Style class of one drawn key (defined in styles.py, drawn from theme colours).
KEYCAP_CSS_CLASS = "hzoom-keycap"
# Gap between neighbouring controls, horizontally and between wrapped lines (pixels).
CONTROL_SPACING = 8


def wrapping_controls() -> Adw.WrapBox:
    """Create a box whose children flow onto the next line when the width runs out.

    Returns:
        An empty wrapping box.
    """
    # Start alignment keeps the controls under the title instead of floating to the middle.
    return Adw.WrapBox(child_spacing=CONTROL_SPACING, line_spacing=CONTROL_SPACING,
                       halign=Gtk.Align.START)


class ModifiersSettingRow(SettingRow):
    """The modifier setting as four toggle buttons."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the toggle buttons.

        Args:
            spec: Mods setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        box = wrapping_controls()
        stacked = StackedRow(spec.label, spec.help, box)
        # The toggles are stacked below the text of the row.
        super().__init__(spec, context, stacked.widget)
        self.subtitle_label = stacked.subtitle_label
        self.toggles: Dict[str, Gtk.ToggleButton] = {}
        for name in MODIFIER_ORDER:
            # One toggle per modifier, labelled with its keyboard name.
            toggle = Gtk.ToggleButton(label=MODIFIER_CAP_NAMES[name])
            label_accessibly(toggle, f"{MODIFIER_CAP_NAMES[name]} key", spec.help)
            toggle.connect("toggled", self._on_toggled)
            # Toggles are kept by modifier name for show_value and tests.
            self.toggles[name] = toggle
            box.append(toggle)

    def selected_names(self) -> List[str]:
        """List the modifiers that are switched on.

        Returns:
            Canonical modifier names in canonical order.
        """
        return [name for name in MODIFIER_ORDER if self.toggles[name].get_active()]

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Set the toggles from the stored text.

        Args:
            text: Modifier text such as ``SUPER + ALT``.
            values: Unused.

        Returns:
            None.
        """
        names = parse_modifiers(text) or []
        for name, toggle in self.toggles.items():
            toggle.set_active(name in names)

    def _on_toggled(self, _toggle) -> None:
        """Report the new modifier set; refuse an empty one.

        Args:
            _toggle: The toggled button (unused).

        Returns:
            None.
        """
        if self._updating:
            return
        names = self.selected_names()
        if not names:
            # Without any modifier the zoom keys would swallow plain typing.
            self.context.report_error("Keep at least one modifier key")
            self.apply_values(self.context.get_values())
            return
        self.emit_change(modifiers_text(names))


class KeySettingRow(SettingRow):
    """A key setting: the shortcut drawn as keycaps, a Change button and a Disable button."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: Key setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        controls = wrapping_controls()
        stacked = StackedRow(spec.label, spec.help, controls)
        # Keycaps, buttons and the disabled marker flow below the title.
        super().__init__(spec, context, stacked.widget)
        self.subtitle_label = stacked.subtitle_label
        self.keycaps = Gtk.Box(spacing=4, valign=Gtk.Align.CENTER)
        # Shown instead of the keycaps while the shortcut is disabled.
        self.disabled_label = Gtk.Label(label="Disabled", valign=Gtk.Align.CENTER)
        self.disabled_label.add_css_class("dim-label")
        self.change_button = Gtk.Button(label="Change…", valign=Gtk.Align.CENTER)
        # The button name says which shortcut it changes.
        label_accessibly(self.change_button, f"Change {spec.label}", spec.help)
        self.change_button.connect("clicked", self._on_change_clicked)
        self.disable_button = Gtk.Button(
            icon_name="edit-clear-symbolic", tooltip_text="Disable this shortcut",
            valign=Gtk.Align.CENTER,
        )
        # An icon-only button needs an explicit accessible name.
        label_accessibly(self.disable_button, f"Disable {spec.label}", "Removes the shortcut")
        self.disable_button.add_css_class("flat")
        self.disable_button.connect("clicked", lambda _button: self.emit_change(""))
        # The append order is the visual order from left to right.
        for part in (self.keycaps, self.disabled_label, self.change_button,
                     self.disable_button):
            controls.append(part)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Draw the shortcut (modifiers + key) or the disabled marker.

        Args:
            text: Key name; empty means disabled.
            values: Effective configuration (supplies the modifiers).

        Returns:
            None.
        """
        parts = chord_parts(values.get("BIND_MODIFIERS", ""), text)
        self._redraw_keycaps(parts)
        # A disabled bind shows a word instead of an empty strip of keys.
        self.keycaps.set_visible(bool(parts))
        self.disabled_label.set_visible(not parts)
        self.disable_button.set_sensitive(bool(text))

    def _redraw_keycaps(self, parts: List[str]) -> None:
        """Replace the drawn keys.

        Args:
            parts: Texts of the keycaps, modifiers first.

        Returns:
            None.
        """
        # Old caps are removed before the new ones are appended.
        for old_cap in children_of(self.keycaps):
            self.keycaps.remove(old_cap)
        for part in parts:
            cap = Gtk.Label(label=part)
            # The style class draws the label like a keyboard key.
            cap.add_css_class(KEYCAP_CSS_CLASS)
            self.keycaps.append(cap)
        label_accessibly(self.keycaps, " + ".join(parts) or "Disabled", self.spec.help)

    def keycap_texts(self) -> List[str]:
        """Read back the drawn keys (used by tests and assistive checks).

        Returns:
            The texts of the current keycaps.
        """
        return [cap.get_label() for cap in children_of(self.keycaps)]

    def _on_change_clicked(self, _button) -> None:
        """Open the key capture dialog.

        Args:
            _button: The Change button (unused).

        Returns:
            None.
        """
        KeyCaptureDialog(self.spec.label, self.accept_key).present(self.widget)

    def accept_key(self, key_name: str) -> bool:
        """Apply a captured key unless another shortcut already uses it.

        Args:
            key_name: Hyprland key name from the capture dialog.

        Returns:
            True when the key was accepted (the dialog may close), False when refused.
        """
        conflict = find_key_conflict(
            self.context.schema, self.context.get_values(), self.spec.key, key_name
        )
        if conflict is not None:
            self.context.report_error(f"{key_name} is already used by “{conflict.label}”")
            # False keeps the dialog open so the user can try another key.
            return False
        self.emit_change(key_name)
        return True
