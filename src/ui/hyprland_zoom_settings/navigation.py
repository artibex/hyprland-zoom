"""The page list (sidebar): one entry per settings page, shown next to or before the content."""

# typing documents the callback shape and the page list.
from typing import Callable, Dict, List

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402 - gi.require_version must run first

from .pages import SettingsPage  # noqa: E402
from .row_base import label_accessibly  # noqa: E402

# Called with the group id of the page the user picked.
PageCallback = Callable[[str], None]


class PageList(Gtk.ListBox):
    """A navigation list; selecting an entry shows the page, activating it opens it."""

    def __init__(
        self, pages: List[SettingsPage], on_selected: PageCallback, on_opened: PageCallback
    ) -> None:
        """Build one entry per page.

        Args:
            pages: Pages in display order.
            on_selected: Called when the selection moves to a page (arrow keys, click).
            on_opened: Called when an entry is activated (click, Enter): in the narrow
                layout this moves from the list to the page.

        Returns:
            None.
        """
        super().__init__(selection_mode=Gtk.SelectionMode.SINGLE)
        # The sidebar style makes the list look like a navigation list, not a settings list.
        self.add_css_class("navigation-sidebar")
        self._entries: Dict[str, Gtk.ListBoxRow] = {}
        self._group_of_row: Dict[Gtk.ListBoxRow, str] = {}
        for page in pages:
            entry = self._build_entry(page)
            self._entries[page.group_id] = entry
            self._group_of_row[entry] = page.group_id
            self.append(entry)
        # Selection and activation are separate: activating an already selected entry
        # must still open it in the narrow layout.
        self.connect("row-selected", lambda _list, row: self._notify(row, on_selected))
        self.connect("row-activated", lambda _list, row: self._notify(row, on_opened))

    @staticmethod
    def _build_entry(page: SettingsPage) -> Gtk.ListBoxRow:
        """Create the list entry of one page.

        Args:
            page: The page.

        Returns:
            A row with the page icon and title; long titles wrap instead of being cut.
        """
        box = Gtk.Box(spacing=12)
        box.append(Gtk.Image(icon_name=page.get_icon_name()))
        title = Gtk.Label(label=page.get_title(), xalign=0.0, wrap=True, hexpand=True)
        box.append(title)
        # Comfortable padding also gives large touch/pointer targets.
        for side in ("top", "bottom"):
            getattr(box, f"set_margin_{side}")(10)
        entry = Gtk.ListBoxRow(child=box, tooltip_text=page.summary or None)
        label_accessibly(entry, page.get_title(), page.summary)
        return entry

    def _notify(self, row: Gtk.ListBoxRow, callback: PageCallback) -> None:
        """Pass the group id of a row to a callback.

        Args:
            row: The row, or None when the selection was cleared.
            callback: Receiver of the group id.

        Returns:
            None.
        """
        # A cleared selection carries no page.
        if row is not None:
            callback(self._group_of_row[row])

    def select_group(self, group_id: str) -> None:
        """Select the entry of a page.

        Args:
            group_id: Group id of the page.

        Returns:
            None.
        """
        self.select_row(self._entries[group_id])
