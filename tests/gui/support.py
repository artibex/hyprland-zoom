"""Shared helpers for the GUI test suites: import paths, the repo schema and the fake zoomctl.

The model tests need only the first two; the widget tests add the fake CLI and Broadway.
"""

# fcntl waits for running fakes at cleanup; json drives the fake CLI state.
import fcntl
import json
# os/sys build the import path, pathlib reads files.
import os
import shutil
import socket
# subprocess starts the Broadway daemon, tempfile makes the scratch dirs.
import subprocess
import sys
import tempfile
# time paces the polling loops and the daemon start-up.
import time
import unittest
import warnings
# Path is the file type of the state directory helpers.
from pathlib import Path
from typing import Callable, List, Optional
from unittest import mock



def silence_gi_warnings() -> None:
    """Hide the upstream deprecation noise of PyGObject's event-loop shim.

    PyGObject's shim (gi/events.py) trips a Python 3.14 deprecation on every main-loop turn.
    unittest installs its own warning filters when a run starts, so this must be called from
    inside the run (module and test set-up), not only at import time.

    Returns:
        None.
    """
    # The module regex keeps every other deprecation warning visible.
    warnings.filterwarnings("ignore", category=DeprecationWarning, module=r"gi\.events")


silence_gi_warnings()

# Seconds a test may wait for an asynchronous reaction before it counts as failed.
WAIT_SECONDS = 8.0

# Repository root and the directory that holds the settings package.
REPO_ROOT = Path(__file__).resolve().parents[2]
UI_SOURCE_DIR = REPO_ROOT / "src" / "ui"
SCHEMA_PATH = REPO_ROOT / "config" / "settings.schema"
FAKE_ZOOMCTL = Path(__file__).resolve().parent / "fixtures" / "fake-zoomctl"

# Make `import hyprland_zoom_settings` work from a plain checkout.
if str(UI_SOURCE_DIR) not in sys.path:
    sys.path.insert(0, str(UI_SOURCE_DIR))


def read_schema_text() -> str:
    """Read the real schema file of the checkout.

    Returns:
        The schema text.
    """
    # Tests run against the contract schema, so a schema change shows up immediately.
    return SCHEMA_PATH.read_text(encoding="utf-8")


class FakeZoomctl:
    """Handle on the state directory of the fake zoomctl executable."""

    def __init__(self, state_dir: Path) -> None:
        """Prepare an empty state directory.

        Args:
            state_dir: Directory the fake reads and writes.

        Returns:
            None.
        """
        # The fake locates its state through the FAKE_ZOOMCTL_STATE environment variable.
        self.state_dir = state_dir
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.calls_file = state_dir / "calls.jsonl"
        self.overrides_file = state_dir / "overrides.json"
        # An empty list means: no canned answers, built-in behaviour only.
        self.overrides_file.write_text("[]", encoding="utf-8")

    def respond(self, *prefix: str, **fields) -> None:
        """Override the answer for calls whose argv starts with a prefix.

        Args:
            prefix: Leading argv words to match (longest prefix wins).
            fields: ``stdout``, ``stderr``, ``rc``, ``sleep`` of the canned answer.

        Returns:
            None.
        """
        # Overrides are appended; the fake picks the longest matching prefix.
        entries = json.loads(self.overrides_file.read_text(encoding="utf-8"))
        entries.append({"match": list(prefix), **fields})
        self.overrides_file.write_text(json.dumps(entries), encoding="utf-8")

    def calls(self) -> List[List[str]]:
        """List every recorded invocation.

        Returns:
            One argv list (without the program name) per call, oldest first.
        """
        # The log does not exist before the first call.
        if not self.calls_file.exists():
            return []
        lines = self.calls_file.read_text(encoding="utf-8").splitlines()
        return [json.loads(line) for line in lines if line.strip()]

    def calls_matching(self, *prefix: str) -> List[List[str]]:
        """Filter recorded calls by argv prefix.

        Args:
            prefix: Leading argv words.

        Returns:
            The matching calls.
        """
        # Prefix comparison mirrors how the fake matches overrides.
        return [call for call in self.calls() if call[: len(prefix)] == list(prefix)]

    def clear_calls(self) -> None:
        """Forget all recorded calls.

        Returns:
            None.
        """
        # Tests clear the log after the initial refresh to assert only their own calls.
        self.calls_file.write_text("", encoding="utf-8")

    def set_status(self, **fields: str) -> None:
        """Change status fields the fake reports from now on.

        Args:
            fields: Porcelain keys to override, e.g. ``engine="missing"``.

        Returns:
            None.
        """
        # The status file is a JSON object merged over the fake's built-in status.
        path = self.state_dir / "status.json"
        current = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        current.update(fields)
        path.write_text(json.dumps(current), encoding="utf-8")

    def config_value(self, key: str) -> Optional[str]:
        """Read a value the fake stored through ``set``.

        Args:
            key: Schema key.

        Returns:
            The stored text, or None when never set.
        """
        # The fake persists user overrides in config.json.
        path = self.state_dir / "config.json"
        if not path.exists():
            return None
        return json.loads(path.read_text(encoding="utf-8")).get(key)


