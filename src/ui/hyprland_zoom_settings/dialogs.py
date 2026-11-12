"""Dialogs: confirmation, about, toast details and the plugin installation help.

They live in one module so tests can replace ``confirm`` and answer it without a human.
"""

# typing documents the callback shape.
from typing import Callable

import gi

# Toolkit versions are pinned before the first import from gi.repository.
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import (  # noqa: E402
    APP_ID, APP_NAME, PLUGIN_GUIDE_PATH, PLUGIN_INSTALL_COMMANDS, PROJECT_URL,
)

# Response ids of the confirmation dialog.
RESPONSE_CANCEL = "cancel"
RESPONSE_CONFIRM = "confirm"
# Response id of dialogs that only offer to close.
RESPONSE_CLOSE = "close"
# How long a copy button shows its "copied" checkmark (milliseconds).
COPIED_FEEDBACK_MILLISECONDS = 1500
# Default width of the plugin help dialog (pixels); it shrinks on narrow windows.
HELP_DIALOG_WIDTH = 520


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


def show_details(parent: Gtk.Widget, summary: str, details: str) -> None:
    """Show the technical text behind a toast.

    Args:
        parent: Widget the dialog is presented over.
        summary: The sentence the toast showed.
        details: The raw zoomctl text (selectable, so it can be copied into a report).

    Returns:
        None.
    """
    dialog = Adw.AlertDialog(heading=summary, body=details, body_use_markup=False)
    dialog.add_response(RESPONSE_CLOSE, "Close")
    dialog.present(parent)


def _copy_button(text: str) -> Gtk.Button:
    """Create a button that copies a text to the clipboard.

    Args:
        text: Text to copy.

    Returns:
        The flat icon button; it shows a checkmark for a moment after copying.
    """
    button = Gtk.Button(icon_name="edit-copy-symbolic", valign=Gtk.Align.CENTER,
                        tooltip_text="Copy")
    button.add_css_class("flat")
    # The accessible name tells which command the button copies.
    button.update_property([Gtk.AccessibleProperty.LABEL], [f"Copy “{text}”"])
    button.connect("clicked", _on_copy_clicked, text)
    return button


def _on_copy_clicked(button: Gtk.Button, text: str) -> None:
    """Put the text on the clipboard and confirm it visibly.

    Args:
        button: The copy button.
        text: Text to copy.

    Returns:
        None.
    """
    Gdk.Display.get_default().get_clipboard().set(text)
    button.set_icon_name("object-select-symbolic")
    # The checkmark returns to the copy icon after a short moment.
    GLib.timeout_add(COPIED_FEEDBACK_MILLISECONDS, _restore_copy_icon, button)


def _restore_copy_icon(button: Gtk.Button) -> bool:
    """Switch a copy button back to its normal icon.

    Args:
        button: The copy button.

    Returns:
        False so the timer fires only once.
    """
    button.set_icon_name("edit-copy-symbolic")
    return GLib.SOURCE_REMOVE


def _command_row(command: str) -> Gtk.Box:
    """Build one line of the help dialog: the command and its copy button.

    Args:
        command: Shell command to show.

    Returns:
        A box with the selectable command text and the copy button.
    """
    row = Gtk.Box(spacing=8)
    label = Gtk.Label(label=command, xalign=0.0, hexpand=True, wrap=True, selectable=True)
    # A monospace look marks the text as something to type.
    label.add_css_class("monospace")
    row.append(label)
    row.append(_copy_button(command))
    return row


def build_plugin_help_content() -> Gtk.Box:
    """Build the body of the plugin installation help.

    Returns:
        The box with explanation, the copyable commands and the path of the local guide.
    """
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    # The intro tells what to do with the commands below.
    intro = Gtk.Label(
        label="Run these commands in a terminal, one after the other:",
        xalign=0.0, wrap=True,
    )
    box.append(intro)
    # Each command gets its own line with a copy button.
    commands = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    for command in PLUGIN_INSTALL_COMMANDS:
        commands.append(_command_row(command))
    # The commands sit in a card so they read as one block.
    commands.add_css_class("card")
    box.append(commands)
    # The local guide path is for people who prefer reading the full text.
    guide = Gtk.Label(label=f"More details: {PLUGIN_GUIDE_PATH}", xalign=0.0, wrap=True,
                      selectable=True)
    guide.add_css_class("dim-label")
    box.append(guide)
    # Margins keep the content off the dialog edges.
    for side in ("top", "bottom", "start", "end"):
        getattr(box, f"set_margin_{side}")(18)
    return box


def show_plugin_help(parent: Gtk.Widget) -> None:
    """Show how to install the optional hyprzoom plugin.

    Args:
        parent: Widget the dialog is presented over.

    Returns:
        None.
    """
    # The header bar gives the dialog a title and a close button.
    view = Adw.ToolbarView()
    view.add_top_bar(Adw.HeaderBar())
    # The commands scroll when the dialog is short (large text).
    scroller = Gtk.ScrolledWindow(
        hscrollbar_policy=Gtk.PolicyType.NEVER, propagate_natural_height=True
    )
    scroller.set_child(build_plugin_help_content())
    view.set_content(scroller)
    # The natural size keeps the dialog compact; the width suits the commands.
    dialog = Adw.Dialog(title="Install the margin plugin", child=view,
                        content_width=HELP_DIALOG_WIDTH)
    dialog.present(parent)
