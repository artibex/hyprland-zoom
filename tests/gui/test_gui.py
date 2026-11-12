"""Widget and window tests on a private Broadway display with the fake zoomctl.

Nothing here touches the live desktop: GTK is pointed at ``gtk4-broadwayd`` before it is
imported, zoomctl is the fake from ``fixtures/``, and the environment is patched per test.
"""

# unittest is the runner; mock patches dialogs, the environment and geteuid.
import importlib.machinery
import importlib.util
import os
import unittest
# mock replaces dialogs and geteuid without touching the real ones.
from unittest import mock

import support
from support import FakeZoomctlTestCase, pump, pump_for

# The Broadway daemon is shared by all tests of this module.
BROADWAY = support.BroadwayDisplay()
# Test hooks filled by setUpModule once GTK is on the Broadway backend.
GUI = {}


def setUpModule():
    """Start Broadway, then import GTK and the app modules (order matters).

    Returns:
        None.
    """
    BROADWAY.start()
    import gi

    gi.require_version("Gtk", "4.0")
    # Both toolkit versions are pinned before anything is imported from gi.repository.
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gdk, Gio, Gtk

    from hyprland_zoom_settings import app, backend, controller, dialogs, rows, schema, tryit
    # Imported only now: GTK must already sit on the Broadway backend.
    from hyprland_zoom_settings import window as window_module

    Adw.init()
    display = Gdk.Display.get_default()
    # A display that is not Broadway would mean the tests could touch the live desktop.
    if display is None or "Broadway" not in type(display).__name__:
        BROADWAY.stop()
        raise unittest.SkipTest(f"GTK did not open a Broadway display ({display})")
    # NON_UNIQUE never claims the real application id, so a running settings app is safe.
    application = app.ZoomSettingsApplication(
        "test.hyprland_zoom.gui", Gio.ApplicationFlags.NON_UNIQUE
    )
    application.register(None)
    GUI.update(
        Adw=Adw, Gdk=Gdk, Gio=Gio, Gtk=Gtk, app=app, backend=backend, controller=controller,
        dialogs=dialogs, rows=rows, schema=schema, tryit=tryit, window=window_module,
        application=application,
    )


def tearDownModule():
    """Stop the Broadway daemon.

    Returns:
        None.
    """
    BROADWAY.stop()


def iter_widgets(root):
    """Yield a widget and all its descendants, depth first.

    Args:
        root: Starting Gtk.Widget.

    Returns:
        Generator of widgets.
    """
    yield root
    child = root.get_first_child()
    # Siblings are walked iteratively, children recursively.
    while child is not None:
        yield from iter_widgets(child)
        child = child.get_next_sibling()


class GuiTestCase(FakeZoomctlTestCase):
    """Base class: opens windows against the fake zoomctl and records toasts."""

    def open_window(self, refresh_seconds=60, zoom_seconds=2, filter_seconds=2):
        """Create, present and settle a settings window.

        Args:
            refresh_seconds: Period of the live status refresh.
            zoom_seconds: Zoom test length in ticks of 50 ms.
            filter_seconds: Filter preview length in ticks of 50 ms.

        Returns:
            The SettingsWindow with an empty call log and recorded toasts in ``toasts``.
        """
        schema = GUI["schema"].parse_schema(support.read_schema_text())
        controller = GUI["controller"].SettingsController(
            schema, GUI["backend"].ZoomctlClient(os.environ["ZOOMCTL_BIN"])
        )
        session = GUI["tryit"].TryItController(controller, zoom_seconds, filter_seconds, 50)
        # The window gets its own controller, so tests do not share state.
        window = GUI["window"].SettingsWindow(
            GUI["application"], schema, controller, session, refresh_seconds
        )
        # Toasts are recorded instead of shown so tests can assert on their text.
        self.toasts = []
        window.add_toast = self.toasts.append
        window.present()
        pump(lambda: controller.status_received and self.fake.calls_matching("config"))
        # Let the rows settle before the call log is cleared.
        pump_for(0.15)
        self.fake.clear_calls()
        self.addCleanup(self.close_window, window)
        # Tests start from a rendered window and an empty call log.
        return window

    @staticmethod
    def close_window(window):
        """Destroy a window at the end of a test.

        Args:
            window: The window.

        Returns:
            None.
        """
        # Closing runs the real close handler (flush edits, end tests) before destroying.
        window.close()
        window.destroy()
        pump_for(0.05)

    @staticmethod
    def row(window, key):
        """Find the SettingRow of a schema key on any page.

        Args:
            window: The window.
            key: Schema key.

        Returns:
            The SettingRow.
        """
        for page in window.pages:
            if key in page.rows:
                return page.rows[key]
        # A missing row is a test failure with a readable message.
        raise AssertionError(f"no row for {key}")

    def settle(self, seconds=0.3):
        """Let pending asynchronous work finish.

        Args:
            seconds: Time to keep the main loop running.

        Returns:
            None.
        """
        pump_for(seconds)


