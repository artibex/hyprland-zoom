"""The "Try it" state machine: a timed zoom test and a timed filter preview with Keep/Revert.

Both tests change the live screen, so the first rule is that they always end: a countdown
restores the previous state, "Stop"/"Revert" does it early and closing the window does it
immediately (``shutdown``).
"""

# typing documents the optional previous zoom.
from typing import Callable, List, Optional

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
        # Both durations are read by the bar to label its buttons.
        self.filter_seconds = filter_seconds
        self.tick_milliseconds = tick_milliseconds
        # Public state read by the widgets.
        self.mode = MODE_IDLE
        self.seconds_left = 0
        self._previous_zoom: Optional[float] = None
        self._timer_id = 0
        # Commands run strictly one after another so a quick Stop cannot overtake the start.
        self._steps: List[Callable[[Callable[[], None]], None]] = []
        self._step_running = False

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
        self._enqueue_command(["zoom", format_float(ZOOM_TEST_FACTOR)], self._on_start_result)

    def start_filter_preview(self) -> None:
        """Preview the configured filter live, without saving anything.

        Returns:
            None.
        """
        if self.busy:
            return
        self._begin(MODE_FILTER, self.filter_seconds)
        # The preview forces the configured filter on without saving anything.
        overrides = [
            f"{FILTER_KEY}={self.settings.values[FILTER_KEY]}",
            f"{FILTER_ACTIVE_KEY}=on",
        ]
        self._enqueue_command(["preview", *overrides], self._on_start_result)

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
            # Keeping the source alive makes the next tick arrive.
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
        # The mode flips first so a re-entrant call sees an idle controller.
        self.mode = MODE_IDLE
        self.emit("changed")
        # The preview ends only after the setting was saved; a refused save simply reverts it.
        self._enqueue(lambda done: self.settings.set_value(
            FILTER_ACTIVE_KEY, "on", lambda _saved: done()))
        self._enqueue_command(["preview", "--end"])

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
        # The countdown text disappears with the mode.
        self.seconds_left = 0
        if restore and mode == MODE_ZOOM:
            self._enqueue_command(["zoom", format_float(self._previous_zoom or FALLBACK_ZOOM)])
        # Ending a preview drops its overrides; the saved config shows again.
        elif restore and mode == MODE_FILTER:
            self._enqueue_command(["preview", "--end"])
        self.emit("changed")

    # ----- ordered command execution ------------------------------------------------------

    def _enqueue(self, step: Callable[[Callable[[], None]], None]) -> None:
        """Queue a step; it starts when all earlier steps have finished.

        Args:
            step: Callable that receives a ``done`` callback and must call it exactly once.

        Returns:
            None.
        """
        self._steps.append(step)
        self._advance()

    def _enqueue_command(self, arguments: List[str], on_result=None) -> None:
        """Queue one zoomctl command.

        Args:
            arguments: zoomctl arguments.
            on_result: Optional callback with the CommandResult.

        Returns:
            None.
        """
        def step(done: Callable[[], None]) -> None:
            """Run the command and signal completion.

            Args:
                done: Callback that releases the queue.

            Returns:
                None.
            """
            def finished(result) -> None:
                """Hand the result on, then release the queue.

                Args:
                    result: CommandResult of the command.

                Returns:
                    None.
                """
                # The queue advances even when the callback raises, so it can never stall.
                try:
                    if on_result:
                        on_result(result)
                finally:
                    done()

            # run_action reports a failure once and then calls finished.
            self.settings.run_action(arguments, finished)

        self._enqueue(step)

    def _advance(self) -> None:
        """Start the next queued step unless one is running.

        Returns:
            None.
        """
        if self._step_running or not self._steps:
            return
        self._step_running = True
        # The step calls _step_finished exactly once when it is done.
        self._steps.pop(0)(self._step_finished)

    def _step_finished(self) -> None:
        """Release the queue after a step and continue with the next one.

        Returns:
            None.
        """
        self._step_running = False
        self._advance()

    def _cancel_timer(self) -> None:
        """Stop the countdown timer if it is running.

        Returns:
            None.
        """
        # A zero id means the timer already ended itself.
        if self._timer_id:
            GLib.source_remove(self._timer_id)
            self._timer_id = 0
