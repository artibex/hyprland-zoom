"""The application object, the root check and ``main``."""

# os reads the environment and the user id; sys passes argv; typing documents optionals.
import os
import sys
from typing import List, Mapping, Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, Gtk  # noqa: E402 - gi.require_version must run first

from .backend import ZoomctlClient  # noqa: E402
from .constants import APP_ID, APP_NAME  # noqa: E402
from .controller import SettingsController  # noqa: E402
from .paths import resolve_icon_search_dir, resolve_schema_path, resolve_zoomctl_binary  # noqa: E402
from .schema import SchemaError, load_schema  # noqa: E402
from .tryit import TryItController  # noqa: E402
from .window import SettingsWindow  # noqa: E402

# Exit codes of ``main``.
EXIT_OK = 0
EXIT_REFUSED = 1


def refuse_root(effective_user_id: int) -> Optional[str]:
    """Decide whether the app must refuse to start.

    Args:
        effective_user_id: Result of ``os.geteuid()``.

    Returns:
        An error message when running as root, otherwise None.
    """
    # A settings app for a user session has no business running as root (contract C8).
    if effective_user_id == 0:
        return f"{APP_NAME} must not run as root; start it as your normal user."
    return None


class ZoomSettingsApplication(Adw.Application):
    """Single-instance application: a second launch just raises the existing window."""

    def __init__(
        self,
        application_id: str = APP_ID,
        flags: Gio.ApplicationFlags = Gio.ApplicationFlags.DEFAULT_FLAGS,
        environment: Optional[Mapping[str, str]] = None,
    ) -> None:
        """Create the application.

        Args:
            application_id: D-Bus/Wayland id (tests pass their own).
            flags: Application flags (tests pass NON_UNIQUE).
            environment: Environment used to locate zoomctl and the schema.

        Returns:
            None.
        """
        super().__init__(application_id=application_id, flags=flags)
        self.environment = os.environ if environment is None else environment
        self.window: Optional[Adw.ApplicationWindow] = None

    def do_startup(self) -> None:
        """Make the application icon findable when running from a checkout.

        Returns:
            None.
        """
        Adw.Application.do_startup(self)
        icon_dir = resolve_icon_search_dir()
        display = Gtk.IconTheme.get_for_display(self._display())
        # Installed copies use the system theme; checkouts add their own icon directory.
        if icon_dir and display is not None:
            display.add_search_path(icon_dir)

    @staticmethod
    def _display():
        """Get the default display.

        Returns:
            The Gdk.Display the application runs on.
        """
        from gi.repository import Gdk

        return Gdk.Display.get_default()

    def do_activate(self) -> None:
        """Present the existing window or build a new one.

        Returns:
            None.
        """
        if self.window is None:
            self.window = self._create_window()
        self.window.present()

    def _create_window(self) -> Adw.ApplicationWindow:
        """Build the settings window, or an explanatory window when the schema is unusable.

        Returns:
            The window to present.
        """
        schema_path = resolve_schema_path(self.environment)
        if schema_path is None:
            return self._error_window("settings.schema was not found (is hyprland-zoom installed?)")
        try:
            schema = load_schema(schema_path)
        except (OSError, SchemaError, ValueError) as error:
            return self._error_window(f"settings.schema could not be read: {error}")
        client = ZoomctlClient(resolve_zoomctl_binary(self.environment))
        controller = SettingsController(schema, client)
        return SettingsWindow(self, schema, controller, TryItController(controller))

    def _error_window(self, message: str) -> Adw.ApplicationWindow:
        """Create a window that only explains why the app cannot work.

        Args:
            message: What went wrong.

        Returns:
            The error window.
        """
        window = Adw.ApplicationWindow(application=self, title=APP_NAME, default_width=520,
                                       default_height=360)
        page = Adw.StatusPage(icon_name="dialog-error-symbolic", title="Cannot start",
                              description=message)
        view = Adw.ToolbarView()
        view.add_top_bar(Adw.HeaderBar())
        view.set_content(page)
        window.set_content(view)
        return window


def main(argv: Optional[List[str]] = None) -> int:
    """Run the settings app.

    Args:
        argv: Command line (defaults to ``sys.argv``).

    Returns:
        Process exit code.
    """
    refusal = refuse_root(os.geteuid())
    if refusal:
        print(refusal, file=sys.stderr)
        return EXIT_REFUSED
    return ZoomSettingsApplication().run(sys.argv if argv is None else argv)
