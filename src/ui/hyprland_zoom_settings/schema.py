"""Parse the settings schema (contract C1) into typed specifications.

The schema file is the only source of keys, types, defaults, ranges, groups, labels and help
texts; the widgets are generated from the objects built here.
"""

# dataclasses give immutable spec objects; typing documents the optional bounds.
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

# Value types the schema may declare (contract C1).
KIND_FLOAT = "float"
KIND_INT = "int"
KIND_BOOL = "bool"
KIND_ENUM = "enum"
KIND_KEY = "key"
KIND_MODS = "mods"
KNOWN_KINDS = (KIND_FLOAT, KIND_INT, KIND_BOOL, KIND_ENUM, KIND_KEY, KIND_MODS)
# A schema line has exactly this many ``|``-separated fields.
SCHEMA_FIELD_COUNT = 7


class SchemaError(ValueError):
    """Raised when a schema line is malformed."""


@dataclass(frozen=True)
class SettingSpec:
    """One setting as declared in the schema.

    Attributes:
        key: Schema key such as ``ZOOM_STEP``.
        kind: One of the ``KIND_*`` constants.
        default: Default value in canonical text form.
        group: Page id (``zoom``, ``tracking``, ...).
        label: Short human-readable name.
        help: One-sentence explanation shown under the label.
        minimum: Lower bound for float/int settings, else None.
        maximum: Upper bound for float/int settings, else None.
        choices: Allowed values of an enum setting, else an empty tuple.
    """

    key: str
    kind: str
    default: str
    group: str
    label: str
    help: str
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    choices: Tuple[str, ...] = ()


class SettingsSchema:
    """All settings of the schema in file order, with lookups by key and by group."""

    def __init__(self, specs: List[SettingSpec]) -> None:
        """Index the specs.

        Args:
            specs: Settings in schema order.

        Returns:
            None.
        """
        # File order is kept because it is the display order inside a page.
        self.specs: List[SettingSpec] = list(specs)
        self.by_key: Dict[str, SettingSpec] = {spec.key: spec for spec in specs}

    def group_ids(self) -> List[str]:
        """List the group ids in order of first appearance.

        Returns:
            Distinct group ids.
        """
        # A dict keeps insertion order and removes repeats in one pass.
        return list(dict.fromkeys(spec.group for spec in self.specs))

    def specs_in_group(self, group: str) -> List[SettingSpec]:
        """Select the settings of one page.

        Args:
            group: Group id.

        Returns:
            The group's settings in schema order.
        """
        # Filtering preserves the schema order of the settings.
        return [spec for spec in self.specs if spec.group == group]

    def defaults(self) -> Dict[str, str]:
        """Collect every default value.

        Returns:
            Mapping key -> canonical default text.
        """
        # Used as the starting point of the effective configuration.
        return {spec.key: spec.default for spec in self.specs}


def _parse_range(kind: str, constraint: str) -> Tuple[Optional[float], Optional[float]]:
    """Read a ``min..max`` constraint.

    Args:
        kind: Setting type (only float and int have ranges).
        constraint: The CONSTRAINT field.

    Returns:
        ``(minimum, maximum)``, both None for types without a range.
    """
    # Only numeric types carry a range.
    if kind not in (KIND_FLOAT, KIND_INT):
        return None, None
    # The separator ``..`` cannot occur inside a number, so a plain split is safe.
    low_text, separator, high_text = constraint.partition("..")
    if not separator:
        raise SchemaError(f"range constraint '{constraint}' needs 'min..max'")
    return float(low_text), float(high_text)


def _parse_line(line: str) -> SettingSpec:
    """Turn one schema line into a spec.

    Args:
        line: A non-comment schema line.

    Returns:
        The parsed spec.
    """
    # HELP is the last field, so it may contain further ``|`` characters.
    fields = [field.strip() for field in line.split("|", SCHEMA_FIELD_COUNT - 1)]
    if len(fields) != SCHEMA_FIELD_COUNT:
        raise SchemaError(f"expected {SCHEMA_FIELD_COUNT} fields: {line!r}")
    key, kind, default, constraint, group, label, help_text = fields
    # Reject unknown types early so the widget factory never meets one.
    if kind not in KNOWN_KINDS:
        raise SchemaError(f"unknown type '{kind}' for {key}")
    minimum, maximum = _parse_range(kind, constraint)
    choices = tuple(constraint.split(",")) if kind == KIND_ENUM else ()
    return SettingSpec(key, kind, default, group, label, help_text, minimum, maximum, choices)


def parse_schema(text: str) -> SettingsSchema:
    """Parse the schema file content.

    Args:
        text: Content of ``settings.schema``.

    Returns:
        The parsed schema.
    """
    specs: List[SettingSpec] = []
    for line in text.splitlines():
        # Comments and blank lines carry no setting.
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        specs.append(_parse_line(line))
    # A repeated key would make the widget-to-setting mapping ambiguous.
    keys = [spec.key for spec in specs]
    if len(keys) != len(set(keys)):
        raise SchemaError("duplicate key in schema")
    return SettingsSchema(specs)


def load_schema(path: str) -> SettingsSchema:
    """Read and parse a schema file.

    Args:
        path: Path of ``settings.schema``.

    Returns:
        The parsed schema.
    """
    # The schema is plain UTF-8 text.
    with open(path, encoding="utf-8") as handle:
        return parse_schema(handle.read())
