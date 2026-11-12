"""Shared building blocks of the setting rows: context, debouncing, base classes, stacked rows.

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

from .constants import DEBOUNCE_MILLISECONDS  # noqa: E402
from .porcelain import EngineStatus  # noqa: E402
from .schema import SettingsSchema, SettingSpec  # noqa: E402

# Called with True when a change was applied, False when it was rejected.
DoneCallback = Callable[[bool], None]


@dataclass
class RowContext:
    """What every row needs from the surrounding window.

    Attributes:
        schema: The settings schema (for conflict checks).
        get_values: Returns the current effective configuration.
        on_change: Called with ``(key, canonical text, optional done callback)`` when the
            user changed a setting.
        report_error: Called with a message the window shows as a toast.
        get_status: Returns the current engine status (live state of the screen).
        run_action: Runs a zoomctl command ``(arguments, optional result callback)``.
    """

    schema: SettingsSchema
    get_values: Callable[[], Dict[str, str]]
    on_change: Callable[..., object]
    # Rows report refusals here instead of showing toasts themselves.
    report_error: Callable[[str], None]
    get_status: Callable[[], EngineStatus]
    run_action: Callable[..., None]


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


def make_plain_row(row_class, title: str, subtitle: Optional[str] = None, **properties):
    """Create a libadwaita row whose texts are never read as markup.

    Markup has to be switched off *before* the texts are set: a row built with all
    properties at once parses them as markup first and logs a warning for ``&`` or ``<``.

    Args:
        row_class: ``Adw.ActionRow``, ``Adw.SwitchRow``, ``Adw.SpinRow``, ...
        title: Row title (plain text).
        subtitle: Row subtitle (plain text), or None for none.
        properties: Further constructor properties (adjustment, model, ...).

    Returns:
        The row.
    """
    row = row_class(**properties)
    row.set_use_markup(False)
    row.set_title(title)
    # Rows without a subtitle keep libadwaita's default (empty) one.
    if subtitle is not None:
        row.set_subtitle(subtitle)
    return row


def make_plain_group(title: str) -> Adw.PreferencesGroup:
    """Create a preferences group with a literal title.

    Args:
        title: Group title (plain text).

    Returns:
        The group; the title is escaped because groups always read it as markup.
    """
    # Groups have no use-markup switch, so the text is escaped instead.
    return Adw.PreferencesGroup(title=GLib.markup_escape_text(title))


class StackedRow:
    """A list row with its title and help text above a full-width control.

    Wide controls (sliders, key capture buttons, toggles) do not fit beside a wrapping title
    at large text sizes or narrow windows; stacking them below the text always fits.
    """

    def __init__(self, title: str, subtitle: str, control: Gtk.Widget) -> None:
        """Build the row.

        Args:
            title: Row title (plain text, never markup).
            subtitle: Help text under the title (plain text).
            control: Widget shown below the texts.

        Returns:
            None.
        """
        # The row is a plain preferences row so it sits in a group like every other row.
        self.widget = Adw.PreferencesRow(title=title, use_markup=False, activatable=False)
        self.title_label = Gtk.Label(label=title, xalign=0.0, wrap=True)
        self.title_label.add_css_class("heading")
        self.subtitle_label = Gtk.Label(label=subtitle, xalign=0.0, wrap=True)
        # The subtitle looks like the one of an action row: smaller and dimmed.
        self.subtitle_label.add_css_class("dim-label")
        self.subtitle_label.add_css_class("caption")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for part in (self.title_label, self.subtitle_label, control):
            box.append(part)
        # Margins match the padding of an action row.
        for side in ("top", "bottom", "start", "end"):
            getattr(box, f"set_margin_{side}")(12)
        self.widget.set_child(box)
        # The row is announced as a whole: name first, then the help text.
        label_accessibly(self.widget, title, subtitle)


class SettingRow:
    """Base of all setting wrappers; subclasses build the widget and call this constructor."""

    def __init__(self, spec: SettingSpec, context: RowContext, widget: Gtk.Widget) -> None:
        """Store the spec and the widget.

        Args:
            spec: The setting shown by this row.
            context: Shared window callbacks.
            widget: The libadwaita row or group this object drives.

        Returns:
            None.
        """
        self.spec = spec
        self.context = context
        self.widget = widget
        self._updating = False
        # Set by rows that draw their own subtitle label (see StackedRow).
        self.subtitle_label: Optional[Gtk.Label] = None

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

    def emit_change(self, text: str, on_done: Optional[DoneCallback] = None) -> None:
        """Report a user edit.

        Args:
            text: New value as text.
            on_done: Optional callback with the outcome (applied or rejected).

        Returns:
            None.
        """
        # Programmatic updates are not user edits.
        if self._updating:
            return
        if on_done is None:
            self.context.on_change(self.spec.key, text)
        else:
            self.context.on_change(self.spec.key, text, on_done)

    def set_visible(self, visible: bool) -> None:
        """Show or hide the row.

        Args:
            visible: Whether the widget is shown.

        Returns:
            None.
        """
        self.widget.set_visible(visible)

    def set_reason(self, reason: Optional[str]) -> None:
        """Lock the row and say why, or unlock it.

        Args:
            reason: Explanation shown instead of the help text, or None to unlock.

        Returns:
            None.
        """
        # The reason replaces the help text so the user sees it exactly where it matters.
        self.widget.set_sensitive(reason is None)
        text = self.spec.help if reason is None else reason
        if self.subtitle_label is not None:
            self.subtitle_label.set_label(text)
        elif hasattr(self.widget, "set_subtitle"):
            self.widget.set_subtitle(text)

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
