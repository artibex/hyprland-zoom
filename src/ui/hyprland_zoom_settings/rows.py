"""Setting rows: one wrapper class per schema type, all created by ``build_setting_row``.

libadwaita's row types cannot be subclassed from Python (several are final), so every
``SettingRow`` *wraps* its widget in ``.widget``. The shared protocol: ``apply_values(values)``
shows the effective value *without* emitting a change, user edits go to ``context.on_change``
(sliders debounced), ``flush()`` sends a pending debounced edit at once and ``is_editing()``
tells the page not to overwrite a value the user is still adjusting.
"""

# dataclasses carry the shared context; typing documents the callables and mappings.
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

import gi

gi.require_version("Gtk", "4.0")
# Both toolkits are pinned before any import from gi.repository.
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import CHOICE_LIST_MAX_OPTIONS, DEBOUNCE_MILLISECONDS, SLIDER_MAX_SPAN  # noqa: E402
from .key_capture import KeyCaptureDialog  # noqa: E402
from .keys import MODIFIER_CAP_NAMES, chord_parts, find_key_conflict  # noqa: E402
from .presentation import CHOICE_LIST_KEYS, option_description, option_label  # noqa: E402
from .schema import (  # noqa: E402
    KIND_BOOL, KIND_ENUM, KIND_FLOAT, KIND_INT, KIND_KEY, KIND_MODS, SettingsSchema, SettingSpec,
)
from .values import (  # noqa: E402
    MODIFIER_ORDER, bool_text, float_digits, format_float, modifiers_text, parse_bool,
    parse_modifiers,
)

# Style class of one drawn key (defined in styles.py, drawn from theme colours).
KEYCAP_CSS_CLASS = "hzoom-keycap"


@dataclass
class RowContext:
    """What every row needs from the surrounding window.

    Attributes:
        schema: The settings schema (for conflict checks).
        get_values: Returns the current effective configuration.
        on_change: Called with ``(key, canonical text)`` when the user changed a setting.
        report_error: Called with a message the window shows as a toast.
    """

    schema: SettingsSchema
    get_values: Callable[[], Dict[str, str]]
    on_change: Callable[[str, str], object]
    # Rows report refusals here instead of showing toasts themselves.
    report_error: Callable[[str], None]


class Debouncer:
    """Runs an action once after a quiet period; used so a slider drag sends one change."""

    def __init__(self, action: Callable[[], None], delay_milliseconds: int) -> None:
        """Remember the action.

        Args:
            action: Callable to run after the quiet period.
            delay_milliseconds: Length of the quiet period.

        Returns:
            None.
        """
        self._action = action
        self._delay = delay_milliseconds
        self._timer_id = 0

    @property
    def pending(self) -> bool:
        """Tell whether an action is waiting.

        Returns:
            True between ``schedule`` and the action running.
        """
        # A non-zero id is a live GLib timer.
        return self._timer_id != 0

    def schedule(self) -> None:
        """(Re)start the quiet period.

        Returns:
            None.
        """
        # Every new event pushes the deadline back.
        self.cancel()
        self._timer_id = GLib.timeout_add(self._delay, self._fire)

    def cancel(self) -> None:
        """Drop a waiting action.

        Returns:
            None.
        """
        if self._timer_id:
            GLib.source_remove(self._timer_id)
            self._timer_id = 0

    def flush(self) -> None:
        """Run a waiting action immediately (window closing).

        Returns:
            None.
        """
        # Without this the last slider move before closing the window would be lost.
        if self._timer_id:
            self.cancel()
            self._action()

    def _fire(self) -> bool:
        """Timer callback: run the action once.

        Returns:
            False so the timer is removed.
        """
        # Clear the id first so ``pending`` is already False inside the action.
        self._timer_id = 0
        self._action()
        return GLib.SOURCE_REMOVE


def children_of(widget: Gtk.Widget) -> List[Gtk.Widget]:
    """List the direct children of a widget.

    Args:
        widget: Container to inspect.

    Returns:
        The children in display order.
    """
    children = []
    child = widget.get_first_child()
    # GTK4 has no generic child iterator; siblings are walked one by one.
    while child is not None:
        children.append(child)
        child = child.get_next_sibling()
    return children


