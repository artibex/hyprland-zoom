"""Asynchronous ``zoomctl`` client: every call runs through ``Gio.Subprocess``, never blocking.

Results are delivered to a callback on the GLib main loop, so widgets can be touched directly
from it. A call that outlives its timeout is killed and reported as an error.
"""

# dataclasses carry results; typing documents the callback shape.
from dataclasses import dataclass
from typing import Callable, List

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402 - gi.require_version must run first

from .constants import COMMAND_TIMEOUT_SECONDS  # noqa: E402

# Exit status reported when the process did not exit normally (killed, not started).
NO_EXIT_STATUS = -1


@dataclass(frozen=True)
class CommandResult:
    """Outcome of one zoomctl invocation.

    Attributes:
        arguments: Arguments that were passed (without the program).
        exit_status: Process exit status, ``NO_EXIT_STATUS`` when it never exited normally.
        stdout: Captured standard output.
        stderr: Captured standard error.
        failure: Reason the process could not run or was killed (empty when it ran).
    """

    arguments: List[str]
    exit_status: int = 0
    stdout: str = ""
    # stderr and failure complete the record of one call.
    stderr: str = ""
    failure: str = ""

    @property
    def ok(self) -> bool:
        """Tell whether the command ran and exited with 0.

        Returns:
            True on success.
        """
        # A failure to spawn or a kill always counts as failed, whatever the status says.
        return not self.failure and self.exit_status == 0

    @property
    def info_message(self) -> str:
        """Pick a note zoomctl printed although it succeeded.

        Returns:
            The first non-empty stderr line of a successful call (for example "engine not
            reachable, saved only"); empty when the call failed or printed nothing.
        """
        # zoomctl exits 0 with a stderr note when it only saved a setting: info, not an error.
        if not self.ok:
            return ""
        return next((line.strip() for line in self.stderr.splitlines() if line.strip()), "")

    @property
    def message(self) -> str:
        """Pick the text to show a user when the command failed.

        Returns:
            The first non-empty stderr line, else the failure reason, else a generic text.
        """
        # zoomctl prints its error on stderr; the first line is the actionable one.
        for line in self.stderr.splitlines():
            if line.strip():
                return line.strip()
        return self.failure or f"zoomctl {' '.join(self.arguments)} failed"


# Every asynchronous call reports through a callback of this shape.
ResultCallback = Callable[[CommandResult], None]


class _PendingCall:
    """Bookkeeping of one running command: its process, callback and kill timer."""

    def __init__(
        self, process: Gio.Subprocess, arguments: List[str], callback: ResultCallback,
        timeout_seconds: int,
    ) -> None:
        """Start the kill timer and remember the call.

        Args:
            process: The running subprocess.
            arguments: zoomctl arguments of the call.
            callback: Result callback.
            timeout_seconds: Kill the process after this many seconds.

        Returns:
            None.
        """
        # The timer is cancelled in finish(); timed_out records whether it fired first.
        self.process = process
        self.arguments = arguments
        self.callback = callback
        self.timeout_seconds = timeout_seconds
        # The flag tells finish() whether the kill timer fired first.
        self.timed_out = False
        self.timer_id = GLib.timeout_add_seconds(timeout_seconds, self._on_timeout)

    def _on_timeout(self) -> bool:
        """Kill the process because it ran too long.

        Returns:
            False so the timer fires only once.
        """
        # force_exit makes communicate finish, which then reports the timeout.
        self.timed_out = True
        self.timer_id = 0
        self.process.force_exit()
        return GLib.SOURCE_REMOVE

    def finish(self, task: Gio.AsyncResult) -> None:
        """Collect the output and call the callback.

        Args:
            task: Async result of ``communicate_utf8_async``.

        Returns:
            None.
        """
        # A timer that has not fired yet must not outlive the call.
        if self.timer_id:
            GLib.source_remove(self.timer_id)
        try:
            _, stdout, stderr = self.process.communicate_utf8_finish(task)
        except GLib.Error as error:
            # A broken pipe is reported like any other failure, never raised.
            self.callback(CommandResult(self.arguments, NO_EXIT_STATUS, failure=error.message))
            return
        # A killed or signalled process has no meaningful exit status.
        exited = self.process.get_if_exited()
        status = self.process.get_exit_status() if exited else NO_EXIT_STATUS
        failure = f"zoomctl timed out after {self.timeout_seconds} s" if self.timed_out else ""
        self.callback(CommandResult(self.arguments, status, stdout or "", stderr or "", failure))


class ZoomctlClient:
    """Runs zoomctl commands asynchronously."""

    def __init__(self, binary: str, timeout_seconds: int = COMMAND_TIMEOUT_SECONDS) -> None:
        """Remember which executable to run.

        Args:
            binary: Path or command name of zoomctl.
            timeout_seconds: Kill a call that takes longer than this.

        Returns:
            None.
        """
        # Both values are fixed for the lifetime of the client.
        self.binary = binary
        self.timeout_seconds = timeout_seconds

    def run(self, arguments: List[str], callback: ResultCallback) -> None:
        """Start a command and deliver its result later.

        Args:
            arguments: zoomctl arguments (each one a separate argv entry, never shell text).
            callback: Called once on the main loop with the CommandResult.

        Returns:
            None.
        """
        argv = [self.binary, *arguments]
        flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
        try:
            process = Gio.Subprocess.new(argv, flags)
        except GLib.Error as error:
            # Spawn failures (missing binary, no permission) are reported like any failure.
            failure = f"Could not run '{self.binary}': {error.message}"
            GLib.idle_add(self._deliver_failure, callback, arguments, failure)
            return
        pending = _PendingCall(process, arguments, callback, self.timeout_seconds)
        # The lambda ignores the source object and finishes the call.
        process.communicate_utf8_async(None, None, lambda _process, task: pending.finish(task))

    @staticmethod
    def _deliver_failure(callback: ResultCallback, arguments: List[str], failure: str) -> bool:
        """Report a spawn failure from an idle callback.

        Args:
            callback: Result callback.
            arguments: Arguments of the failed call.
            failure: Reason text.

        Returns:
            False so the idle source is removed.
        """
        # Delivering asynchronously keeps the contract "callback never runs inside run()".
        callback(CommandResult(arguments, NO_EXIT_STATUS, failure=failure))
        return GLib.SOURCE_REMOVE
