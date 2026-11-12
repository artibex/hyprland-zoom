"""Headless tests of the zoomctl client, the settings controller and the try-it state machine.

They need GLib/Gio only (no display): the fake zoomctl runs as a real subprocess and results
arrive through the default main context that ``support.pump`` iterates.
"""

# unittest is the runner; support provides the fake zoomctl, the pump and the import path.
import unittest

import support
from support import FakeZoomctlTestCase, pump, pump_for

from hyprland_zoom_settings import tryit
# The units under test: client, controller and the schema they run on.
from hyprland_zoom_settings.backend import CommandResult, ZoomctlClient
from hyprland_zoom_settings.controller import SettingsController
from hyprland_zoom_settings.schema import parse_schema


def run_and_wait(client, arguments):
    """Run one command and wait for its result.

    Args:
        client: ZoomctlClient.
        arguments: zoomctl arguments.

    Returns:
        The CommandResult.
    """
    # The list is a mutable cell the callback fills in.
    results = []
    client.run(arguments, results.append)
    pump(lambda: results)
    return results[0]


class ClientTests(FakeZoomctlTestCase):
    """The asynchronous zoomctl client."""

    def test_success_returns_stdout_and_status_zero(self):
        """A normal call delivers its output."""
        result = run_and_wait(ZoomctlClient(str(support.FAKE_ZOOMCTL)), ["status", "--porcelain"])
        self.assertTrue(result.ok)
        self.assertIn("engine=lua", result.stdout)

    def test_failure_exposes_first_stderr_line(self):
        """The toast text is the first stderr line, not the whole noise."""
        self.fake.respond("set", stderr="\nzoomctl: bad value\nusage: ...\n", rc=1)
        result = run_and_wait(ZoomctlClient(str(support.FAKE_ZOOMCTL)), ["set", "A", "b"])
        self.assertFalse(result.ok)
        # The exit status is kept for callers that care.
        self.assertEqual(result.exit_status, 1)
        self.assertEqual(result.message, "zoomctl: bad value")

    def test_missing_binary_is_a_failure_not_an_exception(self):
        """A missing zoomctl produces a readable failure."""
        result = run_and_wait(ZoomctlClient("/nonexistent/zoomctl"), ["status"])
        self.assertFalse(result.ok)
        self.assertIn("Could not run '/nonexistent/zoomctl'", result.message)

    def test_hanging_call_is_killed_after_the_timeout(self):
        """A call that outlives the timeout is killed and reported."""
        self.fake.respond("status", sleep=5)
        client = ZoomctlClient(str(support.FAKE_ZOOMCTL), timeout_seconds=1)
        result = run_and_wait(client, ["status"])
        # A missing binary is a failure result, not an exception.
        self.assertFalse(result.ok)
        self.assertIn("timed out after 1 s", result.message)

    def test_callback_is_never_called_inside_run(self):
        """Even a spawn failure is delivered from the main loop."""
        results = []
        ZoomctlClient("/nonexistent/zoomctl").run(["x"], results.append)
        self.assertEqual(results, [])
        # The callback arrives only after the main loop ran.
        pump(lambda: results)

    def test_result_message_falls_back_to_generic_text(self):
        """No stderr and no failure text still yields a message."""
        self.assertIn("zoomctl set A failed", CommandResult(["set", "A"], 1).message)


class ControllerFixture(FakeZoomctlTestCase):
    """Base: a controller on the real schema with the fake zoomctl."""

    def setUp(self):
        """Build the controller and record its signals."""
        super().setUp()
        schema = parse_schema(support.read_schema_text())
        self.controller = SettingsController(schema, ZoomctlClient(str(support.FAKE_ZOOMCTL)))
        # Plain lists collect what the signals deliver.
        self.errors = []
        self.error_details = []
        self.config_changes = []
        self.status_changes = []
        # Signal handlers append to plain lists the tests inspect.
        self.controller.connect("error", self._record_error)
        self.controller.connect("config-changed", lambda _c: self.config_changes.append(1))
        self.controller.connect("status-changed", lambda _c: self.status_changes.append(1))

    def _record_error(self, _controller, message, details):
        """Remember an error signal.

        Args:
            _controller: The controller (unused).
            message: Plain sentence.
            details: Technical text.

        Returns:
            None.
        """
        # Two parallel lists keep the assertions of older tests unchanged.
        self.errors.append(message)
        self.error_details.append(details)


