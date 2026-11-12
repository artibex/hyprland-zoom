"""The main window: page list beside the page content, engine banner and the Try-it bar.

The page list and the page content form an ``Adw.NavigationSplitView``: side by side while
there is room, one after the other (list first) when the window is narrow or the text is
large. The Try-it bar and the banner span the whole window in both layouts.
"""

# typing documents the page list.
from typing import List

import gi

# Toolkit versions are pinned before the first import from gi.repository.
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402 - gi.require_version must run first

from . import dialogs  # noqa: E402
from .constants import (  # noqa: E402
    APP_NAME, COLLAPSE_CONDITION, CONFIG_POLL_TICKS, STATUS_REFRESH_SECONDS,
)
from .controller import SettingsController  # noqa: E402
from .layout import monitor_size, text_scale  # noqa: E402
from .messages import friendly_notice  # noqa: E402
from .navigation import PageList  # noqa: E402
from .pages import SettingsPage, build_pages  # noqa: E402
from .porcelain import (  # noqa: E402
    STATE_COMPATIBILITY, STATE_NEEDS_SETUP, STATE_NO_HYPRLAND, STATE_NO_ZOOMCTL, STATE_READY,
)
from .row_base import RowContext  # noqa: E402
from .schema import SettingsSchema  # noqa: E402
from .sizing import default_window_size  # noqa: E402
from .tryit import TryItController  # noqa: E402
from .tryit_bar import TryItBar  # noqa: E402

