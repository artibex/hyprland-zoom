"""A small YAML-subset parser for the GitHub Actions workflows (stdlib only).

Supported: block mappings and sequences, `- key: value` items, quoted and
plain scalars, flow sequences, block scalars (| and >), anchors and aliases
(kept as plain text).  Everything is returned as dict / list / str / None;
scalars are never type-converted.  Unsupported constructs degrade to plain
strings instead of raising.
"""
import re
from collections import namedtuple

# One significant source line: indentation, text without comment, line number.
Line = namedtuple('Line', ['indent', 'text', 'number', 'block'])

# Marks a value that opens a block scalar (| or >, optional chomping).
BLOCK_INDICATOR_PATTERN = re.compile(r'(^|\s)[|>][+-]?\d*$')
# A mapping key at the start of a text: plain word or quoted string.
KEY_PATTERN = re.compile(r'^("[^"]*"|\'[^\']*\'|[\w.\-/$\{\}<]+)\s*:(\s+|$)')
# Anchor in front of a value, for example `&name |`.
ANCHOR_PATTERN = re.compile(r'^&[\w-]+\s*')


def strip_comment(text):
    """Remove a trailing ` # comment` that is not inside quotes.

    Args: text - one source line without indentation.
    Returns: the text without the comment and trailing blanks.
    """
    # Track the quote state while scanning for a comment start.
    quote = ''
    for position, character in enumerate(text):
        if quote:
            # Inside quotes only the matching quote ends the state.
            if character == quote:
                quote = ''
        elif character in '"\'':
            quote = character
        elif character == '#' and (position == 0 or text[position - 1] in ' \t'):
            # A hash after a blank (or at the start) begins the comment.
            return text[:position].rstrip()
    return text.rstrip()


def indentation(raw_line):
    """Count the leading blanks of a line.

    Args: raw_line - the source line.
    Returns: number of leading spaces.
    """
    # Tabs are not valid YAML indentation, so only spaces count.
    return len(raw_line) - len(raw_line.lstrip(' '))


def collect_block_scalar(raw_lines, start, parent_indent):
    """Gather the lines of a block scalar that follow its indicator.

    Args: raw_lines - all source lines; start - index after the indicator
          line; parent_indent - indentation of the indicator line.
    Returns: tuple (text of the block, index of the first line after it).
    """
    collected = []
    position = start
    while position < len(raw_lines):
        raw = raw_lines[position]
        # Blank lines belong to the block, shallower content ends it.
        if raw.strip() and indentation(raw) <= parent_indent:
            break
        collected.append(raw.strip())
        position += 1
    # Trailing blank lines are chomped away.
    while collected and not collected[-1]:
        collected.pop()
    return '\n'.join(collected), position


def tokenize(text):
    """Turn YAML text into significant lines, folding block scalars.

    Args: text - the whole YAML document.
    Returns: list of Line (comments and blank lines removed).
    """
    raw_lines = text.split('\n')
    lines = []
    position = 0
    while position < len(raw_lines):
        raw = raw_lines[position]
        position += 1
        # Remember the 1-based number of this line for later reports.
        number = position
        stripped = raw.strip()
        # Skip blank lines and full-line comments, and document markers.
        if not stripped or stripped.startswith('#') or stripped in ('---', '...'):
            continue
        content = strip_comment(stripped)
        block = None
        # A block scalar swallows the deeper-indented lines below it.
        if BLOCK_INDICATOR_PATTERN.search(content):
            block, position = collect_block_scalar(raw_lines, position, indentation(raw))
        lines.append(Line(indentation(raw), content, number, block))
    return lines


def split_key(text):
    """Split `key: value` at the first mapping colon.

    Args: text - the line text without indentation.
    Returns: tuple (key, value) or None when the text is not a mapping entry.
    """
    # The key pattern guards against colons inside plain scalars.
    match = KEY_PATTERN.match(text)
    if not match:
        return None
    # Quotes around the key are not part of its name.
    key = match.group(1).strip('"\'')
    return key, text[match.end():].strip()


def split_flow_items(text):
    """Split the inside of a flow sequence at top-level commas.

    Args: text - content between the brackets.
    Returns: list of stripped item strings.
    """
    items = []
    current = ''
    # Nesting depth of brackets decides which commas split.
    depth = 0
    quote = ''
    for character in text:
        # Commas inside quotes or nested brackets stay part of the item.
        if quote:
            quote = '' if character == quote else quote
        elif character in '"\'':
            quote = character
        elif character in '[{':
            # Opening brackets nest deeper.
            depth += 1
        elif character in ']}':
            depth -= 1
        elif character == ',' and depth == 0:
            # A top-level comma ends the current item.
            items.append(current.strip())
            current = ''
            continue
        current += character
    # The last item has no trailing comma.
    if current.strip():
        items.append(current.strip())
    return items


