"""Setting rows for plain types, all created by ``build_setting_row``.

One wrapper class per schema type (see ``row_base`` for the shared protocol). Shortcut rows
(modifiers and keys) live in ``shortcut_rows``. Every row is built with markup switched off
because titles and help texts come from the schema and may contain ``&`` or ``<``.
"""

# typing documents the mappings and optionals.
from typing import Dict, Optional

import gi

gi.require_version("Gtk", "4.0")
# Both toolkits are pinned before any import from gi.repository.
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import CHOICE_LIST_MAX_OPTIONS, SLIDER_MAX_SPAN  # noqa: E402
from .presentation import (  # noqa: E402
    CHOICE_LIST_KEYS, DisplayUnit, choice_question, display_unit, option_description,
    option_label,
)
from .row_base import (  # noqa: E402
    DebouncedRow, RowContext, SettingRow, StackedRow, label_accessibly, make_plain_group,
    make_plain_row,
)
from .schema import (  # noqa: E402
    KIND_BOOL, KIND_ENUM, KIND_FLOAT, KIND_INT, KIND_KEY, KIND_MODS, SettingSpec,
)
from .shortcut_rows import KeySettingRow, ModifiersSettingRow  # noqa: E402
from .values import bool_text, float_digits, format_float, parse_bool  # noqa: E402

# Schema key of the switch that mirrors the live filter state instead of the saved config.
LIVE_FILTER_KEY = "FILTER_ACTIVE"
# Step of a slider: one hundredth, the precision the schema stores (two decimals).
SLIDER_STEP = 0.01
# Decimal places of a slider's value text (the stored precision).
SLIDER_DIGITS = 2
# A slider's page step is this fraction of its range (PageUp / PageDown).
SLIDER_PAGE_FRACTION = 10


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
        row = make_plain_row(Adw.SwitchRow, spec.label, spec.help)
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