class StructureTests(GuiTestCase):
    """What the window consists of."""

    def test_display_is_broadway_not_the_live_session(self):
        """The suite must never run against the real desktop."""
        display = GUI["Gdk"].Display.get_default()
        self.assertIn("Broadway", type(display).__name__)
        self.assertEqual(os.environ["GDK_BACKEND"], "broadway")

    def test_five_pages_in_presentation_order(self):
        """Zoom, tracking, filter, shortcuts, advanced."""
        window = self.open_window()
        titles = [page.get_title() for page in window.pages]
        self.assertEqual(
            titles,
            ["Zoom", "Pointer tracking", "Colour filters", "Shortcuts", "Advanced"],
        )

    def test_every_schema_key_has_exactly_one_row(self):
        """Widgets are generated from the whole schema, nothing is forgotten."""
        window = self.open_window()
        schema = GUI["schema"].parse_schema(support.read_schema_text())
        shown = [key for page in window.pages for key in page.rows]
        # Order does not matter, but nothing may be missing or doubled.
        self.assertCountEqual(shown, [spec.key for spec in schema.specs])

    def test_widget_type_follows_the_schema_type(self):
        """float short -> slider, float wide / int -> spin, bool -> switch, enum -> combo/list."""
        window = self.open_window()
        rows, Adw, Gtk = GUI["rows"], GUI["Adw"], GUI["Gtk"]
        self.assertIsInstance(self.row(window, "ZOOM_STEP"), rows.ScaleSettingRow)
        # Other short-range floats are sliders too.
        self.assertIsInstance(self.row(window, "FILTER_INTENSITY"), rows.ScaleSettingRow)
        self.assertIsInstance(self.row(window, "ZOOM_MAX"), rows.SpinSettingRow)
        self.assertIsInstance(self.row(window, "SCROLL_EVENT_DELAY_MS").widget, Adw.SpinRow)
        # Bools are switches, enums with few options are combos.
        self.assertIsInstance(self.row(window, "ZOOM_SMOOTH_IMAGES").widget, Adw.SwitchRow)
        self.assertIsInstance(self.row(window, "ZOOM_STEP_MODE").widget, Adw.ComboRow)
        self.assertIsInstance(self.row(window, "ZOOM_TRACKING"), rows.ChoiceListRow)
        # Filter and tracking are explained choice lists.
        self.assertIsInstance(self.row(window, "FILTER"), rows.ChoiceListRow)
        self.assertIsInstance(self.row(window, "BIND_MODIFIERS"), rows.ModifiersSettingRow)
        self.assertIsInstance(self.row(window, "BIND_KEY_IN"), rows.KeySettingRow)
        # The slider is a real Gtk.Scale.
        self.assertIsInstance(self.row(window, "ZOOM_STEP").scale, Gtk.Scale)

    def test_slider_range_and_digits_come_from_the_schema(self):
        """Range and precision are not hard-coded in the widgets."""
        window = self.open_window()
        scale = self.row(window, "FILTER_BRIGHTNESS").scale
        adjustment = scale.get_adjustment()
        # Brightness is the one setting with a negative minimum.
        self.assertEqual((adjustment.get_lower(), adjustment.get_upper()), (-0.5, 0.5))
        self.assertEqual(scale.get_digits(), 2)

    def test_rows_show_the_effective_values_of_zoomctl(self):
        """Values from ``config --porcelain`` reach the widgets."""
        self.fake.respond(
            "config",
            stdout="ZOOM_STEP=0.25\nZOOM_SMOOTH_IMAGES=off\nZOOM_TRACKING=follow\n"
                   "BIND_KEY_IN=P\nSCROLL_EVENT_DELAY_MS=120\nBIND_MODIFIERS=CTRL + SHIFT\n",
        )
        window = self.open_window()
        self.assertAlmostEqual(self.row(window, "ZOOM_STEP").scale.get_value(), 0.25)
        # The switch shows off, as reported by zoomctl.
        self.assertFalse(self.row(window, "ZOOM_SMOOTH_IMAGES").widget.get_active())
        self.assertTrue(self.row(window, "ZOOM_TRACKING").buttons["follow"].get_active())
        self.assertEqual(self.row(window, "SCROLL_EVENT_DELAY_MS").widget.get_value(), 120)
        # The toggles mirror the modifier text.
        self.assertEqual(self.row(window, "BIND_MODIFIERS").selected_names(), ["CTRL", "SHIFT"])

    def test_every_row_has_a_label_and_a_help_tooltip(self):
        """Accessibility baseline: name and description on every setting."""
        window = self.open_window()
        schema = GUI["schema"].parse_schema(support.read_schema_text())
        for page in window.pages:
            # Every row is checked against its schema entry.
            for key, row in page.rows.items():
                spec = schema.by_key[key]
                self.assertEqual(row.widget.get_tooltip_text(), spec.help, key)
                # The title is the schema label.
                self.assertEqual(row.widget.get_title(), spec.label, key)

    def test_interactive_parts_are_keyboard_focusable(self):
        """Sliders, switches, buttons and radio buttons can take focus."""
        window = self.open_window()
        Gtk = GUI["Gtk"]
        focusable_types = (Gtk.Scale, Gtk.Switch, Gtk.Button, Gtk.CheckButton, Gtk.ToggleButton)
        # Hidden widgets (disabled key rows) are skipped.
        for widget in iter_widgets(window):
            if isinstance(widget, focusable_types) and widget.get_visible():
                self.assertTrue(widget.get_focusable(), type(widget).__name__)

    def test_narrow_window_moves_the_switcher_to_the_bottom(self):
        """At a small width (or large text) the breakpoint reveals the bottom switcher."""
        window = self.open_window()
        self.assertFalse(window.switcher_bar.get_reveal())
        window.set_default_size(420, 700)
        # The breakpoint applies after the next layout pass.
        pump(lambda: window.switcher_bar.get_reveal())

    def test_window_survives_a_large_text_scale(self):
        """A doubled font size still builds and lays out the window."""
        settings = GUI["Gtk"].Settings.get_default()
        original = settings.get_property("gtk-xft-dpi")
        self.addCleanup(settings.set_property, "gtk-xft-dpi", original)
        # 192 dpi doubles the font size, like a large text setting.
        settings.set_property("gtk-xft-dpi", 192 * 1024)
        window = self.open_window()
        pump_for(0.2)
        # The window still shows after the doubled size.
        self.assertTrue(window.is_visible())


