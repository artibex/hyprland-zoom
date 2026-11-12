"""The main window: header, engine banner, one page per schema group and the Try-it bar."""

# typing documents the page list.
from typing import List

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402 - gi.require_version must run first

from . import dialogs  # noqa: E402
from .constants import APP_NAME, STATUS_REFRESH_SECONDS  # noqa: E402
from .controller import SettingsController  # noqa: E402
from .pages import SettingsPage, build_pages  # noqa: E402
from .porcelain import ENGINE_UNREACHABLE  # noqa: E402
from .rows import RowContext  # noqa: E402
from .schema import SettingsSchema  # noqa: E402
from .tryit import TryItController  # noqa: E402
from .tryit_bar import TryItBar  # noqa: E402

# Below this width the page switcher moves from the header to a bar at the bottom.
NARROW_WIDTH_CONDITION = "max-width: 640sp"
TOAST_SECONDS = 4


class SettingsWindow(Adw.ApplicationWindow):
    """Main window; owns the pages and wires the controllers' signals to the widgets."""

    def __init__(
        self,
        application: Adw.Application,
        schema: SettingsSchema,
        controller: SettingsController,
        session: TryItController,
        status_refresh_seconds: int = STATUS_REFRESH_SECONDS,
    ) -> None:
        """Build the window and start the first refresh.

        Args:
            application: Owning application.
            schema: Parsed settings schema.
            controller: Settings controller.
            session: Try-it state machine.
            status_refresh_seconds: Period of the live status refresh while visible.

        Returns:
            None.
        """
        super().__init__(application=application, title=APP_NAME, default_width=900,
                         default_height=780)
        self.controller = controller
        self.session = session
        # Configurable so tests need not wait a full second.
        self.status_refresh_seconds = status_refresh_seconds
        self._status_timer_id = 0
        self.pages: List[SettingsPage] = []
        # The layout needs the schema, the rest only needs the controllers.
        self._build_layout(schema)
        self._add_actions()
        self._connect_signals()
        # The first answers fill the pages and the status line.
        controller.refresh_config()
        controller.refresh_status()

    # ----- construction -------------------------------------------------------------------

    def _build_layout(self, schema: SettingsSchema) -> None:
        """Create header, banner, stack, bottom bars and the narrow-width breakpoint.

        Args:
            schema: Parsed settings schema.

        Returns:
            None.
        """
        # Lambdas look the targets up at call time, so replacing add_toast (tests) still works.
        context = RowContext(
            schema, lambda: self.controller.values, self.controller.set_value,
            lambda message: self.add_toast(message),
        )
        self.pages = build_pages(schema, context)
        self.stack = Adw.ViewStack(vexpand=True)
        for page in self.pages:
            # Page title and icon come from the presentation table.
            self.stack.add_titled_with_icon(
                page, page.group_id, page.get_title(), page.get_icon_name()
            )
        self.banner = Adw.Banner(revealed=False)
        self.banner.connect("button-clicked", self._on_banner_clicked)
        # The header owns the switcher and the main menu.
        self.header = self._build_header()
        self.switcher_bar = Adw.ViewSwitcherBar(stack=self.stack)
        view = Adw.ToolbarView()
        # Header first, then the banner, so the banner sits below it.
        view.add_top_bar(self.header)
        view.add_top_bar(self.banner)
        view.set_content(self.stack)
        # Kept as an attribute so tests and the window can reach the bar.
        self.tryit_bar = TryItBar(self.controller, self.session)
        view.add_bottom_bar(self.tryit_bar)
        view.add_bottom_bar(self.switcher_bar)
        # Toasts appear over the whole window, above the Try-it bar.
        self.toast_overlay = Adw.ToastOverlay(child=view)
        self.set_content(self.toast_overlay)
        self._add_narrow_breakpoint()

    def _build_header(self) -> Adw.HeaderBar:
        """Create the header bar with the page switcher and the main menu.

        Returns:
            The header bar.
        """
        header = Adw.HeaderBar()
        self.wide_switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header.set_title_widget(self.wide_switcher)
        # A plain menu model keeps the menu declarative.
        menu = Gio.Menu()
        menu.append("Restore defaults…", "win.restore-defaults")
        menu.append(f"About {APP_NAME}", "win.about")
        # primary=True makes F10 open the menu.
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                       primary=True, tooltip_text="Main menu"))
        return header

    def _add_narrow_breakpoint(self) -> None:
        """Move the page switcher to the bottom bar on narrow windows and large text.

        Returns:
            None.
        """
        condition = Adw.BreakpointCondition.parse(NARROW_WIDTH_CONDITION)
        breakpoint_ = Adw.Breakpoint.new(condition)
        breakpoint_.add_setter(self.switcher_bar, "reveal", True)
        # Narrow windows show the plain title; the switcher moves down.
        breakpoint_.add_setter(self.header, "title-widget", Adw.WindowTitle(title=APP_NAME))
        self.add_breakpoint(breakpoint_)

    def _add_actions(self) -> None:
        """Register the window actions used by the menu and the Advanced page.

        Returns:
            None.
        """
        for name, handler in (("restore-defaults", self._on_restore_defaults),
                              ("about", lambda *_args: dialogs.show_about(self))):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", handler)
            # Actions are addressed as win.<name> by the menu and the Advanced page.
            self.add_action(action)

    def _connect_signals(self) -> None:
        """Connect controller signals and the window lifecycle.

        Returns:
            None.
        """
        self.controller.connect("config-changed", lambda _c: self.refresh_pages())
        self.controller.connect("status-changed", self._on_status_changed)
        self.controller.connect("error", lambda _c, message: self.add_toast(message))
        # The status timer only runs while the window is on screen.
        self.connect("map", lambda _w: self._start_status_timer())
        self.connect("unmap", lambda _w: self._stop_status_timer())
        self.connect("close-request", self._on_close_request)

    # ----- reacting -----------------------------------------------------------------------

    def add_toast(self, message: str) -> None:
        """Show a short message.

        Args:
            message: Plain text (markup is not interpreted).

        Returns:
            None.
        """
        self.toast_overlay.add_toast(Adw.Toast(title=message, timeout=TOAST_SECONDS,
                                               use_markup=False))

    def refresh_pages(self) -> None:
        """Show the effective values and status on every page.

        Returns:
            None.
        """
        for page in self.pages:
            page.apply_values(self.controller.values, self.controller.status)

    def _on_status_changed(self, _controller) -> None:
        """Update the banner and the pages' status-dependent parts.

        Args:
            _controller: The controller (unused).

        Returns:
            None.
        """
        self._update_banner()
        self.refresh_pages()

    def _update_banner(self) -> None:
        """Show the banner for a missing engine or an unreachable zoomctl.

        Returns:
            None.
        """
        status = self.controller.status
        if not self.controller.status_received:
            return
        if status.engine_missing:
            self.banner.set_title("The zoom engine is not set up in your Hyprland configuration.")
            self.banner.set_button_label("Set up")
        elif status.engine == ENGINE_UNREACHABLE:
            reason = self.controller.status_problem or "no answer"
            message = f"zoomctl is not available ({reason}). Changes cannot be applied."
            self.banner.set_title(message)
            # Nothing the app could run would fix this, so no action button.
            self.banner.set_button_label(None)
        self.banner.set_revealed(status.engine_missing or status.engine == ENGINE_UNREACHABLE)

    def _on_banner_clicked(self, _banner) -> None:
        """Run ``zoomctl setup`` from the banner button.

        Args:
            _banner: The banner (unused).

        Returns:
            None.
        """
        self.controller.run_setup(self._on_setup_done)

    def _on_setup_done(self, succeeded: bool) -> None:
        """Tell the user how the setup ended.

        Args:
            succeeded: Whether ``zoomctl setup`` exited with 0.

        Returns:
            None.
        """
        # Failures were already reported by the controller's error signal.
        if succeeded:
            self.add_toast("Engine set up. Reload Hyprland if the status does not change.")

    def _on_restore_defaults(self, _action, _parameter) -> None:
        """Ask for confirmation, then run ``zoomctl reset-config``.

        Args:
            _action: The Gio action (unused).
            _parameter: Action parameter (unused).

        Returns:
            None.
        """
        dialogs.confirm(
            self, "Restore default settings?",
            "All your changes are removed and every setting returns to its default.",
            "Restore defaults", lambda: self.controller.reset_config(self._on_reset_done),
        )

    def _on_reset_done(self, succeeded: bool) -> None:
        """Confirm a finished reset.

        Args:
            succeeded: Whether ``reset-config`` exited with 0.

        Returns:
            None.
        """
        if succeeded:
            self.add_toast("Default settings restored")

    # ----- lifecycle ----------------------------------------------------------------------

    def _start_status_timer(self) -> None:
        """Refresh the status every second while the window is visible.

        Returns:
            None.
        """
        if not self._status_timer_id:
            self._status_timer_id = GLib.timeout_add_seconds(
                self.status_refresh_seconds, self._on_status_tick
            )

    def _stop_status_timer(self) -> None:
        """Stop the periodic refresh (window hidden).

        Returns:
            None.
        """
        if self._status_timer_id:
            GLib.source_remove(self._status_timer_id)
            self._status_timer_id = 0

    def _on_status_tick(self) -> bool:
        """Ask the controller for a fresh status.

        Returns:
            True to keep the timer running.
        """
        self.controller.refresh_status()
        return GLib.SOURCE_CONTINUE

    def _on_close_request(self, _window) -> bool:
        """Flush pending edits and end any running test before the window goes away.

        Args:
            _window: The window (unused).

        Returns:
            False so the window closes.
        """
        # Last slider moves are sent and a zoom/filter test cannot outlive the window.
        for page in self.pages:
            page.flush()
        self.session.shutdown()
        self._stop_status_timer()
        # Returning False lets the window close.
        return False
