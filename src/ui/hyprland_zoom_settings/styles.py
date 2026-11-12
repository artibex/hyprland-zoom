"""Application style sheet: the keycap look, built only from theme colours.

No colour is hard-coded: the caps use libadwaita's named colours, so dark, light and high
contrast styles all stay readable.
"""

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402 - gi.require_version must run first

# One drawn key of a shortcut; a border keeps it visible when the contrast is raised.
STYLE_SHEET = """
.hzoom-keycap {
  padding: 2px 8px;
  border-radius: 6px;
  border: 1px solid @borders;
  background-color: alpha(@window_fg_color, 0.08);
  font-weight: bold;
}
"""


def install_styles(display) -> None:
    """Add the style sheet to a display.

    Args:
        display: The Gdk.Display of the application.

    Returns:
        None.
    """
    provider = Gtk.CssProvider()
    provider.load_from_string(STYLE_SHEET)
    # APPLICATION priority beats the theme but yields to a user's own CSS overrides.
    Gtk.StyleContext.add_provider_for_display(
        display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