class LiveApplyTests(GuiTestCase):
    """Every change becomes ``zoomctl set`` (debounced for sliders)."""

    def test_switch_sends_set_on_off(self):
        """Toggling a switch applies immediately."""
        window = self.open_window()
        self.row(window, "ZOOM_SMOOTH_IMAGES").widget.set_active(False)
        self.wait_for_calls("set")
        # Only the switch change was sent.
        self.assertEqual(
            self.fake.calls_matching("set"), [["set", "ZOOM_SMOOTH_IMAGES", "off"]]
        )

    def test_slider_drag_sends_one_debounced_call_with_the_last_value(self):
        """A drag is one change, not dozens of processes."""
        window = self.open_window()
        scale = self.row(window, "ZOOM_STEP").scale
        for value in (0.2, 0.3, 0.4, 0.5):
            # Four quick moves inside one debounce window.
            scale.set_value(value)
        self.assertEqual(self.fake.calls_matching("set"), [])
        self.wait_for_calls("set")
        # Wait longer than the debounce to prove nothing else follows.
        self.settle(0.5)
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_STEP", "0.50"]])

    def test_spin_row_sends_a_whole_number_for_ints(self):
        """The scroll delay is sent as an integer."""
        window = self.open_window()
        self.row(window, "SCROLL_EVENT_DELAY_MS").widget.set_value(50)
        self.wait_for_calls("set")
        # The integer is sent without decimals.
        self.assertEqual(
            self.fake.calls_matching("set"), [["set", "SCROLL_EVENT_DELAY_MS", "50"]]
        )

    def test_wide_float_spin_row_sends_two_decimals(self):
        """Zoom maximum is a spin row with canonical float text."""
        window = self.open_window()
        self.row(window, "ZOOM_MAX").widget.set_value(6)
        self.wait_for_calls("set")
        # Spin values are sent with two decimals.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_MAX", "6.00"]])

    def test_combo_sends_the_enum_value_not_the_label(self):
        """The drop-down shows labels but sends schema values."""
        window = self.open_window()
        self.row(window, "ZOOM_STEP_MODE").widget.set_selected(1)
        self.wait_for_calls("set")
        # The schema value is sent, not the label.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_STEP_MODE", "add"]])

    def test_choice_list_sends_the_chosen_mode_once(self):
        """Selecting a radio row sends one set; deselecting the old one sends nothing."""
        window = self.open_window()
        self.row(window, "ZOOM_TRACKING").buttons["edge"].set_active(True)
        self.wait_for_calls("set")
        # Give a second (wrong) call time to appear.
        self.settle(0.3)
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_TRACKING", "edge"]])

    def test_programmatic_refresh_never_sends_a_set(self):
        """Showing effective values must not echo them back to zoomctl."""
        self.fake.respond("config", stdout="ZOOM_STEP=0.33\nZOOM_TRACKING=follow\n")
        window = self.open_window()
        window.controller.refresh_config()
        # Longer than the debounce and the refresh round trips.
        self.settle(0.6)
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_modifier_toggles_send_the_canonical_text(self):
        """Switching Alt off leaves SUPER; the order is canonical."""
        window = self.open_window()
        self.row(window, "BIND_MODIFIERS").toggles["ALT"].set_active(False)
        self.wait_for_calls("set")
        # Alt off leaves Super alone.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "BIND_MODIFIERS", "SUPER"]])
        self.row(window, "BIND_MODIFIERS").toggles["CTRL"].set_active(True)
        self.wait_for_calls("set", count=2)
        # Canonical order puts CTRL after SUPER.
        self.assertEqual(self.fake.calls_matching("set")[1][2], "SUPER + CTRL")

    def test_last_modifier_cannot_be_switched_off(self):
        """An empty modifier list would hijack typing: refused with a toast."""
        self.fake.respond("config", stdout="BIND_MODIFIERS=SUPER\n")
        window = self.open_window()
        self.row(window, "BIND_MODIFIERS").toggles["SUPER"].set_active(False)
        # No set may be sent for the refused change.
        self.settle(0.3)
        self.assertEqual(self.fake.calls_matching("set"), [])
        self.assertEqual(self.toasts, ["Keep at least one modifier key"])
        # The toggle jumped back on.
        self.assertTrue(self.row(window, "BIND_MODIFIERS").toggles["SUPER"].get_active())

    def test_rejected_change_toasts_stderr_and_reverts_the_widget(self):
        """zoomctl refusing a value shows its message and restores the old widget state."""
        self.fake.respond("set", stderr="zoomctl: ZOOM_MIN must be <= ZOOM_RESET\n", rc=1)
        window = self.open_window()
        row = self.row(window, "ZOOM_SMOOTH_IMAGES")
        # The user switches the setting off; zoomctl will refuse.
        row.widget.set_active(False)
        self.wait_for_calls("set")
        pump(lambda: self.toasts)
        # The message is zoomctl's own first stderr line.
        self.assertEqual(self.toasts, ["zoomctl: ZOOM_MIN must be <= ZOOM_RESET"])
        pump(lambda: row.widget.get_active())
        self.assertTrue(row.widget.get_active())

    def test_rejected_slider_returns_to_the_effective_value(self):
        """The slider jumps back after a refused change."""
        self.fake.respond("set", stderr="zoomctl: nope\n", rc=1)
        window = self.open_window()
        scale = self.row(window, "ZOOM_STEP").scale
        # A value zoomctl will refuse.
        scale.set_value(1.5)
        self.wait_for_calls("set")
        pump(lambda: abs(scale.get_value() - 0.10) < 0.001)

    def test_closing_the_window_flushes_a_pending_slider_move(self):
        """The last drag before closing must not be lost."""
        window = self.open_window()
        self.row(window, "ZOOM_STEP").scale.set_value(0.77)
        window.close()
        # Wait until the refused call has really been made.
        self.wait_for_calls("set")
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_STEP", "0.77"]])