# How long a toast stays; one with details stays longer so the button can be reached.
TOAST_SECONDS = 4
TOAST_WITH_DETAILS_SECONDS = 10
# Banner wording per engine state (the setup case has two variants, see _update_banner).
BANNER_NEEDS_SETUP = "The zoom engine is not set up in your Hyprland configuration."
BANNER_SETUP_DONE = "Set up. Reload Hyprland to finish."
BANNER_NO_HYPRLAND = "Hyprland is not reachable. Start this app from inside your Hyprland session."


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
        # The default size follows the text scale, so large text starts in a roomy window.
        width, height = default_window_size(text_scale(), monitor_size(Gdk.Display.get_default()))
        super().__init__(application=application, title=APP_NAME, default_width=width,
                         default_height=height)
        self.controller = controller
        self.session = session
        # Configurable so tests need not wait a full second.
        self.status_refresh_seconds = status_refresh_seconds
        self._status_timer_id = 0
        self._ticks = 0
        # Set after a successful setup, until Hyprland was reloaded.
        self._setup_done = False
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
        """Create the pages, the split view, the banner and the Try-it bar.

        Args:
            schema: Parsed settings schema.

        Returns:
            None.
        """
        # Lambdas look the targets up at call time, so replacing add_toast (tests) still works.
        context = RowContext(
            schema, lambda: self.controller.values, self.controller.set_value,
            lambda message: self.add_toast(message), lambda: self.controller.status,
            self.controller.run_action,
        )
        self.pages = build_pages(schema, context)
        self.stack = Adw.ViewStack(vexpand=True)
        for page in self.pages:
            # Page title and icon come from the presentation table.
            self.stack.add_titled_with_icon(
                page, page.group_id, page.get_title(), page.get_icon_name()
            )
        self.banner = Adw.Banner(revealed=False, use_markup=False)
        self.banner.connect("button-clicked", self._on_banner_clicked)
        # The Try-it bar spans the window width below both panes.
        self.tryit_bar = TryItBar(self.controller, self.session)
        outer = Adw.ToolbarView()
        # The banner sits above both panes, the Try-it bar below them.
        outer.add_top_bar(self.banner)
        outer.set_content(self._build_split_view())
        outer.add_bottom_bar(self.tryit_bar)
        # Toasts appear over the whole window, above the Try-it bar.
        self.toast_overlay = Adw.ToastOverlay(child=outer)
        self.set_content(self.toast_overlay)
        self._add_collapse_breakpoint()

    def _build_split_view(self) -> Adw.NavigationSplitView:
        """Create the page list and the page content as two navigation pages.

        Returns:
            The split view.
        """
        self.page_list = PageList(self.pages, self._on_page_selected, self._on_page_opened)
        sidebar_view = Adw.ToolbarView()
        # The sidebar lists the pages; its header carries the main menu.
        sidebar_view.add_top_bar(self._build_sidebar_header())
        sidebar_view.set_content(Gtk.ScrolledWindow(child=self.page_list, vexpand=True))
        self.sidebar_page = Adw.NavigationPage(title=APP_NAME, child=sidebar_view, tag="pages")
        # The content pane shows the selected page under its own header.
        self.content_header = Adw.HeaderBar()
        content_view = Adw.ToolbarView()
        content_view.add_top_bar(self.content_header)
        # Both panes are navigation pages of one split view.
        content_view.set_content(self.stack)
        self.content_page = Adw.NavigationPage(title=self.pages[0].get_title(),
                                               child=content_view, tag="content")
        self.split_view = Adw.NavigationSplitView(
            sidebar=self.sidebar_page, content=self.content_page,
        )
        # The first page is shown from the start.
        self.page_list.select_group(self.pages[0].group_id)
        return self.split_view

    def _build_sidebar_header(self) -> Adw.HeaderBar:
        """Create the sidebar header with the main menu.

        Returns:
            The header bar.
        """
        header = Adw.HeaderBar()
        # A plain menu model keeps the menu declarative.
        menu = Gio.Menu()
        menu.append("Restore defaults…", "win.restore-defaults")
        menu.append(f"About {APP_NAME}", "win.about")
        # primary=True makes F10 open the menu.
        header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu,
                                       primary=True, tooltip_text="Main menu"))
        return header

    def _add_collapse_breakpoint(self) -> None:
        """Switch to the one-pane layout (and the compact Try-it bar) on narrow windows.

        Returns:
            None.
        """
        condition = Adw.BreakpointCondition.parse(COLLAPSE_CONDITION)
        breakpoint_ = Adw.Breakpoint.new(condition)
        # The condition is measured in text-scaled units, so large text collapses sooner.
        breakpoint_.add_setter(self.split_view, "collapsed", True)
        breakpoint_.add_setter(self.tryit_bar, "compact", True)
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
        self.controller.connect("error", lambda _c, message, details: self._notify(
            message, details))
        # Notes of successful calls (offline engine) are shown the same way.
        self.controller.connect("info", lambda _c, message, details: self._notify(
            message, details))
        # The status timer only runs while the window is on screen.
        self.connect("map", lambda _w: self._start_status_timer())
        self.connect("unmap", lambda _w: self._stop_status_timer())
        # Coming back to the window re-reads the configuration changed elsewhere.
        self.connect("notify::is-active", self._on_active_changed)
        self.connect("close-request", self._on_close_request)

    # ----- reacting -----------------------------------------------------------------------

    def _notify(self, message: str, details: str) -> None:
        """Show a controller message, with a Details button when there is more to say.

        Args:
            message: Plain sentence.
            details: Technical text, possibly empty.

        Returns:
            None.
        """
        # Without details the plain one-argument form is used.
        if details:
            self.add_toast(message, details)
        else:
            self.add_toast(message)

    def add_toast(self, message: str, details: str = "") -> None:
        """Show a short message.

        Args:
            message: Plain text (markup is not interpreted).
            details: Optional technical text behind a "Details" button.

        Returns:
            None.
        """
        timeout = TOAST_WITH_DETAILS_SECONDS if details else TOAST_SECONDS
        toast = Adw.Toast(title=message, timeout=timeout, use_markup=False)
        if details:
            toast.set_button_label("Details")
            # The raw text appears only when asked for, in a dialog that can be copied from.
            toast.connect("button-clicked",
                          lambda _toast: dialogs.show_details(self, message, details))
        self.toast_overlay.add_toast(toast)

    def refresh_pages(self) -> None:
        """Show the effective values and status on every page.

        Returns:
            None.
        """
        for page in self.pages:
            page.apply_values(self.controller.values, self.controller.status)

    def _on_page_selected(self, group_id: str) -> None:
        """Show the page chosen in the list.

        Args:
            group_id: Group id of the page.

        Returns:
            None.
        """
        self.stack.set_visible_child_name(group_id)
        page = self.stack.get_child_by_name(group_id)
        # The content header names the page, which matters once the list is hidden.
        self.content_page.set_title(page.get_title())

    def _on_page_opened(self, group_id: str) -> None:
        """Move from the list to the page (matters in the one-pane layout only).

        Args:
            group_id: Group id of the page.

        Returns:
            None.
        """
        self._on_page_selected(group_id)
        self.split_view.set_show_content(True)

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
        """Show the banner that matches the engine state, or hide it.

        Returns:
            None.
        """
        if not self.controller.status_received:
            return
        # The state decides which banner (if any) is shown.
        state = self.controller.status.state
        title, button = self._banner_text(state)
        # A state without a banner text means everything works well enough.
        if title:
            self.banner.set_title(title)
            self.banner.set_button_label(button)
        # An empty title hides the banner.
        self.banner.set_revealed(bool(title))
        if state == STATE_READY:
            self._setup_done = False

    def _banner_text(self, state: str):
        """Choose the banner title and button for an engine state.

        Args:
            state: One of the ``STATE_*`` constants.

        Returns:
            ``(title, button label)``; an empty title hides the banner, a None label hides
            the button (nothing the app could run would help).
        """
        # Without zoomctl nothing can be changed or tested.
        if state == STATE_NO_ZOOMCTL:
            reason = friendly_notice(self.controller.status_problem or "no answer").summary
            return f"zoomctl is not available: {reason} Changes cannot be applied.", None
        # A missing compositor cannot be fixed by setting anything up.
        if state == STATE_NO_HYPRLAND:
            return BANNER_NO_HYPRLAND, None
        if state == STATE_NEEDS_SETUP:
            # After a successful setup only a Hyprland reload is missing.
            return (BANNER_SETUP_DONE, None) if self._setup_done else (BANNER_NEEDS_SETUP, "Set up")
        return "", None

    def _on_banner_clicked(self, _banner) -> None:
        """Run ``zoomctl setup`` from the banner button.

        Args:
            _banner: The banner (unused).

        Returns:
            None.
        """
        self.controller.run_setup(self._on_setup_done)

    def _on_setup_done(self, succeeded: bool) -> None:
        """Tell the user how the setup ended and update the banner.

        Args:
            succeeded: Whether ``zoomctl setup`` exited with 0.

        Returns:
            None.
        """
        # Failures were already reported by the controller's error signal.
        if succeeded:
            self._setup_done = True
            self._update_banner()
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

    def _on_active_changed(self, _window, _pspec) -> None:
        """Re-read the configuration when the window gets the focus back.

        Args:
            _window: The window (unused).
            _pspec: Property spec (unused).

        Returns:
            None.
        """
        if self.is_active():
            self.controller.refresh_config()

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
        """Ask the controller for a fresh status, and now and then for the configuration.

        Returns:
            True to keep the timer running.
        """
        self.controller.refresh_status()
        self._ticks += 1
        # Settings changed by `zoomctl set` elsewhere show up within a few seconds.
        if self._ticks % CONFIG_POLL_TICKS == 0:
            self.controller.refresh_config()
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
