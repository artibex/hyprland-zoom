#!/usr/bin/env python3
"""Live test of the hyprzoom plugin inside a NESTED Hyprland (never the user's session).

What it proves, against the real compositor:
  * the plugin loads through `hl.plugin.load` and its config values map to the Lua config;
  * for margins 0.05 / 0.25 / 0.40 the camera measured from screenshots equals the prediction
    of plugin/camera_math.hpp (tool: tests/plugin/camera_predict.cpp);
  * `enabled=false` and unloading the plugin restore Hyprland's native camera;
  * adding a monitor while zoomed and `hyprctl reload` do not break anything;
  * a plugin build that cannot find its symbol refuses to load instead of hooking blindly.

Safety: everything goes through tests/integration/nested-hyprland.sh, which talks to the
nested instance only. The test refuses to run unless HYPRZOOM_TEST_NESTED_OK=1 is set,
because a nested window briefly appears in the parent session.

Usage: HYPRZOOM_TEST_NESTED_OK=1 tests/plugin/nested_test.py [--work-dir DIR]
Exit:  0 all checks passed; 1 a check failed; 77 prerequisites missing (skipped).
"""

# Standard library only: the test must run on a bare CI image.
import argparse
import os
import shutil

# Process control and scratch space for the nested instance.
import subprocess
import sys
import tempfile

# Waiting for frames and paths for the repository layout.
import time
from pathlib import Path

# The PNG helper lives next to this file; make it importable however the script is started.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import png_probe  # needs the sys.path entry above

# Repository layout the test relies on.
REPO_ROOT = Path(__file__).resolve().parents[2]
NESTED_SCRIPT = REPO_ROOT / "tests" / "integration" / "nested-hyprland.sh"
PLUGIN_SO = REPO_ROOT / "plugin" / "hyprzoom.so"
# Output geometry of the virtual monitor and the zoom level under test.
WIDTH, HEIGHT = 1280, 720
ZOOM = 2.0
# Margins under test; 0.05 is the native behaviour, the others need the plugin.
MARGINS = (0.05, 0.25, 0.40)
# Zoom-in point and the pointer path afterwards: pan right/down, then left/up (monitor pixels).
ANCHOR = (640, 360)
POINTER_PATH = ((1000, 560), (300, 150))
# Allowed difference between measured and predicted camera: gradient step plus pointer rounding.
TOLERANCE_PX = 6.0
# Hyprland needs this long to finish the zoom animation (speed 3) before a measurement.
ZOOM_SETTLE_SECONDS = 1.8
# Lua of the nested instance: virtual monitor, plugin via hl.plugin.load, detached-camera zoom.
NESTED_CONFIG = """\
hl.monitor({{ output = "HEADLESS-1", mode = "{width}x{height}@60", position = "0x0", scale = 1 }})
hl.plugin.load("{plugin}")
hl.config({{
  misc = {{ disable_hyprland_logo = true, force_default_wallpaper = 0,
           background_color = "0x000000" }},
  cursor = {{ zoom_factor = 1.0, zoom_rigid = false, zoom_detached_camera = true }},
  plugin = {{ hyprzoom = {{ edge_margin = 0.05 }} }},
}})
-- The zoom animation must stay enabled, otherwise Hyprland reuses a stale camera (E9).
hl.animation({{ leaf = "zoomFactor", enabled = true, speed = 3, bezier = "default" }})
"""