class TrackingPageTests(GuiTestCase):
    """Margin slider visibility and the plugin hint."""

    def margin_visible(self, window):
        """Tell whether the margin slider is visible.

        Args:
            window: The window.

        Returns:
            True when the margin row is shown.
        """
        return self.row(window, "ZOOM_EDGE_MARGIN").widget.get_visible()

    def test_margin_slider_is_hidden_unless_margin_mode_is_selected(self):
        """Default centred mode hides the slider."""
        window = self.open_window()
        self.assertFalse(self.margin_visible(window))

    def test_margin_slider_appears_for_the_margin_mode(self):
        """The configured margin mode shows the slider."""
        self.fake.respond("config", stdout="ZOOM_TRACKING=margin\n")
        window = self.open_window()
        self.assertTrue(self.margin_visible(window))

    def test_choosing_margin_reveals_the_slider_after_the_change_applied(self):
        """Selecting the mode applies it, then the slider shows up."""
        window = self.open_window()
        self.row(window, "ZOOM_TRACKING").buttons["margin"].set_active(True)
        pump(lambda: self.margin_visible(window))

    def tracking_page(self, window):
        """Get the tracking page.

        Args:
            window: The window.

        Returns:
            The TrackingPage.
        """
        return next(page for page in window.pages if page.group_id == "tracking")

    def test_missing_plugin_is_explained_and_marks_the_margin_option(self):
        """Without the plugin the page says so and warns on the option."""
        window = self.open_window()
        page = self.tracking_page(window)
        self.assertEqual(page.plugin_row.get_title(), "hyprzoom plugin not detected")
        # Read the option's explanation as the user sees it.
        subtitle = self.row(window, "ZOOM_TRACKING").option_rows["margin"].get_subtitle()
        self.assertIn("Needs the hyprzoom plugin", subtitle)

    def test_loaded_plugin_is_reported(self):
        """With the plugin the hint turns positive."""
        self.fake.set_status(plugin="loaded")
        window = self.open_window()
        page = self.tracking_page(window)
        # The hint turns positive.
        self.assertEqual(page.plugin_row.get_title(), "hyprzoom plugin detected")
        subtitle = self.row(window, "ZOOM_TRACKING").option_rows["margin"].get_subtitle()
        self.assertNotIn("Needs the hyprzoom plugin", subtitle)

    def test_effective_mode_is_shown(self):
        """Configured margin without plugin shows the effective fallback."""
        self.fake.set_status(tracking="margin", tracking_effective="edge")
        window = self.open_window()
        self.assertEqual(self.tracking_page(window).effective_row.get_subtitle(), "edge")


