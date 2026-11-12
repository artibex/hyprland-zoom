"""Settings reference generated from `config/settings.schema` (the single source of keys).

The same data feeds the `settings.html` page of the generated site and the key tables of
`docs/configuration.md`, so the handwritten document cannot drift from the schema.
"""
import re

from techdoc_repo import read_text

# The schema file that declares every setting.
SCHEMA_PATH = 'config/settings.schema'
# The handwritten document that embeds the generated tables.
CONFIGURATION_DOC_PATH = 'docs/configuration.md'
# Markers between which the generated tables live inside the document.
BEGIN_MARKER = '<!-- BEGIN GENERATED SETTINGS (python3 tools/techdoc/techdoc.py settings-doc) -->'
END_MARKER = '<!-- END GENERATED SETTINGS -->'
# Titles of the schema groups, in the order of the settings window.
GROUP_TITLES = (
    ('zoom', 'Zoom'),
    ('tracking', 'Pointer tracking'),
    ('filter', 'Colour filters'),
    ('shortcuts', 'Shortcuts'),
    ('advanced', 'Advanced'),
)
# The fields of one schema line, in file order.
SCHEMA_FIELDS = ('key', 'type', 'default', 'constraint', 'group', 'label', 'help')
# Prefix that the short CLI spelling drops (contract C1).
KEY_PREFIX = 'ZOOM_'


def cli_name(key):
    """Compute the short `zoomctl set` spelling of a schema key.

    Args: key - schema key such as ZOOM_STEP_MODE.
    Returns: lower-case hyphenated name without the ZOOM_ prefix ('step-mode').
    """
    # Contract C1: lower-case, underscores become hyphens, ZOOM_ prefix dropped.
    name = key.lower().replace('_', '-')
    return name[len(KEY_PREFIX):] if key.startswith(KEY_PREFIX) else name


def parse_schema(text):
    """Parse the schema text into one dict per setting.

    Args: text - content of config/settings.schema.
    Returns: list of dicts (key, type, default, constraint, group, label, help, cli) in
             schema order; comment and blank lines are skipped.
    """
    settings = []
    for line in text.split('\n'):
        # Comments and blank lines carry no setting.
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        # The help text is last and may contain further separators.
        values = line.split('|', len(SCHEMA_FIELDS) - 1)
        if len(values) != len(SCHEMA_FIELDS):
            continue
        # Pair every value with its field name.
        setting = {field: value.strip() for field, value in zip(SCHEMA_FIELDS, values)}
        setting['cli'] = cli_name(setting['key'])
        settings.append(setting)
    return settings


def allowed_values(setting):
    """Describe what a setting accepts.

    Args: setting - parsed setting dict.
    Returns: short text such as '0.01 to 2.00', 'a, b, c' or 'on, off'.
    """
    kind, constraint = setting['type'], setting['constraint']
    # Numbers show their range, enums their options.
    if kind in ('float', 'int'):
        return constraint.replace('..', ' to ')
    if kind == 'enum':
        return ', '.join(constraint.split(','))
    # Booleans, keys and modifiers have a fixed description.
    return {'bool': 'on, off', 'key': 'a Hyprland key name, empty disables',
            'mods': 'SUPER, SHIFT, CTRL, ALT joined by " + "'}.get(kind, '')


def default_text(setting):
    """Render the default of a setting (an empty default is shown as 'empty').

    Args: setting - parsed setting dict.
    Returns: default text.
    """
    # An empty cell would look like a missing value in the table.
    return setting['default'] or 'empty'


def grouped_settings(settings):
    """Order settings by group in the order of the settings window.

    Args: settings - parsed settings in schema order.
    Returns: list of (group id, group title, settings) for every non-empty group; groups
             unknown to GROUP_TITLES follow, titled with their id.
    """
    titles = dict(GROUP_TITLES)
    group_ids = [group for group, _title in GROUP_TITLES]
    # A group added to the schema later still gets its own table.
    group_ids += sorted({item['group'] for item in settings} - set(group_ids))
    grouped = []
    for group in group_ids:
        # Empty groups get no table.
        members = [item for item in settings if item['group'] == group]
        if members:
            grouped.append((group, titles.get(group, group), members))
    return grouped


def escape_cell(text):
    """Escape a text for a markdown table cell.

    Args: text - cell text.
    Returns: text without pipe characters that would split the cell.
    """
    return text.replace('|', '\\|')


def render_group_table(title, members):
    """Render the markdown table of one group.

    Args: title - group title; members - settings of the group.
    Returns: markdown text with a level-3 heading and the table.
    """
    lines = ['### %s' % title, '',
             '| Key | `zoomctl set` name | Default | Allowed values | Meaning |',
             '|---|---|---|---|---|']
    for item in members:
        # The label leads, the schema help text explains it.
        meaning = '**%s.** %s' % (item['label'], item['help'])
        lines.append('| `%s` | `%s` | `%s` | %s | %s |' % (
            item['key'], item['cli'], default_text(item), allowed_values(item),
            escape_cell(meaning)))
    return '\n'.join(lines)


def render_settings_markdown(settings):
    """Render the generated part of docs/configuration.md.

    Args: settings - parsed settings in schema order.
    Returns: markdown text (no markers) with one table per group.
    """
    return '\n\n'.join(render_group_table(title, members)
                       for _group, title, members in grouped_settings(settings)) + '\n'


def splice_generated_block(document, generated):
    """Replace the generated block of a document, markers kept.

    Args: document - current document text; generated - new block text.
    Returns: the updated document, or None when a marker is missing.
    """
    begin = document.find(BEGIN_MARKER)
    end = document.find(END_MARKER)
    # Both markers must exist and appear in the right order.
    if begin < 0 or end < begin:
        return None
    head = document[:begin + len(BEGIN_MARKER)]
    return '%s\n\n%s\n%s' % (head, generated.rstrip('\n'), document[end:])


def load_settings(root):
    """Read and parse the schema of a repository.

    Args: root - repository root.
    Returns: list of settings ([] when the schema file does not exist).
    """
    return parse_schema(read_text(root, SCHEMA_PATH))


def expected_configuration_doc(root):
    """Compute what docs/configuration.md must contain.

    Args: root - repository root.
    Returns: the document text with the generated block refreshed, or None when the
             document or its markers are missing.
    """
    document = read_text(root, CONFIGURATION_DOC_PATH)
    block = render_settings_markdown(load_settings(root))
    return splice_generated_block(document, block) if document else None


def documented_keys(document):
    """List the keys that appear as table rows in a document.

    Args: document - markdown text.
    Returns: list of schema-style keys found in the first column of table rows.
    """
    # Table rows start with a backticked upper-case key.
    return re.findall(r'^\| `([A-Z][A-Z0-9_]*)` \|', document, re.MULTILINE)
