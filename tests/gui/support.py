"""Shared helpers for the GUI test suites: import paths, the repo schema and the fake zoomctl.

The model tests need only the first two; the widget tests add the fake CLI and Broadway.
"""

# os/sys build the import path, pathlib reads files, json drives the fake CLI state.
import json
import os
import sys
from pathlib import Path
from typing import List, Optional

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
    # ZOOMCTL_SCHEMA tells the fake where the real schema is; the app reads it via the repo.
    return {
        "ZOOMCTL_BIN": str(FAKE_ZOOMCTL),
        "FAKE_ZOOMCTL_STATE": str(state_dir),
        "FAKE_ZOOMCTL_SCHEMA": str(SCHEMA_PATH),
        "FAKE_ZOOMCTL_PYTHON": os.path.realpath(sys.executable),
    }
