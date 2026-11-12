"""Settings controller: effective configuration, serialised ``zoomctl set`` queue, status.

The controller is the only object that talks to ``zoomctl`` for settings (contract E4: the GUI
changes settings only through ``zoomctl set``). Widgets listen to its signals and never keep
their own copy of the truth: a rejected change simply makes them re-read ``values``.
"""

# logging keeps bookkeeping notes out of the user's way; typing documents the queue shapes.
import logging
from typing import Callable, Dict, List, Optional, Tuple

import gi

gi.require_version("GObject", "2.0")
from gi.repository import GLib, GObject  # noqa: E402 - gi.require_version must run first

from .backend import CommandResult, ZoomctlClient  # noqa: E402
from .messages import friendly_notice  # noqa: E402
from .porcelain import EngineStatus, parse_key_values, parse_status  # noqa: E402
from .schema import SettingsSchema  # noqa: E402
from .values import ValueCheck, check_value, check_zoom_order  # noqa: E402

# Notes that are only bookkeeping (backups, paths) go to the log, not to a toast.
LOG = logging.getLogger(__name__)

# Called with True when a change was applied, False when it was rejected.
DoneCallback = Callable[[bool], None]
# One queued change: the canonical value and everybody waiting for the outcome.
_QueuedChange = Tuple[str, List[DoneCallback]]