def parse_scalar(text):
    """Convert a scalar token: unquote strings, split flow sequences.

    Args: text - the value text.
    Returns: str, list (flow sequence) or None for an empty value.
    """
    # An anchor in front of the value is irrelevant for the documentation.
    text = ANCHOR_PATTERN.sub('', text.strip())
    if not text or text == '~':
        return None
    # Flow sequence: parse every item as scalar again.
    if text.startswith('[') and text.endswith(']'):
        return [parse_scalar(item) for item in split_flow_items(text[1:-1])]
    # Matching quotes are removed, everything else stays verbatim.
    if len(text) >= 2 and text[0] == text[-1] and text[0] in '"\'':
        return text[1:-1]
    return text


class Parser:
    """Recursive-descent parser over the tokenised lines of one document."""

    def __init__(self, lines):
        """Create a parser.

        Args: lines - list of Line from tokenize().
        Returns: nothing.
        """
        # The list is mutated when `- key: v` is rewritten into a mapping line.
        self.lines = list(lines)

    def parse_node(self, position, indent):
        """Parse the node that starts at a line.

        Args: position - line index; indent - indentation of the node.
        Returns: tuple (value, next index).
        """
        # A dash starts a sequence, anything else is read as mapping.
        text = self.lines[position].text
        if text == '-' or text.startswith('- '):
            return self.parse_sequence(position, indent)
        # Anything with a key is a mapping.
        if split_key(text):
            return self.parse_mapping(position, indent)
        # A bare scalar line (for example a continued plain scalar).
        return parse_scalar(text), position + 1

    def parse_sequence(self, position, indent):
        """Parse consecutive `- item` lines of equal indentation.

        Args: position - first dash line; indent - dash indentation.
        Returns: tuple (list, next index).
        """
        items = []
        while position < len(self.lines):
            # Stop at the first line that is no item at this indentation.
            line = self.lines[position]
            is_item = line.text == '-' or line.text.startswith('- ')
            if line.indent != indent or not is_item:
                break
            # Parse the item and move on.
            value, position = self.parse_sequence_item(position, indent)
            items.append(value)
        return items, position

    def parse_sequence_item(self, position, indent):
        """Parse one dash item (scalar, inline mapping or nested node).

        Args: position - dash line index; indent - dash indentation.
        Returns: tuple (value, next index).
        """
        line = self.lines[position]
        rest = line.text[1:].lstrip()
        offset = indent + len(line.text) - len(rest)
        # `- |` block scalar: the folded text is the item.
        if line.block is not None:
            return line.block, position + 1
        # `-` alone: the item is the deeper node below.
        if not rest:
            return self.parse_nested(position + 1, indent)
        # `- key: value` starts a mapping whose keys align after the dash.
        if split_key(rest):
            self.lines[position] = Line(offset, rest, line.number, None)
            return self.parse_mapping(position, offset)
        # Plain scalar item.
        return parse_scalar(rest), position + 1

    def parse_nested(self, position, parent_indent):
        """Parse a child node deeper than its parent, if there is one.

        Args: position - index of the candidate child; parent_indent - parent.
        Returns: tuple (value or None, next index).
        """
        # No deeper line means an empty value.
        if position >= len(self.lines) or self.lines[position].indent <= parent_indent:
            return None, position
        return self.parse_node(position, self.lines[position].indent)

    def parse_mapping(self, position, indent):
        """Parse consecutive `key: value` lines of equal indentation.

        Args: position - first key line; indent - key indentation.
        Returns: tuple (dict, next index).
        """
        mapping = {}
        while position < len(self.lines):
            line = self.lines[position]
            entry = split_key(line.text)
            # A different indentation or a non-key line ends the mapping.
            if line.indent != indent or entry is None:
                break
            key, rest = entry
            # The value may be a scalar or a nested block.
            value, position = self.parse_mapping_value(position, indent, rest)
            mapping[key] = value
        return mapping, position

    def parse_mapping_value(self, position, indent, rest):
        """Parse the value of the mapping entry at a line.

        Args: position - key line index; indent - key indentation;
              rest - text after the colon.
        Returns: tuple (value, next index).
        """
        line = self.lines[position]
        # Block scalar value (`key: |`).
        if line.block is not None:
            return line.block, position + 1
        # Inline value on the same line.
        if rest:
            return parse_scalar(rest), position + 1
        # Sequence at the same indentation is legal below a key.
        following = position + 1
        if following < len(self.lines):
            # A sequence at the key's indentation belongs to the key.
            next_line = self.lines[following]
            is_item = next_line.text == '-' or next_line.text.startswith('- ')
            if next_line.indent == indent and is_item:
                return self.parse_sequence(following, indent)
        # Otherwise a deeper block (or nothing) is the value.
        return self.parse_nested(following, indent)


def parse_yaml(text):
    """Parse a YAML document of the supported subset.

    Args: text - the document text.
    Returns: dict / list / str / None (an empty document gives None).
    """
    # Tokenise first; an empty document has no root node.
    lines = tokenize(text)
    if not lines:
        return None
    # The root node starts at the first significant line.
    value, _position = Parser(lines).parse_node(0, lines[0].indent)
    return value
