#!/usr/bin/env python3
"""Validates hyprpm.toml the way hyprpm's manifest parser (v0.56) would read it.

hyprpm reads the file with toml++ and silently marks the manifest "corrupted" on a bad plugin
name, an empty `output` or an empty `build` array. This test repeats those rules with the
stdlib TOML parser and cross-checks the manifest against plugin/Makefile and the commit pins.

Usage: tests/plugin/manifest_test.py   (exit 0 = valid)
"""
import re
import sys
import tomllib  # stdlib since Python 3.11, so no third-party TOML parser is needed
import unittest
from pathlib import Path

# Repository root, derived from this file so the test runs from any directory.
REPO_ROOT = Path(__file__).resolve().parents[2]
# Characters hyprpm accepts in a plugin name (Manifest.cpp validManifestName).
VALID_NAME = re.compile(r"^[A-Za-z0-9_=-]+$")
# hyprpm only runs `git reset --hard '<pin>'` after isValidHash(): hex digits only.
HEX_HASH = re.compile(r"^[0-9a-f]{7,40}$")


def load_manifest() -> dict:
    """Parses hyprpm.toml.

    Returns:
        The parsed TOML document.
    """
    with open(REPO_ROOT / "hyprpm.toml", "rb") as manifest_file:
        return tomllib.load(manifest_file)


class ManifestTest(unittest.TestCase):
    """Checks every rule hyprpm applies to a manifest."""

    def setUp(self) -> None:
        """Loads the manifest once per test."""
        self.manifest = load_manifest()

    def plugin_sections(self) -> dict:
        """Returns every top-level table except [repository] (hyprpm treats them as plugins)."""
        return {name: body for name, body in self.manifest.items() if name != "repository"}

    def test_plugin_hyprzoom_is_declared(self) -> None:
        """The plugin the docs tell users to enable must exist."""
        self.assertIn("hyprzoom", self.plugin_sections())

    def test_plugin_names_are_valid(self) -> None:
        """A name with a forbidden character makes hyprpm reject the whole manifest."""
        for name in self.plugin_sections():
            self.assertRegex(name, VALID_NAME)

    def test_output_and_build_are_present(self) -> None:
        """hyprpm treats an empty output or build list as a corrupted manifest."""
        for name, body in self.plugin_sections().items():
            # Both keys must be non-empty or hyprpm refuses the whole repository.
            self.assertTrue(body.get("output"), f"{name}: output missing")
            self.assertTrue(body.get("build"), f"{name}: build steps missing")
            # A non-string step would make hyprpm substitute "?" and run a bogus command.
            self.assertTrue(all(isinstance(step, str) for step in body["build"]))

    def test_output_matches_the_makefile_target(self) -> None:
        """The manifest must point at the file `make -C plugin` really produces."""
        makefile = (REPO_ROOT / "plugin" / "Makefile").read_text()
        target = Path(self.manifest["hyprzoom"]["output"]).name
        # A rule line `hyprzoom.so:` at the start of a line proves the target exists.
        self.assertRegex(makefile, re.compile(rf"^{re.escape(target)}:", re.MULTILINE),
                         "Makefile has no such target")
        # The directory part must be the plugin folder, where `make -C plugin` writes it.
        self.assertEqual(Path(self.manifest["hyprzoom"]["output"]).parent.as_posix(), "plugin")

    def test_build_steps_only_call_make_in_plugin_dir(self) -> None:
        """Build steps run through a shell: keep them to the documented, reviewable commands."""
        for step in self.manifest["hyprzoom"]["build"]:
            self.assertRegex(step, r"^make -C plugin( clean)?$")

    def test_commit_pins_are_well_formed(self) -> None:
        """Each pin is [hyprland hash, plugin commit]; hyprpm aborts on a malformed commit."""
        for pin in self.manifest["repository"].get("commit_pins", []):
            # hyprpm compares the first entry with the full hash Hyprland reports.
            self.assertEqual(len(pin), 2)
            self.assertRegex(pin[0], r"^[0-9a-f]{40}$", "Hyprland hash must be the full hash")
            # The second entry ends up inside a shell command, hence the strict hex check.
            self.assertRegex(pin[1], HEX_HASH)


if __name__ == "__main__":
    # Exit code 0 only when every test passed, for use from run.sh.
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
