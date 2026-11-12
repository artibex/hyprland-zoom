"""Locate the settings schema, the zoomctl executable and the icon directory.

Resolution order for the schema follows the task contract: ``ZOOMCTL_SHARE_DIR``, then the
installed ``/usr/share/hyprland-zoom``, then the checkout the package is run from.
"""

# os.path handles the file system lookups, typing documents the optional environment mapping.
import os
from typing import Mapping, Optional

from .constants import DEFAULT_SHARE_DIR, DEFAULT_ZOOMCTL, ENV_SHARE_DIR, ENV_ZOOMCTL_BIN

# File name of the schema inside a share directory and relative to a checkout.
SCHEMA_FILE_NAME = "settings.schema"
# Repository root relative to this file: src/ui/hyprland_zoom_settings/paths.py -> repo.
CHECKOUT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def resolve_zoomctl_binary(environment: Mapping[str, str]) -> str:
    """Pick the zoomctl executable.

    Args:
        environment: Process environment (``ZOOMCTL_BIN`` overrides the PATH lookup).

    Returns:
        The path or command name to execute.
    """
    # An explicit override wins; an empty value counts as unset.
    override = environment.get(ENV_ZOOMCTL_BIN, "").strip()
    return override or DEFAULT_ZOOMCTL


def resolve_schema_path(environment: Mapping[str, str]) -> Optional[str]:
    """Find ``settings.schema``.

    Args:
        environment: Process environment (``ZOOMCTL_SHARE_DIR`` is honoured).

    Returns:
        Path of the first existing candidate, or None when there is none.
    """
    # The environment override is authoritative: a wrong path must not fall through silently.
    override = environment.get(ENV_SHARE_DIR, "").strip()
    if override:
        candidate = os.path.join(override, SCHEMA_FILE_NAME)
        return candidate if os.path.isfile(candidate) else None
    # Installed layout first, the repository layout (config/settings.schema) as the fallback.
    candidates = (
        os.path.join(DEFAULT_SHARE_DIR, SCHEMA_FILE_NAME),
        os.path.join(CHECKOUT_ROOT, "config", SCHEMA_FILE_NAME),
    )
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    # None tells the app to show its explanation window.
    return None


def resolve_icon_search_dir() -> Optional[str]:
    """Find the icon theme root of a checkout so the icon works before installation.

    Returns:
        The ``data/icons`` directory of the checkout, or None when running installed.
    """
    # Installed copies use the system icon theme and need no extra search path.
    candidate = os.path.join(CHECKOUT_ROOT, "data", "icons")
    return candidate if os.path.isdir(candidate) else None