class LiveFilterSwitchRow(SwitchSettingRow):
    """The "filter active" switch: shows the live screen and acts on it and on the config."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: The ``FILTER_ACTIVE`` setting.
            context: Shared window callbacks (status and actions are needed).

        Returns:
            None.
        """
        super().__init__(spec, context)
        # The state the user just asked for, shown until the engine confirms it.
        self._requested: Optional[bool] = None

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Show the filter state of the screen, not the saved default.

        Args:
            text: Saved value (ignored; the screen is the truth).
            values: Unused.

        Returns:
            None.
        """
        # A hotkey toggle never writes the config, so only the live status is current.
        live = self.context.get_status().filter_active
        self.widget.set_active(live if self._requested is None else self._requested)

    def _on_toggled(self, _row, _pspec) -> None:
        """Save the choice, then switch the live filter to match.

        Args:
            _row: The row (unused).
            _pspec: Property spec (unused).

        Returns:
            None.
        """
        if self._updating:
            return
        wanted = self.widget.get_active()
        self._requested = wanted
        # The saved default first (it reloads the engine), then the live switch.
        self.emit_change(bool_text(wanted), lambda saved: self._switch_live(wanted, saved))

    def _switch_live(self, wanted: bool, saved: bool) -> None:
        """Turn the filter on or off on the screen after the setting was saved.

        Args:
            wanted: The requested state.
            saved: Whether zoomctl accepted the saved setting.

        Returns:
            None.
        """
        # A rejected save means the user's request is void: show the live state again.
        if not saved:
            self._settle()
            return
        self.context.run_action(["filter", bool_text(wanted)], lambda _result: self._settle())

    def _settle(self) -> None:
        """Drop the pending request and show the live state again.

        Returns:
            None.
        """
        self._requested = None
        # Without this a failed command would leave the switch lying until the next change.
        self.apply_values(self.context.get_values())


class ScaleSettingRow(DebouncedRow):
    """A float setting with a short range as a slider with a visible value."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row with a slider below the texts.

        Args:
            spec: Float setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        low, high = spec.minimum or 0.0, spec.maximum or 0.0
        # Range comes from the schema; step and precision are the stored two decimals.
        adjustment = Gtk.Adjustment(
            lower=low, upper=high, step_increment=SLIDER_STEP,
            page_increment=round((high - low) / SLIDER_PAGE_FRACTION, 2),
        )
        self.scale = Gtk.Scale(
            orientation=Gtk.Orientation.HORIZONTAL, adjustment=adjustment, digits=SLIDER_DIGITS,
            draw_value=True, value_pos=Gtk.PositionType.RIGHT, hexpand=True,
        )
        stacked = StackedRow(spec.label, spec.help, self.scale)
        super().__init__(spec, context, stacked.widget)
        self.subtitle_label = stacked.subtitle_label
        label_accessibly(self.scale, spec.label, spec.help)
        # Dragging fires value-changed continuously; the debouncer sends one change.
        self.scale.connect("value-changed", self.on_widget_edited)

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
        """Build the row; the unit (if any) is part of the title.

        Args:
            spec: Int or wide float setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        unit = display_unit(spec.key) or DisplayUnit("")
        self._factor = unit.factor
        digits = float_digits(spec) if unit.digits is None else unit.digits
        step = unit.step or (1.0 if digits == 0 else 0.1)
        adjustment = Gtk.Adjustment(
            lower=(spec.minimum or 0.0) * self._factor,
            upper=(spec.maximum or 0.0) * self._factor,
            step_increment=step, page_increment=step * 10,
        )
        # The unit sits in the title so every value is read in the unit it is meant in.
        title = f"{spec.label} ({unit.suffix})" if unit.suffix else spec.label
        row = make_plain_row(Adw.SpinRow, title, spec.help, adjustment=adjustment, digits=digits)
        super().__init__(spec, context, row)
        # Typing a number and the spin buttons both end in notify::value.
        row.connect("notify::value", self.on_widget_edited)

    def show_value(self, text: str, values: Dict[str, str]) -> None:
        """Show the number in the displayed unit.

        Args:
            text: Stored number text.
            values: Unused.

        Returns:
            None.
        """
        try:
            self.widget.set_value(float(text) * self._factor)
        except ValueError:
            self.widget.set_value(float(self.spec.default) * self._factor)

    def send_current_value(self) -> None:
        """Send the spin value converted back to the stored unit.

        Returns:
            None.
        """
        number = self.widget.get_value() / self._factor
        self.emit_change(str(int(number)) if self.spec.kind == KIND_INT else format_float(number))


class ComboSettingRow(SettingRow):
    """An enum setting without written option texts as a drop-down with generated labels."""

    def __init__(self, spec: SettingSpec, context: RowContext) -> None:
        """Build the row.

        Args:
            spec: Enum setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        labels = [option_label(spec.key, option) for option in spec.choices]
        # No subtitle: the schema help of an enum may list raw option ids.
        row = make_plain_row(Adw.ComboRow, spec.label, model=Gtk.StringList.new(labels))
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
        """Build one radio row per option under a short question.

        Args:
            spec: Enum setting.
            context: Shared window callbacks.

        Returns:
            None.
        """
        # The question replaces the schema help, which would repeat every option's text.
        question = choice_question(spec.key, spec.label)
        group = make_plain_group(question)
        super().__init__(spec, context, group)
        label_accessibly(group, question, spec.help)
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
        row = make_plain_row(Adw.ActionRow, title, description)
        # The radio button leads the row; clicking the row selects it.
        row.add_prefix(button)
        row.set_activatable_widget(button)
        label_accessibly(button, title, description)
        # The option travels as an extra argument to the handler.
        button.connect("toggled", self._on_toggled, option)
        return row

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


def build_setting_row(spec: SettingSpec, context: RowContext) -> SettingRow:
    """Create the wrapper for a setting from its schema type.

    Args:
        spec: The setting.
        context: Shared window callbacks.

    Returns:
        The matching SettingRow; ``row.widget`` is what a page adds.
    """
    if spec.kind == KIND_BOOL:
        # One switch mirrors the screen instead of the saved value (see LiveFilterSwitchRow).
        row_class = LiveFilterSwitchRow if spec.key == LIVE_FILTER_KEY else SwitchSettingRow
        return row_class(spec, context)
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
