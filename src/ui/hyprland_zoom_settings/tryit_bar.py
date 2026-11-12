"""The "Try it" bar under the settings: live status line plus the timed test buttons."""

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import ZOOM_TEST_FACTOR  # noqa: E402
from .controller import SettingsController  # noqa: E402
from .porcelain import describe_status  # noqa: E402
from .tryit import MODE_FILTER, MODE_IDLE, MODE_ZOOM, TryItController  # noqa: E402


class TryItBar(Gtk.Box):
    """Heading, test buttons and the status line; reacts to both controllers' signals."""

    def __init__(self, settings: SettingsController, session: TryItController) -> None:
        """Build the bar and connect it to the controllers.

        Args:
            settings: Settings controller (status source).
            session: Try-it state machine the buttons drive.

        Returns:
            None.
        """
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.settings = settings
        self.session = session
        for side in ("top", "bottom", "start", "end"):
            getattr(self, f"set_margin_{side}")(12)
        heading = Gtk.Label(label="Try it", xalign=0.0)
        heading.add_css_class("heading")
        self.append(heading)
        self._build_buttons()
        self.status_label = Gtk.Label(xalign=0.0, wrap=True, selectable=True)
        self.status_label.add_css_class("dim-label")
        self.status_label.add_css_class("caption")
        self.append(self.status_label)
        # The bar redraws whenever the session or the status changes.
        session.connect("changed", lambda _session: self.refresh())
        settings.connect("status-changed", lambda _settings: self.refresh())
        self.refresh()

    def _build_buttons(self) -> None:
        """Create the buttons in a wrapping row (they wrap at large text sizes).

        Returns:
            None.
        """
        self.button_box = Adw.WrapBox(child_spacing=8, line_spacing=8)
        self.zoom_button = self._make_button("", self.session.start_zoom_test, "suggested-action")
        self.filter_button = self._make_button("", self.session.start_filter_preview)
        self.stop_button = self._make_button("Stop now", self.session.stop)
        self.keep_button = self._make_button("Keep", self.session.keep, "suggested-action")
        self.revert_button = self._make_button("Revert", self.session.stop)
        self.countdown_label = Gtk.Label(xalign=0.0, wrap=True)
        self.countdown_label.update_property(
            [Gtk.AccessibleProperty.LABEL], ["Try it countdown"]
        )
        for widget in (self.zoom_button, self.filter_button, self.stop_button, self.keep_button,
                       self.revert_button, self.countdown_label):
            self.button_box.append(widget)
        self.append(self.button_box)

    def _make_button(self, label: str, handler, css_class: str = "") -> Gtk.Button:
        """Create one button.

        Args:
            label: Button text.
            handler: Called without arguments on click.
            css_class: Optional style class.

        Returns:
            The button.
        """
        button = Gtk.Button(label=label)
        # The click signal passes the button, which the handlers do not need.
        button.connect("clicked", lambda _button: handler())
        if css_class:
            button.add_css_class(css_class)
        return button

    def refresh(self) -> None:
        """Redraw buttons, countdown and status line from the current state.

        Returns:
            None.
        """
        mode = self.session.mode
        idle = mode == MODE_IDLE
        self.zoom_button.set_label(
            f"Zoom to {ZOOM_TEST_FACTOR:g}× for {self.session.zoom_seconds} s"
        )
        self.filter_button.set_label(f"Preview filter for {self.session.filter_seconds} s")
        # Start buttons only when nothing runs; the matching end buttons only during a test.
        self.zoom_button.set_visible(idle)
        self.filter_button.set_visible(idle)
        self.stop_button.set_visible(mode == MODE_ZOOM)
        self.keep_button.set_visible(mode == MODE_FILTER)
        self.revert_button.set_visible(mode == MODE_FILTER)
        self.countdown_label.set_visible(not idle)
        self.countdown_label.set_label(self._countdown_text(mode))
        self.status_label.set_label(describe_status(self.settings.status))

    def _countdown_text(self, mode: str) -> str:
        """Compose the countdown sentence.

        Args:
            mode: Current session mode.

        Returns:
            Text such as ``Zoomed in – back to normal in 4 s``; empty when idle.
        """
        seconds = self.session.seconds_left
        if mode == MODE_ZOOM:
            return f"Zoomed in – back to normal in {seconds} s"
        if mode == MODE_FILTER:
            return f"Previewing the filter – reverts in {seconds} s unless you keep it"
        return ""