class Nested:
    """Thin wrapper around tests/integration/nested-hyprland.sh for one nested instance."""

    def __init__(self, work_dir: Path) -> None:
        """Prepares the environment of every harness call.

        Args:
            work_dir: Scratch directory for config, screenshots and nested state.
        """
        self.work_dir = work_dir
        # The state dir is passed per call (never exported), as the harness requires.
        self.env = dict(os.environ, NESTED_STATE_DIR=str(work_dir / "nested"))

    def harness(self, *args: str) -> str:
        """Runs the harness script and returns its output.

        Args:
            *args: Harness sub-command and arguments.

        Returns:
            Stripped stdout (plus stderr when the script failed).
        """
        # The timeout keeps a hung hyprctl from blocking the whole run.
        result = subprocess.run(
            [str(NESTED_SCRIPT), *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=90,
            check=False,
        )
        # On failure the error text is the interesting part (e.g. why a plugin was refused).
        text = result.stdout + result.stderr if result.returncode else result.stdout
        return text.strip()

    def ctl(self, *args: str) -> str:
        """Runs hyprctl against the nested instance.

        Args:
            *args: hyprctl arguments.

        Returns:
            hyprctl output.
        """
        return self.harness("ctl", *args)

    def lua(self, code: str) -> str:
        """Evaluates Lua in the nested compositor (errors come back as text).

        Args:
            code: Lua source.

        Returns:
            hyprctl eval output ("ok" on success).
        """
        return self.ctl("eval", code)

    def query(self, expression: str) -> str:
        """Evaluates a Lua expression and returns its value (hyprctl repl).

        Args:
            expression: Lua expression, e.g. `1 + 1`.

        Returns:
            The printed value.
        """
        return self.ctl("repl", f"return {expression}")

    def move_pointer(self, x: int, y: int, settle: float = 0.4) -> None:
        """Warps the nested pointer and waits for a frame.

        Args:
            x: Layout x coordinate.
            y: Layout y coordinate.
            settle: Seconds to wait so the frame with the new camera is rendered.
        """
        # Absolute warp through the Lua dispatcher (verified in the S1 spike).
        self.ctl("dispatch", f"hl.dsp.cursor.move({{x={x},y={y}}})")
        time.sleep(settle)

    def alive(self) -> bool:
        """Tells whether the nested compositor still answers.

        Returns:
            True when `hyprctl version` works.
        """
        return "Hyprland" in self.ctl("version")

    def camera(self) -> tuple | None:
        """Measures the camera top-left from a screenshot of the gradient.

        Returns:
            (x, y) in pattern pixels, or None when the gradient is not visible.
        """
        # grim captures the virtual output exactly as rendered (the zoomed gradient).
        shot = str(self.work_dir / "shot.png")
        self.harness("shot", shot)
        image = png_probe.read_png(shot)
        # Two probe pixels: the centre normally works, the corner is a fallback near borders.
        for screen_x, screen_y in ((WIDTH // 2, HEIGHT // 2), (60, 60)):
            point = png_probe.pattern_point(png_probe.pixel(image, screen_x, screen_y))
            # The pattern point at a screen pixel minus the zoomed offset is the camera origin.
            if point:
                return round(point[0] - screen_x / ZOOM), round(point[1] - screen_y / ZOOM)
        return None

    def reset_camera_state(self) -> None:
        """Gets Hyprland to forget the camera: render real frames at zoom 1.0 (see S1 Q7)."""
        # Zoom out first; the animation needs time to finish before frames at 1.0 appear.
        self.lua("hl.config({cursor={zoom_factor=1.0}})")
        time.sleep(1.2)
        # Pointer movement damages the cursor area so frames really get rendered.
        self.move_pointer(20, 20)
        self.move_pointer(30, 30)
        # Alternating background colours force full-monitor damage, i.e. genuine frames at 1.0.
        for colour in ("0x010101", "0x000000", "0x010101", "0x000000"):
            self.lua(f'hl.config({{misc={{background_color="{colour}"}}}})')
            time.sleep(0.5)


class LiveTest:
    """The checks, sharing one nested instance, one predictor binary and one result list."""

    def __init__(self, nested: Nested, predictor: Path) -> None:
        """Remembers the collaborators.

        Args:
            nested: Nested instance wrapper (not yet started).
            predictor: Compiled tests/plugin/camera_predict.
        """
        self.nested = nested
        self.predictor = predictor
        # Descriptions of failed checks, for the final verdict.
        self.failed: list[str] = []

    def check(self, condition: bool, description: str) -> None:
        """Prints one verdict line and remembers failures.

        Args:
            condition: Result of the check.
            description: What was checked.
        """
        # Flush so progress is visible while the slow checks run.
        print(("PASS  " if condition else "FAIL  ") + description, flush=True)
        if not condition:
            self.failed.append(description)

    def predict(self, margin: float) -> list:
        """Asks the compiled camera maths for the camera after each pointer move.

        Args:
            margin: Edge margin.

        Returns:
            List of (x, y) camera origins, one per entry of POINTER_PATH.
        """
        # The predictor takes the anchor first, then every pointer position as "x,y".
        points = [f"{x},{y}" for x, y in (ANCHOR, *POINTER_PATH)]
        command = [str(self.predictor), str(margin), str(ZOOM), str(WIDTH), str(HEIGHT), *points]
        # One "x y" line per pointer position comes back.
        output = subprocess.run(command, text=True, capture_output=True, check=True).stdout
        return [tuple(float(value) for value in line.split()) for line in output.splitlines()]

    def measure_path(self) -> list:
        """Zooms in at ANCHOR, walks POINTER_PATH and measures the camera after each step.

        Returns:
            List of measured (x, y) camera origins.
        """
        # Start every measurement from a freshly forgotten camera and the anchor position.
        self.nested.reset_camera_state()
        self.nested.move_pointer(*ANCHOR)
        # Zoom in at the anchor and wait for the animation to settle.
        self.nested.lua(f"hl.config({{cursor={{zoom_factor={ZOOM}}}}})")
        time.sleep(ZOOM_SETTLE_SECONDS)
        # Walk the path and measure after every pointer move.
        measured = []
        for x, y in POINTER_PATH:
            self.nested.move_pointer(x, y)
            # camera() already waited for a rendered frame inside move_pointer.
            measured.append(self.nested.camera())
        return measured

    @staticmethod
    def matches(measured: list, expected: list) -> bool:
        """Compares measured and predicted camera paths within TOLERANCE_PX.

        Args:
            measured: Output of measure_path.
            expected: Output of predict.

        Returns:
            True when every step is within tolerance.
        """
        # A missing measurement (None) or a different step count can never match.
        if len(measured) != len(expected) or None in measured:
            return False
        return all(
            abs(m[0] - e[0]) <= TOLERANCE_PX and abs(m[1] - e[1]) <= TOLERANCE_PX
            for m, e in zip(measured, expected)
        )

    def check_path(self, margin: float, description: str) -> None:
        """Measures the current camera path and compares it with the prediction for a margin.

        Args:
            margin: Margin whose prediction applies.
            description: Check title.
        """
        expected = self.predict(margin)
        measured = self.measure_path()
        # Whether Hyprland really forgot the old camera depends on frame scheduling (S1 Q7 quirk,
        # present in native Hyprland too); a genuine hook bug is deterministic and fails twice.
        retried = not self.matches(measured, expected)
        if retried:
            measured = self.measure_path()
        # The note keeps a flaky-reset retry visible in the log instead of hiding it.
        note = " (after 1 retry: camera reset is timing dependent)" if retried else ""
        self.check(
            self.matches(measured, expected),
            f"{description}: measured {measured} vs predicted {expected}{note}",
        )

    def margin_from_lua(self) -> float:
        """Reads `plugin.hyprzoom.edge_margin` through the Lua config API.

        Returns:
            The value rounded to two decimals (Hyprland stores it as float32).
        """
        raw = self.nested.query('hl.get_config("plugin.hyprzoom.edge_margin")')
        return round(float(raw), 2)

    def check_plugin_basics(self) -> None:
        """Checks loading and the Lua config mapping."""
        nested = self.nested
        # Loaded through hl.plugin.load in the nested config.
        listed = "hyprzoom" in nested.ctl("plugin", "list")
        self.check(listed, "plugin listed by `hyprctl plugin list`")
        # The margin configured in the config file must be readable through Lua.
        self.check(self.margin_from_lua() == 0.05, "Lua config: edge_margin reads back 0.05")
        # Runtime changes use the documented Lua mapping plugin.hyprzoom.edge_margin.
        nested.lua("hl.config({plugin={hyprzoom={edge_margin=0.25}}})")
        self.check(self.margin_from_lua() == 0.25, "hl.config({plugin={hyprzoom=...}}) accepted")
        # The bool option defaults to true (plugin active).
        enabled = nested.query('tostring(hl.get_config("plugin.hyprzoom.enabled"))')
        self.check(enabled == "true", "plugin.hyprzoom.enabled defaults to true")

    def check_margins(self) -> None:
        """Measures the camera for every margin and compares it with the maths."""
        for margin in MARGINS:
            # Set the margin through the same Lua path the engine will use.
            self.nested.lua(f"hl.config({{plugin={{hyprzoom={{edge_margin={margin}}}}}}})")
            self.check_path(margin, f"margin {margin:.2f}")

    def check_native_fallbacks(self) -> None:
        """Checks `enabled=false` and unloading both give the native (margin 0.05) camera."""
        nested = self.nested
        # A big margin must be ignored while the plugin is switched off.
        nested.lua("hl.config({plugin={hyprzoom={edge_margin=0.40, enabled=false}}})")
        self.check_path(0.05, "enabled=false ignores margin 0.40 (native camera)")
        # Unloading must restore the native code path and leave the compositor running.
        nested.lua("hl.config({plugin={hyprzoom={enabled=true}}})")
        nested.ctl("plugin", "unload", str(PLUGIN_SO))
        self.check("hyprzoom" not in nested.ctl("plugin", "list"), "plugin unloads cleanly")
        # With the hook removed the margin cannot matter any more: native numbers again.
        self.check_path(0.05, "after unload the native camera is back")
        self.check(nested.alive(), "compositor alive after unload")

    def check_reload_and_monitor_add(self) -> None:
        """Reloads the plugin, then adds and removes a monitor while zoomed."""
        nested = self.nested
        # Loading at runtime is how hyprpm brings the plugin in.
        nested.ctl("plugin", "load", str(PLUGIN_SO))
        nested.lua("hl.config({plugin={hyprzoom={edge_margin=0.25}}})")
        self.check_path(0.25, "reloaded plugin works again (margin 0.25)")
        # A second monitor means a second CMonitorZoomController is exercised by the hook.
        nested.ctl("output", "create", "headless")
        time.sleep(1.0)
        self.check(nested.alive(), "no crash when a monitor is added while zoomed")
        # Removing it again must not leave the hook with a dangling controller.
        nested.ctl("output", "remove", "HEADLESS-2")
        time.sleep(0.5)
        self.check(nested.alive(), "no crash when that monitor is removed again")
        self.check_path(0.25, "camera still follows margin 0.25 afterwards")

    def check_config_reload(self) -> None:
        """Checks `hyprctl reload` (Omarchy does this on every theme/config change)."""
        nested = self.nested
        # Set a value that differs from the config file, so the reload visibly resets it.
        nested.lua("hl.config({plugin={hyprzoom={edge_margin=0.40}}})")
        nested.ctl("reload")
        time.sleep(1.5)
        # The plugin must survive the reload and re-read the config file's margin.
        self.check(nested.alive(), "compositor alive after `hyprctl reload`")
        self.check("hyprzoom" in nested.ctl("plugin", "list"), "plugin still loaded after reload")
        self.check(self.margin_from_lua() == 0.05, "reload re-applies the file's margin (0.05)")
        # After the reload the hook must still be in charge.
        nested.lua("hl.config({plugin={hyprzoom={edge_margin=0.40}}})")
        self.check_path(0.40, "hook still active after reload (margin 0.40)")

    def check_refusal(self, work_dir: Path) -> None:
        """Builds a plugin that searches a nonexistent symbol and checks it refuses to load.

        Args:
            work_dir: Scratch directory for the throw-away build.
        """
        nested = self.nested
        # A scratch copy of the plugin dir keeps the real build output untouched.
        bad_dir = work_dir / "bad-plugin"
        shutil.rmtree(bad_dir, ignore_errors=True)
        shutil.copytree(REPO_ROOT / "plugin", bad_dir, ignore=shutil.ignore_patterns("*.so"))
        # The Makefile's EXTRA_CXXFLAGS swaps the searched symbol for one that does not exist.
        flags = 'EXTRA_CXXFLAGS=-DHYPRZOOM_HOOKED_SYMBOL=\\"zoomWithNoSuchFunction\\"'
        command = ["make", "-C", str(bad_dir), flags]
        build = subprocess.run(command, capture_output=True, text=True, check=False)
        self.check(build.returncode == 0, "test build with a wrong symbol name compiles")
        # Unload the good plugin so the name `hyprzoom` is free, then try the bad one.
        nested.ctl("plugin", "unload", str(PLUGIN_SO))
        output = nested.ctl("plugin", "load", str(bad_dir / "hyprzoom.so"))
        listed = "hyprzoom" in nested.ctl("plugin", "list")
        self.check(not listed, f"plugin with unknown symbol is refused ({output[-120:]!r})")
        # Refusing must never take the compositor down, and must say why.
        self.check(nested.alive(), "compositor alive after the refused plugin")
        self.check("hook refused" in output, "the refusal reason is reported back to the user")

    def run_all(self, work_dir: Path) -> int:
        """Starts the nested instance, runs every check and always stops it again.

        Args:
            work_dir: Scratch directory.

        Returns:
            Exit code for the script.
        """
        # The gradient and config are inputs of the nested instance.
        gradient = work_dir / "gradient.png"
        png_probe.write_gradient(str(gradient), WIDTH, HEIGHT)
        config = write_nested_config(work_dir)
        try:
            print("nested instance:", self.nested.harness("start", str(config)), flush=True)
            # imv shows the gradient 1:1 on the whole virtual output, full screen.
            self.nested.harness("run", "imv-wayland", "-f", "-s", "none", str(gradient))
            time.sleep(2.5)
            # Cheap checks first, the destructive ones (unload, refusal) last.
            self.check_plugin_basics()
            self.check_margins()
            self.check_native_fallbacks()
            # The plugin was unloaded above; this check loads it again like hyprpm does.
            self.check_reload_and_monitor_add()
            self.check_config_reload()
            # Last, because it leaves the good plugin unloaded.
            self.check_refusal(work_dir)
        finally:
            # Always stop the nested instance, even when a check raised.
            print(self.nested.harness("stop"), flush=True)
            # imv outlives its compositor as an orphan; its command line has our unique path.
            subprocess.run(["pkill", "-f", str(gradient)], check=False)
        print(f"{len(self.failed)} failed" if self.failed else "all nested checks passed")
        return 1 if self.failed else 0


def write_nested_config(work_dir: Path) -> Path:
    """Writes the Lua config of the nested instance (loads the plugin through hl.plugin.load).

    Args:
        work_dir: Scratch directory.

    Returns:
        Path of the config file.
    """
    # Fill the template with the geometry and the absolute plugin path.
    config = work_dir / "nested.lua"
    config.write_text(NESTED_CONFIG.format(width=WIDTH, height=HEIGHT, plugin=PLUGIN_SO))
    return config


def build_predictor(work_dir: Path) -> Path:
    """Compiles tests/plugin/camera_predict.cpp.

    Args:
        work_dir: Scratch directory for the binary.

    Returns:
        Path of the executable.
    """
    # Plain g++ is enough: the predictor only includes camera_math.hpp.
    binary = work_dir / "camera_predict"
    source = REPO_ROOT / "tests" / "plugin" / "camera_predict.cpp"
    subprocess.run(["g++", "-std=c++20", "-O1", str(source), "-o", str(binary)], check=True)
    return binary


def prerequisites_missing() -> str:
    """Names what prevents the live test from running.

    Returns:
        Empty string when everything is in place, otherwise a reason.
    """
    # The nested window briefly shows up in the user's session, so require explicit consent.
    if os.environ.get("HYPRZOOM_TEST_NESTED_OK") != "1":
        return "set HYPRZOOM_TEST_NESTED_OK=1 to run (a window appears briefly)"
    # Every external tool the test shells out to.
    tools = ("Hyprland", "hyprctl", "grim", "imv-wayland", "g++")
    missing = [tool for tool in tools if not shutil.which(tool)]
    if missing:
        return "missing tools: " + ", ".join(missing)
    # The plugin must be built, and a parent Wayland session must exist to nest into.
    if not PLUGIN_SO.exists():
        return "plugin/hyprzoom.so not built (run tests/plugin/build.sh)"
    # Hyprland picks its nested (wayland) backend only when a parent session is reachable.
    if not os.environ.get("WAYLAND_DISPLAY"):
        return "no parent Wayland session (WAYLAND_DISPLAY unset)"
    return ""


def main() -> int:
    """Parses arguments, checks prerequisites and runs the live test.

    Returns:
        Exit code (see module docstring).
    """
    # The first docstring line doubles as the --help description.
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    help_text = "scratch directory (default: temp dir)"
    parser.add_argument("--work-dir", type=Path, default=None, help=help_text)
    args = parser.parse_args()
    # Skipping (77) is not a failure: CI without a Wayland session stays green.
    reason = prerequisites_missing()
    if reason:
        print("SKIP  nested test:", reason)
        return 77
    # A fresh temp dir per run unless the caller wants to keep screenshots.
    work_dir = args.work_dir or Path(tempfile.mkdtemp(prefix="hyprzoom-nested."))
    work_dir.mkdir(parents=True, exist_ok=True)
    # Build the predictor first so a compile error surfaces before the nested instance starts.
    return LiveTest(Nested(work_dir), build_predictor(work_dir)).run_all(work_dir)


if __name__ == "__main__":
    sys.exit(main())