class SettingsController(GObject.Object):
    """Holds the effective configuration and applies changes through zoomctl."""

    __gsignals__ = {
        # The effective configuration changed (or a change was rejected): re-read ``values``.
        "config-changed": (GObject.SignalFlags.RUN_FIRST, None, ()),
        # A new engine status arrived: re-read ``status``.
        "status-changed": (GObject.SignalFlags.RUN_FIRST, None, ()),
        # Something failed; arguments: a plain sentence for a toast and the technical details.
        "error": (GObject.SignalFlags.RUN_FIRST, None, (str, str)),
        # A call succeeded but zoomctl added a note (e.g. saved while the engine is offline).
        "info": (GObject.SignalFlags.RUN_FIRST, None, (str, str)),
    }

    def __init__(self, schema: SettingsSchema, client: ZoomctlClient) -> None:
        """Start with the schema defaults until the first refresh answers.

        Args:
            schema: Parsed settings schema.
            client: Asynchronous zoomctl client.

        Returns:
            None.
        """
        super().__init__()
        self.schema = schema
        self.client = client
        # Effective values by key; replaced wholesale by every successful config refresh.
        self.values: Dict[str, str] = schema.defaults()
        self.status = EngineStatus()
        # Why the status is unreachable (spawn error text), shown by the banner.
        self.status_problem = ""
        self._queue: Dict[str, _QueuedChange] = {}
        self._set_in_flight = False
        self._config_in_flight = False
        # In-flight flags make overlapping refreshes collapse into one.
        self._config_refresh_again = False
        self._status_in_flight = False
        # False until the first status answer arrived, so the banner does not flash at startup.
        self.status_received = False
        # Raw text of the last configuration answer: an unchanged answer redraws nothing.
        self._config_text: Optional[str] = None

    # ----- reading ------------------------------------------------------------------------

    def refresh_config(self) -> None:
        """Re-read the effective configuration (``config --porcelain``).

        Returns:
            None.
        """
        # A refresh requested while one runs is repeated afterwards so no change is missed.
        if self._config_in_flight:
            self._config_refresh_again = True
            return
        self._config_in_flight = True
        # The result arrives later on the main loop.
        self.client.run(["config", "--porcelain"], self._on_config_result)

    def _on_config_result(self, result: CommandResult) -> None:
        """Adopt a fresh configuration.

        Args:
            result: Result of ``config --porcelain``.

        Returns:
            None.
        """
        self._config_in_flight = False
        if result.ok:
            # Unknown keys are ignored: the schema decides which settings exist.
            reported = parse_key_values(result.stdout)
            known = {key: text for key, text in reported.items() if key in self.schema.by_key}
            self.values = {**self.values, **known}
            # The periodic re-read must not redraw (and disturb) the pages without news.
            if result.stdout != self._config_text:
                self._config_text = result.stdout
                self.emit("config-changed")
        else:
            # A failed read keeps the old values and tells the user.
            self._emit_problem(f"Could not read the configuration: {result.message}")
        # Run the deferred refresh, if one was requested in the meantime.
        if self._config_refresh_again:
            self._config_refresh_again = False
            self.refresh_config()

    def refresh_status(self) -> None:
        """Re-read the engine status (``status --porcelain``); overlapping calls are skipped.

        Returns:
            None.
        """
        # The 1 s status timer must never pile up processes behind a slow call.
        if self._status_in_flight:
            return
        self._status_in_flight = True
        self.client.run(["status", "--porcelain"], self._on_status_result)

    def _on_status_result(self, result: CommandResult) -> None:
        """Adopt a fresh status and tell the widgets if it changed.

        Args:
            result: Result of ``status --porcelain``.

        Returns:
            None.
        """
        self._status_in_flight = False
        # A failing zoomctl is shown as "unreachable", not as an error toast every second.
        status = parse_status(result.stdout) if result.ok else EngineStatus()
        problem = "" if result.ok else result.message
        first_answer = not self.status_received
        self.status_received = True
        # Only real changes (or the first answer) redraw the widgets.
        if first_answer or status != self.status or problem != self.status_problem:
            self.status = status
            self.status_problem = problem
            # Widgets and the banner react to this signal.
            self.emit("status-changed")

    # ----- writing ------------------------------------------------------------------------

    def set_value(self, key: str, text: str, on_done: Optional[DoneCallback] = None) -> ValueCheck:
        """Validate a change and queue ``zoomctl set``.

        Args:
            key: Schema key.
            text: Candidate value.
            on_done: Optional callback with True (applied) or False (rejected).

        Returns:
            The local validation verdict; when not ok nothing is sent and the widgets are
            told to re-read the effective value.
        """
        verdict = self._check_change(key, text)
        if not verdict.ok:
            # Invalid input never reaches zoomctl; widgets revert via the config-changed signal.
            self.emit("error", verdict.error, "")
            self.emit("config-changed")
            if on_done:
                self._call_later(on_done, False)
            # Callers use the verdict for immediate feedback.
            return verdict
        # A newer value for the same key replaces an older queued one but keeps its waiters.
        waiting = self._queue[key][1] if key in self._queue else []
        self._queue[key] = (verdict.canonical, waiting + ([on_done] if on_done else []))
        self._pump_queue()
        return verdict

    def _check_change(self, key: str, text: str) -> ValueCheck:
        """Validate one change on its own and against the settings it depends on.

        Args:
            key: Schema key.
            text: Candidate value.

        Returns:
            The verdict; ``error`` names the settings by their labels.
        """
        verdict = check_value(self.schema.by_key[key], text)
        if not verdict.ok:
            return verdict
        # Cross-field rules are checked here so the message uses labels, not key names.
        labels = {spec.key: spec.label for spec in self.schema.specs}
        conflict = check_zoom_order(labels, self.values, key, verdict.canonical)
        return ValueCheck(False, error=conflict) if conflict else verdict

    def _emit_problem(self, raw: str) -> None:
        """Report a failure as a plain sentence plus details.

        Args:
            raw: Raw zoomctl text.

        Returns:
            None.
        """
        # The mapping lives in one module so every failure reads the same way.
        notice = friendly_notice(raw)
        self.emit("error", notice.summary, notice.details if notice.details != notice.summary
                  else "")

    def _emit_note(self, raw: str) -> None:
        """Report a note of a successful call, or only log it when it is bookkeeping.

        Args:
            raw: Raw zoomctl text.

        Returns:
            None.
        """
        notice = friendly_notice(raw)
        # An empty summary marks notes the user does not need (backup paths and the like).
        if not notice.summary:
            LOG.info("zoomctl: %s", notice.details)
            return
        self.emit("info", notice.summary, notice.details)

    @staticmethod
    def _call_later(callback: DoneCallback, flag: bool) -> None:
        """Call a callback from the main loop instead of inside the current call.

        Args:
            callback: Callback to invoke.
            flag: Argument for the callback.

        Returns:
            None.
        """
        # Callers rely on "never called synchronously", like the client's own callbacks.
        def invoke() -> bool:
            """Run the callback once.

            Returns:
                False so the idle source is removed.
            """
            # The return value removes the idle source after one run.
            callback(flag)
            return GLib.SOURCE_REMOVE

        GLib.idle_add(invoke)

    def _pump_queue(self) -> None:
        """Send the next queued change if none is in flight.

        Returns:
            None.
        """
        # Changes are applied strictly one after another (the CLI rewrites one config file).
        if self._set_in_flight or not self._queue:
            return
        key = next(iter(self._queue))
        value, waiting = self._queue.pop(key)
        # No second set starts until this one has finished.
        self._set_in_flight = True
        self.client.run(
            ["set", key, value], lambda result: self._on_set_result(key, value, waiting, result)
        )

    def _on_set_result(
        self, key: str, value: str, waiting: List[DoneCallback], result: CommandResult
    ) -> None:
        """Finish one change: remember it or reject it, then continue with the queue.

        Args:
            key: Schema key that was set.
            value: Canonical value that was sent.
            waiting: Callbacks to inform.
            result: Result of ``set``.

        Returns:
            None.
        """
        self._set_in_flight = False
        if result.ok:
            self.values[key] = value
            # An offline engine still saves the value, but zoomctl explains it on stderr.
            self._report_note(result)
        else:
            # The first stderr line of zoomctl becomes the toast, in plain words.
            self._emit_problem(result.message)
        # Success updates dependent widgets; failure makes them revert to the old value.
        self.emit("config-changed")
        for callback in waiting:
            callback(result.ok)
        if self._queue:
            self._pump_queue()
        else:
            # Re-reading picks up values zoomctl changed implicitly and repairs any drift.
            self.refresh_config()

    # ----- other actions ----------------------------------------------------------------

    def run_action(
        self, arguments: List[str], on_done: Optional[Callable[[CommandResult], None]] = None
    ) -> None:
        """Run a zoomctl command, report a failure as an error and always call back.

        Args:
            arguments: zoomctl arguments, e.g. ``["zoom", "2.00"]``.
            on_done: Optional callback with the CommandResult.

        Returns:
            None.
        """
        def finished(result: CommandResult) -> None:
            """Report failures once, then hand the result to the caller.

            Args:
                result: Result of the command.

            Returns:
                None.
            """
            # Every caller gets the same error reporting without repeating it.
            if not result.ok:
                self._emit_problem(result.message)
            self._report_note(result)
            if on_done:
                # The caller sees the result after the user has been told about it.
                on_done(result)

        # The wrapper reports errors once and then calls the caller back.
        self.client.run(arguments, finished)

    def _report_note(self, result: CommandResult) -> None:
        """Forward a stderr note of a successful call as an info message.

        Args:
            result: Result of a zoomctl call.

        Returns:
            None.
        """
        # Only notes of successful calls are info; failures are reported as errors elsewhere.
        if result.info_message:
            self._emit_note(result.info_message)

    def reset_config(self, on_done: Optional[DoneCallback] = None) -> None:
        """Delete all user overrides (``zoomctl reset-config``) and reload the values.

        Args:
            on_done: Optional callback with the success flag.

        Returns:
            None.
        """
        def finished(result: CommandResult) -> None:
            """Reload values after the reset.

            Args:
                result: Result of ``reset-config``.

            Returns:
                None.
            """
            # Reloading is needed even on failure: a partial reset may have changed files.
            self.refresh_config()
            if on_done:
                on_done(result.ok)

        self.run_action(["reset-config"], finished)

    def run_setup(self, on_done: Optional[DoneCallback] = None) -> None:
        """Wire the engine into the Hyprland config (``zoomctl setup``) and refresh.

        Args:
            on_done: Optional callback with the success flag.

        Returns:
            None.
        """
        def finished(result: CommandResult) -> None:
            """Refresh status and values after the setup attempt.

            Args:
                result: Result of ``setup``.

            Returns:
                None.
            """
            # The engine may need a moment to load, so the regular status timer follows up.
            self.refresh_status()
            self.refresh_config()
            if on_done:
                on_done(result.ok)

        # Setup reuses the shared error reporting of run_action.
        self.run_action(["setup"], finished)
