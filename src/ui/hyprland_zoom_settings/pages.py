"""Settings pages: one ``Adw.PreferencesPage`` per schema group, generated from the schema.

Only presentation is hand-tuned here: the tracking page shows ONE notice (and locks the margin
slider) while the margin mode lacks its plugin, the advanced page carries "Restore defaults".
"""

# typing documents the mappings and lists.
from typing import Dict, List, Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from . import dialogs  # noqa: E402
from .porcelain import EngineStatus, TrackingNotice, tracking_notice  # noqa: E402
from .presentation import GroupInfo, ordered_groups  # noqa: E402
from .row_base import RowContext, SettingRow, StackedRow  # noqa: E402
from .rows import build_setting_row  # noqa: E402
from .schema import SettingSpec  # noqa: E402

# Schema keys the tracking page treats specially.
TRACKING_KEY = "ZOOM_TRACKING"
EDGE_MARGIN_KEY = "ZOOM_EDGE_MARGIN"
MARGIN_MODE = "margin"
# Why the margin slider is locked (shown in place of its help text).
MARGIN_LOCKED_REASON = "Needs the hyprzoom plugin. See the notice above."


class SettingsPage(Adw.PreferencesPage):
    """A page whose rows are generated from the settings of one schema group."""

    def __init__(self, info: GroupInfo, specs: List[SettingSpec], context: RowContext) -> None:
        """Build the page.

        Args:
            info: Page title, icon and description.
            specs: Settings of the group in schema order.
            context: Shared row callbacks.

        Returns:
            None.
        """
        # The page has no intro text: the sidebar and the rows already say what it is.
        super().__init__(title=info.title, icon_name=info.icon)
        self.group_id = info.group
        self.summary = info.description
        # Rows by schema key, and the preferences group that holds each row (for hiding).
        self.rows: Dict[str, SettingRow] = {}
        self.group_of: Dict[str, Adw.PreferencesGroup] = {}
        self._build(specs, context)

    def _build(self, specs: List[SettingSpec], context: RowContext) -> None:
        """Create the widgets for every setting, keeping the schema order.

        Args:
            specs: Settings of the group.
            context: Shared row callbacks.

        Returns:
            None.
        """
        current_group: Optional[Adw.PreferencesGroup] = None
        for spec in specs:
            row = build_setting_row(spec, context)
            self.rows[spec.key] = row
            if isinstance(row.widget, Adw.PreferencesGroup):
                # Explained choice lists are groups of their own; the next row starts anew.
                self.add(row.widget)
                self.group_of[spec.key] = row.widget
                current_group = None
                continue
            # The first plain row after a choice list opens a fresh group.
            if current_group is None:
                current_group = Adw.PreferencesGroup()
                self.add(current_group)
            # Plain rows of one run share a group, so the page keeps its rhythm.
            current_group.add(row.widget)
            self.group_of[spec.key] = current_group

    def apply_values(self, values: Dict[str, str], status: EngineStatus) -> None:
        """Show the effective configuration and status in every row.

        Args:
            values: Effective configuration, key -> text.
            status: Current engine status.

        Returns:
            None.
        """
        for row in self.rows.values():
            row.apply_values(values)
        self.refine(values, status)

    def refine(self, values: Dict[str, str], status: EngineStatus) -> None:
        """Hook for page-specific presentation (default: nothing).

        Args:
            values: Effective configuration.
            status: Current engine status.

        Returns:
            None.
        """
        # Plain pages need nothing beyond their rows.
        return None

    def flush(self) -> None:
        """Send every pending debounced edit (window closing).

        Returns:
            None.
        """
        for row in self.rows.values():
            row.flush()