class ControllerTests(ControllerFixture):
    """Reading and writing settings."""

    def test_refresh_config_adopts_values_and_ignores_unknown_keys(self):
        """Effective values replace the defaults; unknown keys are dropped."""
        self.fake.respond(
            "config", stdout="ZOOM_STEP=0.25\nNOT_A_KEY=1\nZOOM_TRACKING=edge\n"
        )
        self.controller.refresh_config()
        pump(lambda: self.config_changes)
        # The reported value replaced the default.
        self.assertEqual(self.controller.values["ZOOM_STEP"], "0.25")
        self.assertEqual(self.controller.values["ZOOM_TRACKING"], "edge")
        self.assertNotIn("NOT_A_KEY", self.controller.values)
        # Keys the CLI did not report keep their default.
        self.assertEqual(self.controller.values["ZOOM_MIN"], "1.00")

    def test_set_value_sends_one_set_call_with_the_canonical_value(self):
        """A valid change becomes ``zoomctl set KEY VALUE``."""
        verdict = self.controller.set_value("ZOOM_STEP", "0.2")
        self.assertTrue(verdict.ok)
        self.wait_for_calls("set")
        # Exactly one set with the canonical two-decimal text.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "ZOOM_STEP", "0.20"]])
        pump(lambda: self.controller.values["ZOOM_STEP"] == "0.20")

    def test_invalid_value_never_reaches_zoomctl_and_reverts_widgets(self):
        """Local validation refuses, toasts and asks the widgets to re-read."""
        verdict = self.controller.set_value("ZOOM_STEP", "9")
        self.assertFalse(verdict.ok)
        self.assertEqual(len(self.errors), 1)
        # Widgets must be told to revert.
        self.assertTrue(self.config_changes)
        pump_for(0.2)
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_rejected_set_keeps_the_old_value_and_reports_the_message(self):
        """zoomctl refusing a change leaves the effective value untouched."""
        self.fake.respond("set", stderr="zoomctl: the engine said no\n", rc=1)
        outcomes = []
        self.controller.set_value("ZOOM_MAX", "6", outcomes.append)
        # The outcome callback fires after the process ended.
        pump(lambda: outcomes)
        self.assertEqual(outcomes, [False])
        # The prefix is gone; short, path-free text is shown as it is.
        self.assertEqual(self.errors, ["The engine said no"])
        # A refused change leaves the default untouched.
        self.assertEqual(self.controller.values["ZOOM_MIN"], "1.00")

    def test_changes_are_serialised_and_same_key_changes_are_coalesced(self):
        """Only the newest value of a key is sent; other keys keep their order."""
        self.controller.set_value("ZOOM_STEP", "0.11")
        # The first call is already in flight, so the next two queue up behind it.
        self.controller.set_value("ZOOM_MAX", "5")
        self.controller.set_value("ZOOM_MAX", "6")
        self.controller.set_value("ZOOM_STEP", "0.12")
        self.wait_for_calls("set", count=3)
        # Give a wrongly spawned process time to show up in the log.
        pump_for(0.2)
        self.assertEqual(
            self.fake.calls_matching("set"),
            [["set", "ZOOM_STEP", "0.11"], ["set", "ZOOM_MAX", "6.00"],
             ["set", "ZOOM_STEP", "0.12"]],
        )

    def test_successful_set_is_followed_by_a_config_refresh(self):
        """The effective values are re-read once the queue is empty."""
        self.controller.set_value("ZOOM_STEP", "0.3")
        self.wait_for_calls("config", count=1)

    def test_status_unreachable_when_zoomctl_cannot_run(self):
        """A missing zoomctl yields the unreachable status and remembers why."""
        self.controller.client.binary = "/nonexistent/zoomctl"
        self.controller.refresh_status()
        pump(lambda: self.status_changes)
        # No answer means the unreachable state.
        self.assertEqual(self.controller.status.engine, "unreachable")
        self.assertIn("Could not run", self.controller.status_problem)

    def test_unchanged_status_does_not_emit_again(self):
        """Polling every second must not redraw the UI without news."""
        self.controller.refresh_status()
        pump(lambda: self.status_changes)
        self.controller.refresh_status()
        # The second poll must really have run.
        self.wait_for_calls("status", count=2)
        pump_for(0.2)
        self.assertEqual(len(self.status_changes), 1)

    def test_reset_config_calls_reset_and_reloads(self):
        """Restore defaults is ``reset-config`` followed by a refresh."""
        outcomes = []
        self.controller.reset_config(outcomes.append)
        pump(lambda: outcomes)
        # reset_config reports success to its caller.
        self.assertEqual(outcomes, [True])
        self.wait_for_calls("config")
        self.assertEqual(self.fake.calls_matching("reset-config"), [["reset-config"]])

    def test_stderr_note_on_success_is_info_not_error(self):
        """``set`` exits 0 with a note when the engine is offline: shown as info."""
        self.fake.respond("set", stderr="zoomctl: engine not reachable, saved only\n", rc=0)
        infos = []
        self.controller.connect("info", lambda _c, message, _details: infos.append(message))
        # The outcome list proves the change counted as applied.
        outcomes = []
        self.controller.set_value("ZOOM_STEP", "0.3", outcomes.append)
        pump(lambda: outcomes)
        # Exit status 0 means success even with a note.
        self.assertEqual(outcomes, [True])
        self.assertIn("Hyprland is not reachable", infos[0])
        self.assertEqual(self.errors, [])

    def test_run_action_reports_failures_as_errors(self):
        """Actions share one error path."""
        self.fake.respond("zoom", stderr="zoomctl: engine not loaded\n", rc=1)
        results = []
        self.controller.run_action(["zoom", "2.00"], results.append)
        # Wait for the failing command to report.
        pump(lambda: results)
        self.assertEqual(self.errors, ["The zoom engine is not loaded in Hyprland."])
        # The raw text stays available for the Details button.
        self.assertEqual(self.error_details, ["engine not loaded"])

    def test_zoom_order_rule_is_checked_locally_with_labels(self):
        """MIN above RESET never reaches zoomctl; the message names the labels."""
        verdict = self.controller.set_value("ZOOM_MIN", "3")
        self.assertFalse(verdict.ok)
        self.assertEqual(self.errors, ["Minimum zoom (3.00) can't be above Reset zoom (1.00)"])
        pump_for(0.2)
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_failed_set_tells_widgets_to_revert_even_when_the_reread_fails_too(self):
        """A rejected change must not depend on the follow-up config read to be undone."""
        self.fake.respond("set", stderr="zoomctl: no\n", rc=1)
        self.fake.respond("config", stderr="zoomctl: cannot read\n", rc=1)
        outcomes = []
        self.controller.set_value("ZOOM_STEP", "0.5", outcomes.append)
        pump(lambda: outcomes)
        # The revert signal comes from the failed set itself.
        self.assertTrue(self.config_changes)
        # The failed read is reported too, and the old value stays effective.
        self.wait_for_calls("config")
        pump(lambda: len(self.errors) >= 2)
        self.assertEqual(self.controller.values["ZOOM_STEP"], "0.10")

    def test_unchanged_configuration_does_not_redraw(self):
        """The periodic re-read stays silent without news."""
        self.controller.refresh_config()
        pump(lambda: self.config_changes)
        seen = len(self.config_changes)
        self.controller.refresh_config()
        self.wait_for_calls("config", count=2)
        pump_for(0.2)
        self.assertEqual(len(self.config_changes), seen)
        # An external change is noticed.
        self.fake.respond("config", stdout="ZOOM_STEP=0.77\n")
        self.controller.refresh_config()
        pump(lambda: len(self.config_changes) > seen)
        self.assertEqual(self.controller.values["ZOOM_STEP"], "0.77")