class BannerAndMenuTests(GuiTestCase):
    """Engine banner, setup action, restore defaults."""

    def test_no_banner_when_the_engine_runs(self):
        """A healthy engine shows no banner."""
        window = self.open_window()
        self.assertFalse(window.banner.get_revealed())

    def test_banner_offers_setup_when_the_engine_is_missing(self):
        """engine=missing reveals the banner with a Set up button."""
        self.fake.set_status(engine="missing")
        window = self.open_window()
        self.assertTrue(window.banner.get_revealed())
        # The button label is the contract wording.
        self.assertEqual(window.banner.get_button_label(), "Set up")

    def test_setup_button_runs_zoomctl_setup_and_hides_the_banner(self):
        """Set up -> ``zoomctl setup`` -> the status turns healthy -> banner gone."""
        self.fake.set_status(engine="missing")
        window = self.open_window()
        window.banner.emit("button-clicked")
        # The click ran ``zoomctl setup``.
        self.wait_for_calls("setup")
        pump(lambda: not window.banner.get_revealed())
        pump(lambda: self.toasts)
        # The user is told what happened.
        self.assertIn("Engine set up", self.toasts[0])

    def test_unreachable_zoomctl_is_explained_without_a_setup_button(self):
        """A missing zoomctl binary shows the reason and offers no action."""
        window = self.open_window()
        window.controller.client.binary = "/nonexistent/zoomctl"
        window.controller.refresh_status()
        # The banner appears after the status refresh fails.
        pump(lambda: window.banner.get_revealed())
        self.assertIn("zoomctl is not available", window.banner.get_title())
        self.assertIsNone(window.banner.get_button_label())

    def test_restore_defaults_asks_before_resetting(self):
        """The action opens a confirmation; nothing happens until it is confirmed."""
        asked = []
        window = self.open_window()
        with mock.patch.object(GUI["dialogs"], "confirm", lambda *args: asked.append(args)):
            # The same path the menu item takes.
            window.activate_action("win.restore-defaults", None)
        self.assertEqual(len(asked), 1)
        self.settle(0.2)
        # Nothing ran before the confirmation.
        self.assertEqual(self.fake.calls_matching("reset-config"), [])
        # Confirming runs the callback the window handed over.
        asked[0][4]()
        self.wait_for_calls("reset-config")
        pump(lambda: self.toasts)
        self.assertEqual(self.toasts, ["Default settings restored"])

    def test_restore_defaults_button_on_the_advanced_page_is_wired_to_the_action(self):
        """The destructive button triggers the same window action."""
        window = self.open_window()
        buttons = [w for w in iter_widgets(window) if isinstance(w, GUI["Gtk"].Button)]
        wired = [b for b in buttons if b.get_action_name() == "win.restore-defaults"]
        # Exactly one button is wired to the action.
        self.assertEqual(len(wired), 1)

    def test_real_confirm_dialog_presents_and_only_confirm_runs_the_action(self):
        """The real Adw.AlertDialog works on this backend; Cancel is a no-op."""
        window = self.open_window()
        ran = []
        GUI["dialogs"].confirm(window, "Sure?", "Body", "Do it", lambda: ran.append(1))
        # Give the dialog time to map.
        pump_for(0.2)
        dialog = window.get_visible_dialog()
        self.assertIsInstance(dialog, GUI["Adw"].AlertDialog)
        # Cancel must not run the action.
        dialog.emit("response", "cancel")
        self.assertEqual(ran, [])
        dialog.emit("response", "confirm")
        # Confirm runs it exactly once.
        self.assertEqual(ran, [1])