def environment_for_fake(state_dir: Path) -> dict:
    """Build the environment that makes the settings app use the fake zoomctl.

    Args:
        state_dir: The fake's state directory.

    Returns:
        Variables to set (``ZOOMCTL_BIN``, ``FAKE_ZOOMCTL_STATE``, schema location).
    """
    # The fake reads defaults and key order from the real schema file.
    return {
        "ZOOMCTL_BIN": str(FAKE_ZOOMCTL),
        "FAKE_ZOOMCTL_STATE": str(state_dir),
        "FAKE_ZOOMCTL_SCHEMA": str(SCHEMA_PATH),
    }


def pump(condition: Callable[[], bool], timeout: float = WAIT_SECONDS) -> None:
    """Run the default GLib main loop until a condition holds.

    Args:
        condition: Callable returning a truthy value when the wait is over.
        timeout: Seconds before the wait fails the test.

    Returns:
        None.
    """
    from gi.repository import GLib

    context = GLib.MainContext.default()
    deadline = time.monotonic() + timeout
    # Iterating the context delivers subprocess results, timers and idle callbacks.
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("timed out waiting for the GUI")
        context.iteration(False)
        # A short sleep keeps the polling loop from burning a CPU core.
        time.sleep(0.003)


def pump_for(seconds: float) -> None:
    """Run the main loop for a fixed time.

    Args:
        seconds: Duration to keep iterating.

    Returns:
        None.
    """
    deadline = time.monotonic() + seconds
    # A condition that only turns true at the deadline makes pump a timed loop.
    pump(lambda: time.monotonic() > deadline, timeout=seconds + 2)


def wait_for_fake_processes(state_dir: Path, timeout: float = WAIT_SECONDS) -> None:
    """Wait until no fake zoomctl of a test is still running.

    Args:
        state_dir: The fake's state directory (holds ``busy.lock``).
        timeout: Seconds before giving up; cleanup then proceeds anyway.

    Returns:
        None.
    """
    # Without any call there is no lock file and nothing to wait for.
    lock_path = Path(state_dir) / "busy.lock"
    if not lock_path.exists():
        return
    deadline = time.monotonic() + timeout
    with open(lock_path, "a", encoding="utf-8") as lock_file:
        # Each running fake holds a shared lock; an exclusive one succeeds once all exited.
        while time.monotonic() < deadline:
            try:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                # A fake may wait on its pipe being read, so keep the main loop turning.
                pump_for(0.02)


class FakeZoomctlTestCase(unittest.TestCase):
    """Base class: every test gets its own fake zoomctl state and a patched environment."""

    def setUp(self) -> None:
        """Create the state directory and point the environment at the fake.

        Returns:
            None.
        """
        silence_gi_warnings()
        # A private temp dir per test keeps call logs and stored settings isolated.
        scratch = tempfile.TemporaryDirectory(prefix="hzoom-gui-")
        self.addCleanup(scratch.cleanup)
        self.fake = FakeZoomctl(Path(scratch.name) / "state")
        # Cleanups run last-in first-out: stragglers finish before the directory goes.
        self.addCleanup(wait_for_fake_processes, self.fake.state_dir)
        # patch.dict restores the real environment after the test.
        patcher = mock.patch.dict(os.environ, environment_for_fake(self.fake.state_dir))
        patcher.start()
        self.addCleanup(patcher.stop)

    def wait_for_calls(self, *prefix: str, count: int = 1) -> None:
        """Wait until the fake saw enough calls that start with a prefix.

        Args:
            prefix: Leading argv words.
            count: Number of matching calls to wait for.

        Returns:
            None.
        """
        # Subprocess results arrive through the main loop, so the loop must keep running.
        pump(lambda: len(self.fake.calls_matching(*prefix)) >= count)


