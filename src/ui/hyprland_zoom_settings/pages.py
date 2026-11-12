"""Settings pages: one ``Adw.PreferencesPage`` per schema group, generated from the schema.

Only presentation is hand-tuned here: the tracking page explains the plugin dependency and
shows the margin slider only for the margin mode, the advanced page carries "Restore defaults".
"""

# typing documents the mappings and lists.
from typing import Dict, List, Optional

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402 - gi.require_version must run first

from .constants import PROJECT_URL  # noqa: E402
from .porcelain import EngineStatus  # noqa: E402
from .presentation import GroupInfo, option_description, ordered_groups  # noqa: E402
from .rows import ChoiceListRow, RowContext, SettingRow, build_setting_row  # noqa: E402
from .schema import SettingSpec  # noqa: E402

# Schema keys the tracking page treats specially.
TRACKING_KEY = "ZOOM_TRACKING"
EDGE_MARGIN_KEY = "ZOOM_EDGE_MARGIN"
MARGIN_MODE = "margin"
# Where the plugin installation is described (docs/plugin.md in the project repository).
PLUGIN_DOCS_URL = f"{PROJECT_URL}/blob/main/docs/plugin.md"


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
        super().__init__(title=info.title, icon_name=info.icon, description=info.description)
        self.group_id = info.group
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
            if current_group is None:
                current_group = Adw.PreferencesGroup()
                self.add(current_group)
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
    """Tracking modes as explained choices, margin slider only for the margin mode."""

    def __init__(self, info: GroupInfo, specs: List[SettingSpec], context: RowContext) -> None:
        """Build the rows and the plugin hint group.

        Args:
            info: Page title, icon and description.
            specs: Settings of the group.
            context: Shared row callbacks.

        Returns:
            None.
        """
        super().__init__(info, specs, context)
        self.plugin_row = Adw.ActionRow()
        self.plugin_row.add_prefix(Gtk.Image(icon_name="dialog-information-symbolic"))
        docs_link = Gtk.LinkButton(uri=PLUGIN_DOCS_URL, label="docs/plugin.md")
        docs_link.set_valign(Gtk.Align.CENTER)
        self.plugin_row.add_suffix(docs_link)
        self.effective_row = Adw.ActionRow(title="Active tracking mode")
        group = Adw.PreferencesGroup(title="Margin mode")
        group.add(self.plugin_row)
        group.add(self.effective_row)
        self.add(group)

    def refine(self, values: Dict[str, str], status: EngineStatus) -> None:
        """Show or hide the margin slider and describe the plugin state.

        Args:
            values: Effective configuration.
            status: Current engine status.

        Returns:
            None.
        """
        # The margin only matters in margin mode, so the slider is hidden otherwise.
        margin_selected = values.get(TRACKING_KEY) == MARGIN_MODE
        if EDGE_MARGIN_KEY in self.rows:
            self.rows[EDGE_MARGIN_KEY].set_visible(margin_selected)
            self.group_of[EDGE_MARGIN_KEY].set_visible(margin_selected)
        self._describe_plugin(status)
        self.effective_row.set_subtitle(status.tracking_effective or "unknown")

    def _describe_plugin(self, status: EngineStatus) -> None:
        """Explain whether margin mode is available and annotate its option.

        Args:
            status: Current engine status.

        Returns:
            None.
        """
        margin_text = option_description(TRACKING_KEY, MARGIN_MODE) or ""
        if status.plugin_loaded:
            self.plugin_row.set_title("hyprzoom plugin detected")
            self.plugin_row.set_subtitle("Margin mode is available.")
            note = margin_text
        else:
            self.plugin_row.set_title("hyprzoom plugin not detected")
            self.plugin_row.set_subtitle(
                "Margin mode needs the optional hyprzoom plugin. Without it Hyprland keeps its "
                "fixed 5 % edge margin. Installation is described in:"
            )
            note = f"{margin_text} Needs the hyprzoom plugin (not detected)."
        choice = self.rows.get(TRACKING_KEY)
        if isinstance(choice, ChoiceListRow):
            choice.set_option_subtitle(MARGIN_MODE, note)


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
            label="Restore defaults…", valign=Gtk.Align.CENTER, action_name="win.restore-defaults"
        )
        restore_button.add_css_class("destructive-action")
        row = Adw.ActionRow(
            title="Restore defaults",
            subtitle="Removes all your changes and returns every setting to its default.",
        )
        row.add_suffix(restore_button)
        group = Adw.PreferencesGroup(title="Reset")
        group.add(row)
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
        pages.append(page_class(info, schema.specs_in_group(info.group), context))
    return pages