class TryItTests(GuiTestCase):
    """The bottom bar: status line, zoom test, filter preview."""

    def test_status_line_shows_the_engine_state(self):
        """The line summarises zoom, tracking, filter and engine."""
        self.fake.set_status(zoom="1.75")
        window = self.open_window()
        line = window.tryit_bar.status_label.get_label()
        # The zoom from the status appears with two decimals.
        self.assertIn("Zoom 1.75×", line)
        self.assertIn("Tracking: centered", line)
        self.assertIn("Engine: lua", line)

    def test_status_line_refreshes_every_second_while_visible(self):
        """The 1 s timer picks up an external zoom change."""
        window = self.open_window(refresh_seconds=1)
        self.fake.set_status(zoom="3.00")
        pump(lambda: "Zoom 3.00×" in window.tryit_bar.status_label.get_label(), timeout=4)

    def test_status_timer_stops_when_the_window_is_hidden(self):
        """No polling while nobody looks."""
        window = self.open_window(refresh_seconds=1)
        window.set_visible(False)
        pump_for(0.2)
        # Only polls made after hiding count.
        self.fake.clear_calls()
        pump_for(2.3)
        self.assertEqual(self.fake.calls_matching("status"), [])

    def test_buttons_name_the_test_and_its_duration(self):
        """Labels follow the configured durations."""
        window = self.open_window()
        self.assertEqual(window.tryit_bar.zoom_button.get_label(), "Zoom to 2× for 2 s")
        self.assertEqual(window.tryit_bar.filter_button.get_label(), "Preview filter for 2 s")

    def test_zoom_test_zooms_shows_a_countdown_and_restores(self):
        """2× now, countdown visible, the previous zoom afterwards."""
        self.fake.set_status(zoom="1.40")
        window = self.open_window(zoom_seconds=3)
        bar = window.tryit_bar
        # The click starts the test; the zoom call follows.
        bar.zoom_button.emit("clicked")
        self.assertTrue(bar.countdown_label.get_visible())
        self.assertFalse(bar.zoom_button.get_visible())
        # The Stop button replaces the start buttons.
        self.assertTrue(bar.stop_button.get_visible())
        self.assertIn("back to normal in 3 s", bar.countdown_label.get_label())
        self.wait_for_calls("zoom", count=2)
        # Zoom to 2.00, then back to the previous 1.40.
        self.assertEqual(self.fake.calls_matching("zoom"), [["zoom", "2.00"], ["zoom", "1.40"]])
        pump(lambda: bar.zoom_button.get_visible())

    def test_stop_button_restores_early(self):
        """Stop now ends the test before the countdown."""
        window = self.open_window(zoom_seconds=100)
        window.tryit_bar.zoom_button.emit("clicked")
        window.tryit_bar.stop_button.emit("clicked")
        # The stop restored the zoom.
        self.wait_for_calls("zoom", count=2)
        self.assertTrue(window.tryit_bar.zoom_button.get_visible())

    def test_filter_preview_offers_keep_and_revert(self):
        """During the preview only Keep and Revert are offered."""
        window = self.open_window(filter_seconds=100)
        bar = window.tryit_bar
        bar.filter_button.emit("clicked")
        # The preview call has been made.
        self.wait_for_calls("preview")
        self.assertEqual(
            self.fake.calls_matching("preview")[0],
            ["preview", "FILTER=smart-invert", "FILTER_ACTIVE=on"],
        )
        self.assertTrue(bar.keep_button.get_visible() and bar.revert_button.get_visible())
        # The start button is hidden during the preview.
        self.assertFalse(bar.filter_button.get_visible())

    def test_revert_ends_the_preview_and_saves_nothing(self):
        """Revert = ``preview --end``."""
        window = self.open_window(filter_seconds=100)
        window.tryit_bar.filter_button.emit("clicked")
        window.tryit_bar.revert_button.emit("clicked")
        # Start and end of the preview.
        self.wait_for_calls("preview", count=2)
        self.assertEqual(self.fake.calls_matching("preview")[1], ["preview", "--end"])
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_keep_saves_the_filter_then_ends_the_preview(self):
        """Keep = ``set FILTER_ACTIVE on`` then ``preview --end``."""
        window = self.open_window(filter_seconds=100)
        window.tryit_bar.filter_button.emit("clicked")
        window.tryit_bar.keep_button.emit("clicked")
        # Keep ends the preview after saving.
        self.wait_for_calls("preview", count=2)
        self.assertEqual(self.fake.calls_matching("set"), [["set", "FILTER_ACTIVE", "on"]])
        self.assertEqual(self.fake.config_value("FILTER_ACTIVE"), "on")

    def test_failed_zoom_test_toasts_and_returns_to_idle(self):
        """An engine error ends the test and tells the user."""
        self.fake.respond("zoom", stderr="zoomctl: engine not loaded\n", rc=1)
        window = self.open_window()
        window.tryit_bar.zoom_button.emit("clicked")
        # The refusal reaches the user.
        pump(lambda: self.toasts)
        pump(lambda: window.tryit_bar.zoom_button.get_visible())
        self.assertEqual(self.toasts, ["zoomctl: engine not loaded"])

    def test_closing_during_a_test_restores_the_screen(self):
        """The window must never leave the screen zoomed or filtered."""
        self.fake.set_status(zoom="1.20")
        window = self.open_window(zoom_seconds=100)
        window.tryit_bar.zoom_button.emit("clicked")
        # Closing mid-test must restore the screen.
        window.close()
        self.wait_for_calls("zoom", count=2)
        self.assertEqual(self.fake.calls_matching("zoom")[-1], ["zoom", "1.20"])


