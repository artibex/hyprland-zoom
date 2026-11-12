"""The "Try it" state machine: a timed zoom test and a timed filter preview with Keep/Revert.

Both tests change the live screen, so the first rule is that they always end: a countdown
restores the previous state, "Stop"/"Revert" does it early and closing the window does it
immediately (``shutdown``).
"""

# typing documents the optional previous zoom.
from typing import Optional

import gi

gi.require_version("GObject", "2.0")
from gi.repository import GLib, GObject  # noqa: E402 - gi.require_version must run first

from .constants import FILTER_PREVIEW_SECONDS, ZOOM_TEST_FACTOR, ZOOM_TEST_SECONDS  # noqa: E402
from .controller import SettingsController  # noqa: E402
from .values import format_float  # noqa: E402

# What the controller is currently doing.
MODE_IDLE = "idle"
MODE_ZOOM = "zoom"
MODE_FILTER = "filter"
# Zoom level assumed when the status does not report one (the unzoomed screen).
FALLBACK_ZOOM = 1.0
# Schema key and value that switch the colour filter on.
FILTER_ACTIVE_KEY = "FILTER_ACTIVE"
FILTER_KEY = "FILTER"


class TryItController(GObject.Object):
    """Runs the timed tests and exposes ``mode`` and ``seconds_left`` to the widgets."""

    __gsignals__ = {
        # Mode or countdown changed: redraw the buttons and the countdown text.
        "changed": (GObject.SignalFlags.RUN_FIRST, None, ()),
    }

    def __init__(
        self,
        settings: SettingsController,
        zoom_seconds: int = ZOOM_TEST_SECONDS,
        filter_seconds: int = FILTER_PREVIEW_SECONDS,
        tick_milliseconds: int = 1000,
    ) -> None:
        """Create an idle controller.

        Args:
            settings: Controller used to run zoomctl and to keep the filter on.
            zoom_seconds: Duration of the zoom test.
            filter_seconds: Duration of the filter preview.
            tick_milliseconds: Length of one countdown second (tests shorten it).

        Returns:
            None.
        """
        super().__init__()
        self.settings = settings
        self.zoom_seconds = zoom_seconds
        self.filter_seconds = filter_seconds
        self.tick_milliseconds = tick_milliseconds
        # Public state read by the widgets.
        self.mode = MODE_IDLE
        self.seconds_left = 0
        self._previous_zoom: Optional[float] = None
        self._timer_id = 0

    @property
    def busy(self) -> bool:
        """Tell whether a test is running.

        Returns:
            True while a zoom test or filter preview is active.
        """
        # Only one test at a time: both change the same screen.
        return self.mode != MODE_IDLE

    # ----- starting -----------------------------------------------------------------------

    def start_zoom_test(self) -> None:
        """Zoom to the test factor and restore the previous zoom afterwards.

        Returns:
            None.
        """
        if self.busy:
            return
        # The previous zoom is read now so the restore does not depend on a later status.
        previous = self.settings.status.zoom
        self._previous_zoom = FALLBACK_ZOOM if previous is None else previous
        self._begin(MODE_ZOOM, self.zoom_seconds)
        target = format_float(ZOOM_TEST_FACTOR)
        self.settings.run_action(["zoom", target], self._on_start_result)

    def start_filter_preview(self) -> None:
        """Preview the configured filter live, without saving anything.

        Returns:
            None.
        """
        if self.busy:
            return
        self._begin(MODE_FILTER, self.filter_seconds)
        overrides = [
            f"{FILTER_KEY}={self.settings.values[FILTER_KEY]}",
            f"{FILTER_ACTIVE_KEY}=on",
        ]
        self.settings.run_action(["preview", *overrides], self._on_start_result)

    def _begin(self, mode: str, seconds: int) -> None:
        """Enter a test mode and start the countdown.

        Args:
            mode: ``MODE_ZOOM`` or ``MODE_FILTER``.
            seconds: Countdown length.

        Returns:
            None.
        """
        # The countdown runs from the click on, so the UI answers immediately.
        self.mode = mode
        self.seconds_left = seconds
        self._timer_id = GLib.timeout_add(self.tick_milliseconds, self._on_tick)
        self.emit("changed")

    def _on_start_result(self, result) -> None:
        """Abort the test when zoomctl refused to start it.

        Args:
            result: CommandResult of the start command.

        Returns:
            None.
        """
        # Nothing was applied on failure, so there is nothing to restore; the error is a toast.
        if not result.ok and self.busy:
            self._end(restore=False)

    # ----- ending -------------------------------------------------------------------------

    def _on_tick(self) -> bool:
        """Advance the countdown by one second.

        Returns:
            True to keep the timer, False once the test ended.
        """
        self.seconds_left -= 1
        if self.seconds_left > 0:
            self.emit("changed")
            return GLib.SOURCE_CONTINUE
        # The timer source ends itself by returning False, so it is forgotten first.
        self._timer_id = 0
        self._end(restore=True)
        return GLib.SOURCE_REMOVE

    def stop(self) -> None:
        """End the running test early ("Stop" / "Revert") and restore the previous state.

        Returns:
            None.
        """
        # Stopping an idle controller is a no-op, so a double click is harmless.
        if self.busy:
            self._end(restore=True)

    def shutdown(self) -> None:
        """Restore immediately because the window is closing.

        Returns:
            None.
        """
        # Same as stop(); a separate name documents the intent at the call site.
        self.stop()

    def keep(self) -> None:
        """Make the previewed filter permanent ("Keep"), then drop the preview overrides.

        Returns:
            None.
        """
        if self.mode != MODE_FILTER:
            return
        self._cancel_timer()
        self.mode = MODE_IDLE
        self.emit("changed")
        # Preview ends only after the setting was saved; a failed save simply reverts it.
        self.settings.set_value(FILTER_ACTIVE_KEY, "on", self._on_keep_saved)

    def _on_keep_saved(self, saved: bool) -> None:
        """Drop the preview overrides once the filter setting is stored (or refused).

        Args:
            saved: Whether ``zoomctl set`` accepted the setting.

        Returns:
            None.
        """
        # The saved config now carries the filter, so ending the preview changes nothing visible.
        self.settings.run_action(["preview", "--end"])

    def _end(self, restore: bool) -> None:
        """Leave the current test mode and optionally restore the screen.

        Args:
            restore: True to undo the test (zoom back / end preview).

        Returns:
            None.
        """
        mode = self.mode
        self._cancel_timer()
        self.mode = MODE_IDLE
        self.seconds_left = 0
        if restore and mode == MODE_ZOOM:
            self.settings.run_action(["zoom", format_float(self._previous_zoom or FALLBACK_ZOOM)])
        elif restore and mode == MODE_FILTER:
            self.settings.run_action(["preview", "--end"])
        self.emit("changed")

    def _cancel_timer(self) -> None:
        """Stop the countdown timer if it is running.

        Returns:
            None.
        """
        # A zero id means the timer already ended itself.
        if self._timer_id:
            GLib.source_remove(self._timer_id)
            self._timer_id = 0