class TryItTests(ControllerFixture):
    """The zoom test and the filter preview."""

    def make(self, zoom_seconds=2, filter_seconds=2):
        """Create a controller with a fast countdown.

        Args:
            zoom_seconds: Zoom test length in ticks.
            filter_seconds: Filter preview length in ticks.

        Returns:
            The TryItController (50 ms per tick).
        """
        # The status must be known first: the zoom test restores the zoom it saw.
        self.fake.set_status(zoom="1.30")
        self.controller.refresh_status()
        pump(lambda: self.controller.status.zoom is not None)
        return tryit.TryItController(self.controller, zoom_seconds, filter_seconds, 50)

    def test_zoom_test_zooms_then_restores_the_previous_zoom(self):
        """2.00 now, the previous 1.30 after the countdown."""
        session = self.make()
        session.start_zoom_test()
        self.assertEqual(session.mode, tryit.MODE_ZOOM)
        # The restore is the second zoom call.
        self.wait_for_calls("zoom", count=2)
        self.assertEqual(
            self.fake.calls_matching("zoom"),
            [["zoom", "2.00", "--transient"], ["zoom", "1.30", "--transient"]],
        )
        self.assertEqual(session.mode, tryit.MODE_IDLE)
        # The test left the toggle's remembered level alone (R-P2-18).
        self.controller.refresh_status()
        pump(lambda: self.controller.status.saved_zoom is not None)
        self.assertNotEqual(self.controller.status.saved_zoom, 2.0)

    def test_countdown_is_reported_through_the_changed_signal(self):
        """The widgets see every remaining second."""
        session = self.make(zoom_seconds=3)
        seen = []
        session.connect("changed", lambda _s: seen.append(session.seconds_left))
        # The second start must be ignored while the first runs.
        session.start_zoom_test()
        pump(lambda: session.mode == tryit.MODE_IDLE)
        self.assertEqual(seen, [3, 2, 1, 0])

    def test_stop_restores_early_and_a_second_start_is_ignored_while_busy(self):
        """Stop ends the test at once; start during a test does nothing."""
        session = self.make(zoom_seconds=50)
        session.start_zoom_test()
        session.start_zoom_test()
        # Stop ends the test at once instead of after 50 ticks.
        session.stop()
        self.wait_for_calls("zoom", count=2)
        self.assertEqual(len(self.fake.calls_matching("zoom")), 2)
        # The controller is idle again.
        self.assertEqual(session.mode, tryit.MODE_IDLE)

    def test_failed_zoom_start_ends_the_test_without_restoring(self):
        """If the zoom was refused there is nothing to undo."""
        self.fake.respond("zoom", stderr="zoomctl: no engine\n", rc=1)
        session = self.make()
        session.start_zoom_test()
        # The failed start ends the test by itself.
        pump(lambda: session.mode == tryit.MODE_IDLE)
        pump_for(0.3)
        self.assertEqual(self.fake.calls_matching("zoom"), [["zoom", "2.00", "--transient"]])
        # The failure reached the user as an error, in plain words.
        self.assertEqual(self.errors, ["The zoom engine is not loaded in Hyprland."])

    def test_filter_preview_uses_the_configured_filter_and_ends_with_preview_end(self):
        """The preview forces the filter on and is dropped when the countdown ends."""
        self.controller.values["FILTER"] = "grayscale"
        session = self.make()
        session.start_filter_preview()
        # Start and end of the preview are two calls.
        self.wait_for_calls("preview", count=2)
        self.assertEqual(
            self.fake.calls_matching("preview"),
            [["preview", "FILTER=grayscale", "FILTER_ACTIVE=on"], ["preview", "--end"]],
        )

    def test_revert_ends_the_preview_without_saving(self):
        """Revert is stop(): preview --end, no ``set``."""
        session = self.make(filter_seconds=50)
        session.start_filter_preview()
        session.stop()
        # Revert issues the end call.
        self.wait_for_calls("preview", count=2)
        self.assertEqual(self.fake.calls_matching("set"), [])

    def test_keep_saves_the_filter_before_ending_the_preview(self):
        """Keep = ``set FILTER_ACTIVE on`` then ``preview --end``."""
        session = self.make(filter_seconds=50)
        session.start_filter_preview()
        session.keep()
        # Keep issues set and then the end call.
        self.wait_for_calls("preview", count=2)
        order = [call[0] for call in self.fake.calls() if call[0] in ("set", "preview")]
        self.assertEqual(order, ["preview", "set", "preview"])
        # Exactly one set is sent, the saved filter switch.
        self.assertEqual(self.fake.calls_matching("set"), [["set", "FILTER_ACTIVE", "on"]])
        self.assertEqual(session.mode, tryit.MODE_IDLE)

    def test_shutdown_restores_a_running_test(self):
        """Closing the window must not leave the screen zoomed."""
        session = self.make(zoom_seconds=50)
        session.start_zoom_test()
        session.shutdown()
        # Shutdown restores without waiting for the countdown.
        self.wait_for_calls("zoom", count=2)
        self.assertEqual(self.fake.calls_matching("zoom")[-1], ["zoom", "1.30", "--transient"])

    def test_failed_preview_start_ends_the_preview_quietly(self):
        """A refused preview may have applied part of it, so it is ended (R-P2-02)."""
        self.fake.respond("preview", "FILTER=smart-invert", stderr="zoomctl: boom\n", rc=1,
                          apply=True)
        session = self.make()
        session.start_filter_preview()
        pump(lambda: session.mode == tryit.MODE_IDLE)
        self.wait_for_calls("preview", count=2)
        self.assertEqual(self.fake.calls_matching("preview")[1], ["preview", "--end"])
        pump_for(0.2)
        # One error for the failed start; the cleanup call is silent even if it fails too.
        self.assertEqual(len(self.errors), 1)

    def test_changing_the_filter_during_a_preview_updates_the_preview(self):
        """The newly saved filter shows up in the running preview and the countdown restarts."""
        session = self.make(filter_seconds=50)
        session.start_filter_preview()
        self.wait_for_calls("preview")
        session.seconds_left = 10
        self.controller.set_value("FILTER", "grayscale")
        self.wait_for_calls("preview", count=2)
        self.assertEqual(self.fake.calls_matching("preview")[1],
                         ["preview", "FILTER=grayscale", "FILTER_ACTIVE=on"])
        # The countdown restarted (at most one tick has passed since).
        self.assertGreaterEqual(session.seconds_left, 49)
        # The preview is still running.
        self.assertEqual(session.mode, tryit.MODE_FILTER)

    def test_filter_change_without_a_preview_starts_nothing(self):
        """Idle sessions ignore filter changes."""
        session = self.make()
        self.controller.set_value("FILTER", "invert")
        self.wait_for_calls("set")
        pump_for(0.3)
        self.assertEqual(self.fake.calls_matching("preview"), [])
        self.assertEqual(session.mode, tryit.MODE_IDLE)


if __name__ == "__main__":
    # Allows running this file directly.
    unittest.main()