class KeyCaptureTests(GuiTestCase):
    """The shortcut rows and the capture dialog."""

    def press(self, dialog, keysym_name):
        """Simulate a key press in a capture dialog.

        Args:
            dialog: The KeyCaptureDialog.
            keysym_name: GDK keysym name such as ``p`` or ``Escape``.

        Returns:
            What the key handler returned (True = consumed).
        """
        keyval = GUI["Gdk"].keyval_from_name(keysym_name)
        # Keycode 0 makes the layout lookup fail, which exercises the keyval fallback.
        return dialog._on_key_pressed(None, keyval, 0, 0)

    def open_capture(self, window, key):
        """Open the capture dialog of a key row.

        Args:
            window: The window.
            key: Schema key of a key row.

        Returns:
            The dialog.
        """
        opened = []
        original = GUI["rows"].KeyCaptureDialog
        with mock.patch.object(GUI["rows"], "KeyCaptureDialog", lambda *a: opened.append(
                original(*a)) or opened[-1]):
            # Clicking Change opens the capture dialog.
            self.row(window, key).change_button.emit("clicked")
        return opened[0]

    def test_capturing_a_free_key_sets_the_hyprland_name(self):
        """Pressing P assigns key P."""
        window = self.open_window()
        dialog = self.open_capture(window, "BIND_KEY_IN")
        self.assertTrue(self.press(dialog, "p"))
        # The captured key was applied.
        self.wait_for_calls("set")
        self.assertEqual(self.fake.calls_matching("set"), [["set", "BIND_KEY_IN", "P"]])

    def test_named_keys_are_captured_with_their_hyprland_names(self):
        """Return becomes RETURN."""
        window = self.open_window()
        dialog = self.open_capture(window, "BIND_KEY_FILTER")
        self.press(dialog, "Return")
        # A named key is applied with its Hyprland name.
        self.wait_for_calls("set")
        self.assertEqual(self.fake.calls_matching("set")[0][2], "RETURN")

    def test_a_key_used_by_another_shortcut_is_refused(self):
        """O is the zoom-out key, so it cannot also zoom in."""
        window = self.open_window()
        dialog = self.open_capture(window, "BIND_KEY_IN")
        self.press(dialog, "o")
        # No set may follow the refused key.
        self.settle(0.2)
        self.assertEqual(self.fake.calls_matching("set"), [])
        self.assertEqual(len(self.toasts), 1)
        # The toast names the other shortcut.
        self.assertIn("already used by “Zoom out key”", self.toasts[0])

    def test_modifier_and_escape_presses_do_not_assign_anything(self):
        """Lone modifiers are swallowed, Escape is left to the dialog."""
        window = self.open_window()
        dialog = self.open_capture(window, "BIND_KEY_IN")
        self.assertTrue(self.press(dialog, "Shift_L"))
        # Escape is passed on so the dialog closes.
        self.assertFalse(self.press(dialog, "Escape"))
        self.settle(0.2)
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_disable_button_clears_the_key(self):
        """Disable sends an empty key."""
        window = self.open_window()
        self.row(window, "BIND_KEY_IN").disable_button.emit("clicked")
        self.wait_for_calls("set")
        # An empty key disables the bind.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "BIND_KEY_IN", ""]])

    def test_disabled_key_shows_a_word_instead_of_a_keycap(self):
        """An empty key hides the shortcut label."""
        self.fake.respond("config", stdout="BIND_KEY_IN=\n")
        window = self.open_window()
        row = self.row(window, "BIND_KEY_IN")
        # The word replaces the keys.
        self.assertFalse(row.keycaps.get_visible())
        self.assertTrue(row.disabled_label.get_visible())
        self.assertFalse(row.disable_button.get_sensitive())

    def test_shortcut_shows_modifiers_and_key(self):
        """The keycap label combines the modifier setting and the key."""
        window = self.open_window()
        row = self.row(window, "BIND_KEY_IN")
        self.assertEqual(row.keycap_texts(), ["Super", "Alt", "I"])