def label_accessibly(widget: Gtk.Widget, label: str, description: str) -> None:
    """Give a widget an explicit accessible name and description.

    Args:
        widget: Widget to label.
        label: Accessible name.
        description: Accessible description.

    Returns:
        None.
    """
    # Screen readers announce the label first, then the description.
    widget.update_property(
        [Gtk.AccessibleProperty.LABEL, Gtk.AccessibleProperty.DESCRIPTION], [label, description]
    )


class SettingRow:
    """Base of all setting wrappers; subclasses build the widget and call this constructor."""

    def __init__(self, spec: SettingSpec, context: RowContext, widget: Gtk.Widget) -> None:
        """Store the spec and the widget; give the widget its tooltip.

        Args:
            spec: The setting shown by this row.
            context: Shared window callbacks.
            widget: The libadwaita row or group this object drives.

        Returns:
            None.
        """
        # The tooltip repeats the help text for pointer users and assistive tools.
        self.spec = spec
        self.context = context
        self.widget = widget
        self._updating = False
        # Pointer users and assistive tools get the same help text.
        widget.set_tooltip_text(spec.help)

    def apply_values(self, values: Dict[str, str]) -> None:
        """Show the effective value without emitting a change.

        Args:
            values: Effective configuration, key -> text.

        Returns:
            None.
        """
        # A value the user is still adjusting must not be overwritten under their hand.
        if self.is_editing():
            return
        self._updating = True
        try:
            # The subclass paints the value; the guard flag silences its signals.
            self.show_value(values.get(self.spec.key, self.spec.default), values)
        finally:
            self._updating = False

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Display a value in the widget (implemented by each row type).

        Args:
            text: Value of this row's key.
            values: The whole effective configuration.

        Returns:
            None.
        """
        raise NotImplementedError

    def emit_change(self, text: str) -> None:
        """Report a user edit.

        Args:
            text: New value as text.

        Returns:
            None.
        """
        # Programmatic updates are not user edits.
        if not self._updating:
            self.context.on_change(self.spec.key, text)

    def set_visible(self, visible: bool) -> None:
        """Show or hide the row.

        Args:
            visible: Whether the widget is shown.

        Returns:
            None.
        """
        self.widget.set_visible(visible)

    def is_editing(self) -> bool:
        """Tell whether the user is in the middle of an edit.

        Returns:
            True while a debounced edit is pending (never for plain rows).
        """
        return False

    def flush(self) -> None:
        """Send a pending edit immediately (nothing is pending for plain rows).

        Returns:
            None.
        """
        return None


class DebouncedRow(SettingRow):
    """Base of rows whose edits arrive in bursts (slider drags, typing in a spin box)."""

    def __init__(self, spec: SettingSpec, context: RowContext, widget: Gtk.Widget) -> None:
        """Create the debouncer next to the widget.

        Args:
            spec: The setting.
            context: Shared window callbacks.
            widget: The row widget.

        Returns:
            None.
        """
        super().__init__(spec, context, widget)
        self._debouncer = Debouncer(self.send_current_value, DEBOUNCE_MILLISECONDS)

    def on_widget_edited(self, *_args) -> None:
        """Schedule a debounced change after a user edit (connected to the widget signal).

        Args:
            _args: Signal arguments (unused).

        Returns:
            None.
        """
        if not self._updating:
            self._debouncer.schedule()

    def send_current_value(self) -> None:
        """Send the widget's current value (implemented by each row type).

        Returns:
            None.
        """
        raise NotImplementedError

    def is_editing(self) -> bool:
        """Tell whether an edit has not been sent yet.

        Returns:
            True while the debouncer waits.
        """
        return self._debouncer.pending

    def flush(self) -> None:
        """Send an unsent edit now.

        Returns:
            None.
        """
        self._debouncer.flush()


class SwitchSettingRow(SettingRow):
    """A bool setting as a switch row."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: Bool setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        row = Adw.SwitchRow(title=spec.label, subtitle=spec.help)
        super().__init__(spec, context, row)
        row.connect("notify::active", self._on_toggled)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Show on/off.

        Args:
            text: ``on`` or ``off``.
            values: Unused.

        Returns:
            None.
        """
        # Unparsable text shows as off rather than raising inside a signal handler.
        self.widget.set_active(bool(parse_bool(text)))

    def _on_toggled(self, _row, _pspec) -> None:
        """Report the new state.

        Args:
            _row: The row (unused).
            _pspec: Property spec (unused).

        Returns:
            None.
        """
        self.emit_change(bool_text(self.widget.get_active()))


class ScaleSettingRow(DebouncedRow):
    """A float setting with a short range as a slider with a visible value."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row with a slider.

        Args:
            spec: Float setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        row = Adw.ActionRow(title=spec.label, subtitle=spec.help)
        super().__init__(spec, context, row)
        low, high = spec.minimum or 0.0, spec.maximum or 0.0
        # Range and step come from the schema, never from literals here.
        adjustment = Gtk.Adjustment(
            lower=low, upper=high, step_increment=0.01, page_increment=round((high - low) / 10, 2)
        )
        self.scale = Gtk.Scale(
            orientation=Gtk.Orientation.HORIZONTAL, adjustment=adjustment, digits=2,
            draw_value=True, value_pos=Gtk.PositionType.LEFT, valign=Gtk.Align.CENTER,
            width_request=260,
        )
        label_accessibly(self.scale, spec.label, spec.help)
        # Dragging fires value-changed continuously; the debouncer sends one change.
        self.scale.connect("value-changed", self.on_widget_edited)
        row.add_suffix(self.scale)
        row.set_activatable_widget(self.scale)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Move the slider.

        Args:
            text: Float text.
            values: Unused.

        Returns:
            None.
        """
        # A bad value from the CLI falls back to the schema default instead of crashing.
        try:
            self.scale.set_value(float(text))
        except ValueError:
            self.scale.set_value(float(self.spec.default))

    def send_current_value(self) -> None:
        """Send the slider's value.

        Returns:
            None.
        """
        self.emit_change(format_float(self.scale.get_value()))


class SpinSettingRow(DebouncedRow):
    """An int setting, or a float with a wide range, as a spin row."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: Int or wide float setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        digits = float_digits(spec)
        step = 1.0 if digits == 0 else 0.1
        adjustment = Gtk.Adjustment(
            lower=spec.minimum or 0.0, upper=spec.maximum or 0.0,
            step_increment=step, page_increment=step * 10,
        )
        # The digits value gives whole numbers for ints and two decimals otherwise.
        row = Adw.SpinRow(title=spec.label, subtitle=spec.help, adjustment=adjustment,
                          digits=digits)
        super().__init__(spec, context, row)
        # Typing a number and the spin buttons both end in notify::value.
        row.connect("notify::value", self.on_widget_edited)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Show the number.

        Args:
            text: Number text.
            values: Unused.

        Returns:
            None.
        """
        try:
            self.widget.set_value(float(text))
        except ValueError:
            self.widget.set_value(float(self.spec.default))

    def send_current_value(self) -> None:
        """Send the spin value.

        Returns:
            None.
        """
        number = self.widget.get_value()
        self.emit_change(str(int(number)) if self.spec.kind == KIND_INT else format_float(number))


class ComboSettingRow(SettingRow):
    """An enum setting as a drop-down with human labels."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: Enum setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        labels = [option_label(spec.key, option) for option in spec.choices]
        row = Adw.ComboRow(title=spec.label, subtitle=spec.help, model=Gtk.StringList.new(labels))
        super().__init__(spec, context, row)
        # Selection changes are user edits unless the guard flag is set.
        row.connect("notify::selected", self._on_selected)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Select the option.

        Args:
            text: Option value.
            values: Unused.

        Returns:
            None.
        """
        # An unknown option leaves the current selection untouched.
        if text in self.spec.choices:
            self.widget.set_selected(self.spec.choices.index(text))

    def _on_selected(self, _row, _pspec) -> None:
        """Report the chosen option.

        Args:
            _row: The row (unused).
            _pspec: Property spec (unused).

        Returns:
            None.
        """
        self.emit_change(self.spec.choices[self.widget.get_selected()])


class ChoiceListRow(SettingRow):
    """An enum setting as a group of radio rows, each with a one-sentence explanation."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build one radio row per option.

        Args:
            spec: Enum setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        group = Adw.PreferencesGroup(title=spec.label, description=spec.help)
        super().__init__(spec, context, group)
        self.option_rows: Dict[str, Adw.ActionRow] = {}
        # Public so tests and the page can reach the radio buttons by option.
        self.buttons: Dict[str, Gtk.CheckButton] = {}
        first_button: Optional[Gtk.CheckButton] = None
        for option in spec.choices:
            button = Gtk.CheckButton(valign=Gtk.Align.CENTER)
            # Check buttons with the same group behave as radio buttons.
            if first_button is None:
                first_button = button
            else:
                button.set_group(first_button)
            row = self._build_option_row(option, button)
            # Rows are kept by option so subtitles can be replaced later.
            self.option_rows[option] = row
            self.buttons[option] = button
            group.add(row)

    def _build_option_row(self, option: str, button: Gtk.CheckButton) -> Adw.ActionRow:
        """Create the row of one option.

        Args:
            option: Option value.
            button: Its radio button.

        Returns:
            The row, wired to report a selection.
        """
        title = option_label(self.spec.key, option)
        description = option_description(self.spec.key, option) or ""
        row = Adw.ActionRow(title=title, subtitle=description)
        # The radio button leads the row; clicking the row selects it.
        row.add_prefix(button)
        row.set_activatable_widget(button)
        label_accessibly(button, title, description)
        # The option travels as an extra argument to the handler.
        button.connect("toggled", self._on_toggled, option)
        return row

    def set_option_subtitle(self, option: str, text: str) -> None:
        """Replace an option's explanation (used to warn about a missing plugin).

        Args:
            option: Option value.
            text: New subtitle.

        Returns:
            None.
        """
        self.option_rows[option].set_subtitle(text)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Select the option's radio button.

        Args:
            text: Option value.
            values: Unused.

        Returns:
            None.
        """
        if text in self.buttons:
            self.buttons[text].set_active(True)

    def _on_toggled(self, button: Gtk.CheckButton, option: str) -> None:
        """Report the newly selected option.

        Args:
            button: The toggled radio button.
            option: Its option value.

        Returns:
            None.
        """
        # Radio groups also signal the button that was deselected; only the new one counts.
        if button.get_active():
            self.emit_change(option)


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
        row = Adw.ActionRow(title=spec.label, subtitle=spec.help)
        super().__init__(spec, context, row)
        box = Gtk.Box(spacing=0, valign=Gtk.Align.CENTER)
        # Linked styling draws the four toggles as one segmented control.
        box.add_css_class("linked")
        self.toggles: Dict[str, Gtk.ToggleButton] = {}
        for name in MODIFIER_ORDER:
            # One toggle per modifier, labelled with its keyboard name.
            toggle = Gtk.ToggleButton(label=MODIFIER_CAP_NAMES[name])
            label_accessibly(toggle, f"{MODIFIER_CAP_NAMES[name]} key", spec.help)
            toggle.connect("toggled", self._on_toggled)
            # Toggles are kept by modifier name for show_value and tests.
            self.toggles[name] = toggle
            box.append(toggle)
        row.add_suffix(box)

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
        row = Adw.ActionRow(title=spec.label, subtitle=spec.help)
        super().__init__(spec, context, row)
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
        # The suffix order is the visual order from left to right.
        for part in (self.keycaps, self.disabled_label, self.change_button,
                     self.disable_button):
            row.add_suffix(part)

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


def build_setting_row(spec: SettingSpec, context: RowContext) -> SettingRow:
    """Create the wrapper for a setting from its schema type.

    Args:
        spec: The setting.
        context: Shared window callbacks.

    Returns:
        The matching SettingRow; ``row.widget`` is what a page adds.
    """
    if spec.kind == KIND_BOOL:
        return SwitchSettingRow(spec, context)
    if spec.kind == KIND_ENUM:
        # Only enums with explanations and a manageable size become radio lists.
        use_list = spec.key in CHOICE_LIST_KEYS and len(spec.choices) <= CHOICE_LIST_MAX_OPTIONS
        return ChoiceListRow(spec, context) if use_list else ComboSettingRow(spec, context)
    if spec.kind == KIND_MODS:
        # Modifiers and keys have their own rows because they need capture.
        return ModifiersSettingRow(spec, context)
    if spec.kind == KIND_KEY:
        return KeySettingRow(spec, context)
    # Floats with a short range get a slider; whole numbers and wide floats a spin box.
    span = (spec.maximum or 0.0) - (spec.minimum or 0.0)
    if spec.kind == KIND_FLOAT and span <= SLIDER_MAX_SPAN:
        return ScaleSettingRow(spec, context)
    return SpinSettingRow(spec, context)
