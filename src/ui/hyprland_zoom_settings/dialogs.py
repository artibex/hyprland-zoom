"""Dialogs: the confirmation dialog and the about dialog.

They live in one module so tests can replace ``confirm`` and answer it without a human.
"""

# typing documents the callback shape.
from typing import Callable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import APP_ID, APP_NAME, PROJECT_URL  # noqa: E402

# Response ids of the confirmation dialog.
RESPONSE_CANCEL = "cancel"
RESPONSE_CONFIRM = "confirm"


def confirm(
    parent: Gtk.Widget, heading: str, body: str, action_label: str, on_confirm: Callable[[], None]
) -> None:
    """Ask the user to confirm a destructive action; Cancel is the default.

    Args:
        parent: Widget the dialog is presented over.
        heading: Dialog title.
        body: Explanation of what will happen.
        action_label: Label of the confirming button.
        on_confirm: Called only when the user confirms.

    Returns:
        None.
    """
    dialog = Adw.AlertDialog(heading=heading, body=body)
    dialog.add_response(RESPONSE_CANCEL, "Cancel")
    dialog.add_response(RESPONSE_CONFIRM, action_label)
    # Cancel stays the default so an accidental Enter cannot destroy anything.
    dialog.set_response_appearance(RESPONSE_CONFIRM, Adw.ResponseAppearance.DESTRUCTIVE)
    dialog.set_default_response(RESPONSE_CANCEL)
    dialog.set_close_response(RESPONSE_CANCEL)
    dialog.connect("response", lambda _dialog, response: _on_response(response, on_confirm))
    # Presenting over the parent makes the dialog modal for that window.
    dialog.present(parent)


def _on_response(response: str, on_confirm: Callable[[], None]) -> None:
    """Run the action only for the confirming response.

    Args:
        response: Response id chosen by the user.
        on_confirm: Action to run on confirmation.

    Returns:
        None.
    """
    # Cancel and closing the dialog both end here without side effects.
    if response == RESPONSE_CONFIRM:
        on_confirm()


def show_about(parent: Gtk.Widget) -> None:
    """Show the about dialog.

    Args:
        parent: Widget the dialog is presented over.

    Returns:
        None.
    """
    dialog = Adw.AboutDialog(
        application_name=APP_NAME, application_icon=APP_ID, developer_name="artibex",
        website=PROJECT_URL, license_type=Gtk.License.MIT_X11,
        comments="Configure and try out the hyprland-zoom screen magnifier.",
    )
    dialog.present(parent)