class AppTests(GuiTestCase):
    """Application object, root refusal, entry script, assets."""

    def test_root_is_refused_with_a_message(self):
        """Contract C8: normal user only."""
        self.assertIn("must not run as root", GUI["app"].refuse_root(0))
        self.assertIsNone(GUI["app"].refuse_root(1000))

    def test_main_returns_one_for_root_without_opening_a_window(self):
        """``main`` stops before touching GTK when started as root."""
        with mock.patch.object(os, "geteuid", return_value=0):
            self.assertEqual(GUI["app"].main(["x"]), GUI["app"].EXIT_REFUSED)

    def test_application_id_and_single_instance_flags(self):
        """The real application is unique on the session bus under the contract id."""
        application = GUI["app"].ZoomSettingsApplication()
        self.assertEqual(application.get_application_id(), "io.github.artibex.HyprlandZoom")
        non_unique = GUI["Gio"].ApplicationFlags.NON_UNIQUE
        # NON_UNIQUE would allow two settings windows.
        self.assertFalse(application.get_flags() & non_unique)

    def test_activate_builds_one_window_and_reuses_it(self):
        """A second activation raises the existing window."""
        application = GUI["app"].ZoomSettingsApplication(
            "test.hyprland_zoom.activate", GUI["Gio"].ApplicationFlags.NON_UNIQUE,
            environment={**os.environ},
        )
        application.register(None)
        application.activate()
        # The first activation created the window.
        first = application.window
        application.activate()
        self.assertIs(application.window, first)
        # The window is destroyed after the test.
        self.addCleanup(self.close_window, first)

    def test_missing_schema_gives_an_explanatory_window(self):
        """Without a schema the app explains instead of crashing."""
        application = GUI["app"].ZoomSettingsApplication(
            "test.hyprland_zoom.noschema", GUI["Gio"].ApplicationFlags.NON_UNIQUE,
            environment={"ZOOMCTL_SHARE_DIR": "/nonexistent/share"},
        )
        application.register(None)
        window = application._create_window()
        # The explanation window is destroyed after the test.
        self.addCleanup(window.destroy)
        statuses = [w for w in iter_widgets(window) if isinstance(w, GUI["Adw"].StatusPage)]
        self.assertIn("settings.schema was not found", statuses[0].get_description())

    def test_entry_script_finds_the_package_in_the_checkout(self):
        """The script resolves the package next to itself."""
        path = support.REPO_ROOT / "src" / "ui" / "hyprland-zoom-settings"
        loader = importlib.machinery.SourceFileLoader("entry_script", str(path))
        spec = importlib.util.spec_from_loader("entry_script", loader)
        # The script is loaded as a module without running it.
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        self.assertEqual(module.find_package_parent(), str(support.UI_SOURCE_DIR))
        # The packaged script must be executable.
        self.assertTrue(os.access(path, os.X_OK))

    def test_style_sheet_parses_without_errors(self):
        """The keycap CSS uses only constructs this GTK understands."""
        from hyprland_zoom_settings import styles

        errors = []
        provider = GUI["Gtk"].CssProvider()
        # Parsing errors are collected, not printed.
        provider.connect("parsing-error", lambda _p, _section, error: errors.append(error))
        provider.load_from_string(styles.STYLE_SHEET)
        self.assertEqual(errors, [])

    def test_icon_and_desktop_file_are_consistent(self):
        """The desktop entry points at the app id, the icons exist and load."""
        desktop = (support.REPO_ROOT / "data" / "io.github.artibex.HyprlandZoom.desktop")
        text = desktop.read_text(encoding="utf-8")
        self.assertIn("Exec=hyprland-zoom-settings", text)
        # The desktop file names the contract application id.
        self.assertIn("Icon=io.github.artibex.HyprlandZoom", text)
        theme = GUI["Gtk"].IconTheme.get_for_display(GUI["Gdk"].Display.get_default())
        theme.add_search_path(str(support.REPO_ROOT / "data" / "icons"))
        # The colour icon and its symbolic variant both resolve.
        self.assertTrue(theme.has_icon("io.github.artibex.HyprlandZoom"))
        self.assertTrue(theme.has_icon("io.github.artibex.HyprlandZoom-symbolic"))


if __name__ == "__main__":
    # Allows running this file directly.
    unittest.main()
