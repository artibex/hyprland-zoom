"""The "press the key" dialog that turns a key press into a Hyprland key name."""

# typing documents the callback shape.
from typing import Callable, Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
# Adw is pinned last; the imports follow once all versions are set.
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import KEY_CAPTURE_GRACE_MILLISECONDS  # noqa: E402
from .keys import CANCEL_KEYSYM_NAME, hyprland_key_name  # noqa: E402

# Called with the Hyprland key name; returns True when the key was accepted (dialog closes).
KeyAcceptor = Callable[[str], bool]


def base_keysym_name(display: Optional[Gdk.Display], keycode: int, keyval: int) -> Optional[str]:
    """Name the key as it is without modifiers (so Shift+0 still means the key ``0``).

    Args:
        display: Display used to look up the keyboard layout (may be None).
        keycode: Hardware keycode of the event.
        keyval: Keyval the event reported (with modifiers applied).

    Returns:
        The keysym name of the unshifted key; falls back to the event's own keyval name when
        the layout lookup is not available (for example on the Broadway backend).
    """
    if display is not None:
        found, layouts, keyvals = display.map_keycode(keycode)
        candidates = zip(layouts, keyvals, strict=True) if found else []
        for layout, base_keyval in candidates:
            # Group 0 / level 0 is the unshifted symbol of the first layout; some backends
            # (Broadway) report keyval 0 for every code, which means "no information".
            if layout.group == 0 and layout.level == 0 and base_keyval:
                return Gdk.keyval_name(base_keyval)
    return Gdk.keyval_name(keyval)


class KeyCaptureDialog(Adw.Dialog):
    """Modal dialog that waits for one key press; a Cancel button is always available."""

    def __init__(self, setting_label: str, on_key: KeyAcceptor) -> None:
        """Build the dialog.

        Args:
            setting_label: Name of the shortcut being changed.
            on_key: Called with the captured Hyprland key name; True closes the dialog.

        Returns:
            None.
        """
        super().__init__(title=setting_label, content_width=380)
        self._on_key = on_key
        # Keys held down while the dialog opens (Enter on "Change…") must not be captured.
        self.armed = False
        GLib.timeout_add(KEY_CAPTURE_GRACE_MILLISECONDS, self._arm)
        page = Adw.StatusPage(
            icon_name="input-keyboard-symbolic",
            title="Press the new key",
            description="Press just the key: the modifier keys are set separately.",
        )
        # A button is the way out for pointer and switch users; Esc does the same.
        cancel = Gtk.Button(label="Cancel", halign=Gtk.Align.CENTER)
        cancel.add_css_class("pill")
        cancel.connect("clicked", lambda _button: self.close())
        page.set_child(cancel)
        # The status page is the whole dialog content.
        self.set_child(page)
        # Capture phase: the dialog sees every key before a focused button could use it.
        controller = Gtk.EventControllerKey()
        controller.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        controller.connect("key-pressed", self._on_key_pressed)
        self.add_controller(controller)

    def _arm(self) -> bool:
        """Start accepting keys once the grace period is over.

        Returns:
            False so the timer fires only once.
        """
        self.armed = True
        return GLib.SOURCE_REMOVE

    def _on_key_pressed(self, _controller, keyval: int, keycode: int, _state) -> bool:
        """Translate a key press and hand it to the acceptor.

        Args:
            _controller: The key controller (unused).
            keyval: Keyval of the press.
            keycode: Hardware keycode of the press.
            _state: Modifier state (unused: modifiers are a separate setting).

        Returns:
            True when the press was consumed, False to let Escape close the dialog.
        """
        # Escape always reaches the dialog's own close handler, even inside the grace period.
        if Gdk.keyval_name(keyval) == CANCEL_KEYSYM_NAME:
            return False
        if not self.armed:
            # The press belongs to the click that opened the dialog: swallow it.
            return True
        name = hyprland_key_name(base_keysym_name(self.get_display(), keycode, keyval))
        # Lone modifiers and unknown keys are not bindable: swallow them.
        if name is None:
            return True
        if self._on_key(name):
            self.close()
        return True