class TrackingPage(SettingsPage):
    """Tracking modes as explained choices; one notice and a locked slider without the plugin."""

    def __init__(self, info: GroupInfo, specs: List[SettingSpec], context: RowContext) -> None:
        """Build the rows and the notice group between the choices and the margin slider.

        Args:
            info: Page title, icon and description.
            specs: Settings of the group.
            context: Shared row callbacks.

        Returns:
            None.
        """
        super().__init__(info, specs, context)
        # The button opens the installation help dialog.
        self.install_button = Gtk.Button(label="How to install…", halign=Gtk.Align.START)
        self.install_button.connect(
            "clicked", lambda button: dialogs.show_plugin_help(button)
        )
        # One notice slot (title, body, button) that is filled and shown on demand.
        self._notice = StackedRow("", "", self.install_button)
        self.notice_group = Adw.PreferencesGroup(visible=False)
        self.notice_group.add(self._notice.widget)
        # The notice sits right under the choices, above the margin slider.
        margin_group = self.group_of.get(EDGE_MARGIN_KEY)
        if margin_group is not None:
            self.remove(margin_group)
        # The margin group is re-added after the notice.
        self.add(self.notice_group)
        if margin_group is not None:
            self.add(margin_group)

    def refine(self, values: Dict[str, str], status: EngineStatus) -> None:
        """Show or hide the margin slider and the notice.

        Args:
            values: Effective configuration.
            status: Current engine status.

        Returns:
            None.
        """
        # The margin only matters in margin mode, so the slider is hidden otherwise.
        configured = values.get(TRACKING_KEY, "")
        margin_selected = configured == MARGIN_MODE
        if EDGE_MARGIN_KEY in self.rows:
            self.rows[EDGE_MARGIN_KEY].set_visible(margin_selected)
            self.group_of[EDGE_MARGIN_KEY].set_visible(margin_selected)
            # Without the plugin the slider would silently do nothing, so it is locked.
            locked = not status.plugin_loaded
            self.rows[EDGE_MARGIN_KEY].set_reason(MARGIN_LOCKED_REASON if locked else None)
        self._show_notice(tracking_notice(configured, status))

    def _show_notice(self, notice: Optional[TrackingNotice]) -> None:
        """Fill and show the single notice, or hide it.

        Args:
            notice: Result of ``tracking_notice``.

        Returns:
            None.
        """
        self.notice_group.set_visible(notice is not None)
        if notice is None:
            return
        # The texts come from the notice; the install button only fits the plugin case.
        self._notice.title_label.set_label(notice.title)
        self._notice.subtitle_label.set_label(notice.body)
        # Only the missing plugin can be fixed by installing something.
        self.install_button.set_visible(notice.needs_plugin)


class AdvancedPage(SettingsPage):
    """Advanced settings plus the "Restore defaults" button."""

    def __init__(self, info: GroupInfo, specs: List[SettingSpec], context: RowContext) -> None:
        """Build the rows and the reset group.

        Args:
            info: Page title, icon and description.
            specs: Settings of the group.
            context: Shared row callbacks.

        Returns:
            None.
        """
        super().__init__(info, specs, context)
        restore_button = Gtk.Button(
            label="Restore defaults…", halign=Gtk.Align.START, action_name="win.restore-defaults"
        )
        restore_button.add_css_class("destructive-action")
        # Title, explanation and the destructive button stacked, so they fit any width.
        row = StackedRow(
            "Restore defaults",
            "Removes all your changes and returns every setting to its default.",
            restore_button,
        )
        group = Adw.PreferencesGroup()
        # The reset sits in its own group, apart from the ordinary settings.
        group.add(row.widget)
        self.add(group)


# Pages with extra presentation; every other group uses the generic page.
PAGE_CLASSES = {"tracking": TrackingPage, "advanced": AdvancedPage}


def build_pages(schema, context: RowContext) -> List[SettingsPage]:
    """Create one page per schema group in presentation order.

    Args:
        schema: The SettingsSchema.
        context: Shared row callbacks.

    Returns:
        The pages, ready to be added to a view stack.
    """
    pages: List[SettingsPage] = []
    for info in ordered_groups(schema.group_ids()):
        page_class = PAGE_CLASSES.get(info.group, SettingsPage)
        # Each page gets exactly the settings of its group.
        pages.append(page_class(info, schema.specs_in_group(info.group), context))
    return pages