class BroadwayDisplay:
    """A private Broadway (GTK4 in a browser protocol) display, never the live desktop."""

    def __init__(self) -> None:
        """Prepare an unstarted display.

        Returns:
            None.
        """
        self.daemon: Optional[subprocess.Popen] = None
        self.name = ""
        self._sockets_before: set = set()
        # Set when the environment has no runtime dir (minimal CI containers).
        self._private_runtime_dir: Optional[str] = None

    @staticmethod
    def _runtime_dir() -> str:
        """Find the directory where Broadway keeps its sockets.

        Returns:
            The runtime directory path.
        """
        # Broadway uses XDG_RUNTIME_DIR; /tmp is the fallback for minimal CI containers.
        return os.environ.get("XDG_RUNTIME_DIR", "/tmp")

    def _ensure_runtime_dir(self) -> None:
        """Create a private runtime directory when the environment has none.

        Returns:
            None.
        """
        # GLib would otherwise fall back to a cache directory for the Broadway sockets.
        if os.environ.get("XDG_RUNTIME_DIR"):
            return
        self._private_runtime_dir = tempfile.mkdtemp(prefix="hzoom-runtime-")
        os.chmod(self._private_runtime_dir, 0o700)
        # Exporting it lets the daemon and GTK agree on one runtime directory.
        os.environ["XDG_RUNTIME_DIR"] = self._private_runtime_dir

    def _free_display_number(self) -> int:
        """Find a display number whose HTTP port and socket are unused.

        Returns:
            A free Broadway display number.
        """
        for number in range(61, 120):
            # Broadway listens on 8080 + n; a bind test proves the port is free.
            probe = socket.socket()
            try:
                probe.bind(("127.0.0.1", 8080 + number))
            except OSError:
                continue
            finally:
                # Releasing the probe port lets the daemon bind it right after.
                probe.close()
            socket_name = f"broadway{number + 1}.socket"
            if not os.path.exists(os.path.join(self._runtime_dir(), socket_name)):
                # The first free display number is used.
                return number
        raise unittest.SkipTest("no free Broadway display number")

    def start(self) -> None:
        """Start gtk4-broadwayd and point GTK at it.

        Returns:
            None.
        """
        binary = shutil.which("gtk4-broadwayd")
        if binary is None:
            raise unittest.SkipTest("gtk4-broadwayd is not installed")
        # Broadway sockets live in the runtime directory, so it must exist first.
        self._ensure_runtime_dir()
        # Remembering the old sockets protects other users' displays on cleanup.
        self._sockets_before = {
            name for name in os.listdir(self._runtime_dir()) if name.startswith("broadway")
        }
        self.name = f":{self._free_display_number()}"
        self.daemon = subprocess.Popen(
            [binary, self.name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        # Removing the Wayland/X11 variables guarantees GTK cannot fall back to the real desktop.
        for variable in ("WAYLAND_DISPLAY", "DISPLAY"):
            os.environ.pop(variable, None)
        os.environ["GDK_BACKEND"] = "broadway"
        os.environ["BROADWAY_DISPLAY"] = self.name
        # The daemon needs a moment to create its socket before GTK connects.
        time.sleep(0.6)

    def stop(self) -> None:
        """Stop the daemon and delete only the sockets this run created.

        Returns:
            None.
        """
        if self.daemon is None:
            return
        self.daemon.terminate()
        # Waiting for the exit makes sure the socket files are really gone.
        self.daemon.wait(timeout=5)
        for name in os.listdir(self._runtime_dir()):
            if name.startswith("broadway") and name not in self._sockets_before:
                # Only sockets created by this run are removed, never somebody else's.
                os.remove(os.path.join(self._runtime_dir(), name))
        # A runtime directory this class created is removed with everything in it.
        if self._private_runtime_dir:
            shutil.rmtree(self._private_runtime_dir, ignore_errors=True)
