"""Static extraction of the CLI help text of a shell script (never executes it).

The help text is found in the source as either a run of `echo "..."` lines or
a here-document that contains a `Usage:` line and at least one section title such as
`Commands:` or `Zoom:`.  The result describes usage lines, options, commands, further
sections and free notes for the generated cli.html.
"""
import re

# One `echo "a" "b" …` line (optionally redirected); group 1 holds the quoted args.
ECHO_PATTERN = re.compile(r'^\s*echo\s+((?:"(?:[^"\\]|\\.)*"\s*)+)(?:>&2)?\s*$')
# One double-quoted argument; group 1 is its inside.
QUOTED_ARGUMENT_PATTERN = re.compile(r'"((?:[^"\\]|\\.)*)"')
# Top-level `NAME="value"` or `NAME+="value"` without substitutions.
ASSIGNMENT_PATTERN = re.compile(r'^([A-Z][A-Z0-9_]*)(\+?)="([^"$`\\]*)"\s*$')
# A `${NAME}` or `$NAME` reference inside a printed line.
VARIABLE_REFERENCE_PATTERN = re.compile(r'\$\{([A-Z][A-Z0-9_]*)\}|\$([A-Z][A-Z0-9_]*)')
# A bare `echo` prints an empty line.
BARE_ECHO_PATTERN = re.compile(r'^\s*echo\s*(?:>&2)?\s*$')
# Here-document opener; group 1 is the terminator word.
HEREDOC_OPENER_PATTERN = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
# Escapes that a double-quoted echo string turns into the literal character.
ESCAPE_PATTERN = re.compile(r'\\(["$`\\])')
# An option or command entry: two leading blanks, a term, two+ blanks, a text.
ENTRY_PATTERN = re.compile(r'^\s{2}(\S.*?)\s{2,}(\S.*)$')
# A line that starts an entry: exactly two leading blanks, then the term.
ENTRY_START_PATTERN = re.compile(r'^ {2}\S')
# A section title: starts at column 0 and ends with a colon.
SECTION_PATTERN = re.compile(r'^(\S.*):$')
# Stand-in for the shell variable of the program name while extracting.
PROGRAM_PLACEHOLDER = '<script>'
# Section titles that map to dedicated keys of the result.
KNOWN_SECTIONS = {'Options': 'options', 'Commands': 'commands'}


def unescape_echo(text):
    """Turn the inside of an echo string into the text it prints.

    Args: text - raw characters between the double quotes.
    Returns: the printed text with `$0` replaced by PROGRAM_PLACEHOLDER.
    """
    # Backslash escapes of double-quote context collapse to the character.
    printed = ESCAPE_PATTERN.sub(r'\1', text)
    # The program name is shown as a placeholder instead of the shell variable.
    return printed.replace('$0', PROGRAM_PLACEHOLDER)


def echo_text(line):
    """Return the text printed by an echo line.

    Args: line - one source line.
    Returns: printed text, or None when the line is no simple echo.
    """
    # A bare echo prints a blank line.
    if BARE_ECHO_PATTERN.match(line):
        return ''
    match = ECHO_PATTERN.match(line)
    # Anything else (pipes, variables-only echoes, ...) is not help text.
    if not match:
        return None
    # echo joins its arguments with one blank, exactly like the shell does.
    arguments = QUOTED_ARGUMENT_PATTERN.findall(match.group(1))
    return ' '.join(unescape_echo(argument) for argument in arguments)


def logical_lines(lines):
    """Join backslash-continued source lines into one logical line each.

    Args: lines - source lines of the script.
    Returns: list of logical lines (continuations merged with one blank).
    """
    joined = []
    pending = ''
    for line in lines:
        # A trailing backslash continues the statement on the next line.
        if line.rstrip().endswith('\\'):
            pending += line.rstrip()[:-1].rstrip() + ' '
            continue
        # The continuation ends here: emit the merged statement.
        joined.append(pending + line.strip() if pending else line)
        pending = ''
    # A dangling continuation at the end of the file is kept as is.
    if pending:
        joined.append(pending.rstrip())
    return joined


def shell_assignments(lines):
    """Collect constant top-level string variables (`=` and `+=`).

    Args: lines - source lines of the script.
    Returns: dict mapping the variable name to its final value.
    """
    values = {}
    for line in lines:
        match = ASSIGNMENT_PATTERN.match(line)
        # Only column-0 constant strings are safe to evaluate statically.
        if not match:
            continue
        name, append, value = match.groups()
        # `+=` extends the value collected so far, `=` replaces it.
        values[name] = values.get(name, '') + value if append else value
    return values


def expand_variables(text, values):
    """Replace known `${NAME}`/`$NAME` references in a printed line.

    Args: text - printed help line; values - dict from shell_assignments.
    Returns: the line with every known variable expanded (unknown ones stay).
    """
    def substitute(match):
        """Return the value of one reference, or the reference itself.

        Args: match - regex match of VARIABLE_REFERENCE_PATTERN.
        Returns: replacement text.
        """
        name = match.group(1) or match.group(2)
        return values.get(name, match.group(0))
    return VARIABLE_REFERENCE_PATTERN.sub(substitute, text)


def echo_blocks(lines):
    """Collect runs of consecutive echo lines (comments and blanks may interleave).

    Args: lines - source lines of the script.
    Returns: list of text blocks, each a list of printed lines.
    """
    blocks = []
    current = []
    for line in lines:
        stripped = line.strip()
        # Comments and blank source lines do not interrupt a run.
        if not stripped or stripped.startswith('#'):
            continue
        printed = echo_text(line)
        if printed is None:
            # A non-echo statement ends the run.
            if current:
                blocks.append(current)
            current = []
        else:
            current.append(printed)
    # The file may end inside a run.
    if current:
        blocks.append(current)
    return blocks


def heredoc_blocks(lines):
    """Collect the bodies of all here-documents.

    Args: lines - source lines of the script.
    Returns: list of text blocks, each a list of lines.
    """
    blocks = []
    terminator = None
    body = []
    for line in lines:
        # Inside a heredoc: gather lines until the terminator appears.
        if terminator is not None:
            if line.strip() == terminator:
                blocks.append(body)
                terminator, body = None, []
            else:
                # Every other line belongs to the help text.
                body.append(line.replace('$0', PROGRAM_PLACEHOLDER))
            continue
        # Outside: a heredoc opener (not a here-string) starts a new body.
        opener = HEREDOC_OPENER_PATTERN.search(line)
        if opener and '<<<' not in line and not line.lstrip().startswith('#'):
            terminator = opener.group(1)
    return blocks


def find_help_block(lines):
    """Pick the block that holds the full help text.

    Args: lines - source lines of the script.
    Returns: list of printed lines, or [] when no block qualifies.
    """
    # The help block names a Usage line and at least one section title.
    for block in heredoc_blocks(lines) + echo_blocks(lines):
        has_usage = any(line.startswith('Usage:') for line in block)
        has_section = any(SECTION_PATTERN.match(line) and not line.startswith('Usage:')
                          for line in block)
        # Only a block with both parts is the help text.
        if has_usage and has_section:
            return block
    return []


def description_column(block):
    """Find the column in which the entry descriptions start.

    Args: block - printed help lines.
    Returns: the most common start column of descriptions of two-blank-separated
             entries; None when no entry has such a gap.
    """
    # Hand-aligned help texts put every description in the same column.
    columns = {}
    for line in block:
        match = ENTRY_PATTERN.match(line)
        # Lines without a two-blank gap do not vote.
        if match:
            columns[match.start(2)] = columns.get(match.start(2), 0) + 1
    return max(columns, key=columns.get) if columns else None


def split_entry(line, column):
    """Split an entry line into term and description.

    Args: line - indented help line; column - description column or None.
    Returns: tuple (term, text); text is '' for a bare term.
    """
    # A description in the aligned column wins, so one blank may separate long terms.
    if column and len(line) > column and line[column - 1] == ' ' and line[column] != ' ':
        return line[:column].strip(), line[column:].strip()
    match = ENTRY_PATTERN.match(line)
    return (match.group(1), match.group(2)) if match else (line.strip(), '')


def new_help_result():
    """Create the empty result structure.

    Args: none.
    Returns: dict with the documented keys.
    """
    # Every key exists even when the help text lacks the section.
    return {'found': False, 'intro': [], 'usage': [], 'options': [],
            'commands': [], 'sections': [], 'notes': []}


def add_entry(target, line, column):
    """Add an entry line, or append a continuation to the previous entry.

    Args: target - list of entries; line - indented help line;
          column - description column (see description_column).
    Returns: nothing (the list is modified).
    """
    # Exactly two leading blanks start a new entry.
    if ENTRY_START_PATTERN.match(line):
        term, text = split_entry(line, column)
        target.append({'term': term, 'text': text})
    elif target and line.strip():
        # A deeper indentation continues the last description.
        target[-1]['text'] = (target[-1]['text'] + ' ' + line.strip()).strip()


def target_for_section(result, title):
    """Return the entry list that belongs to a section title.

    Args: result - result dict; title - section title without colon.
    Returns: the entry list (created for unknown sections).
    """
    # Options and Commands have fixed keys, other sections are appended.
    key = KNOWN_SECTIONS.get(title)
    if key:
        return result[key]
    # Unknown section titles are appended in order of appearance.
    section = {'title': title, 'entries': []}
    result['sections'].append(section)
    return section['entries']


def parse_help_lines(block):
    """Structure the printed help lines.

    Args: block - list of printed help lines.
    Returns: dict (found, intro, usage, options, commands, sections, notes).
    """
    result = new_help_result()
    result['found'] = bool(block)
    column = description_column(block)
    # No section is open before the first title.
    target = None
    for line in block:
        # Section titles switch the target list.
        section = SECTION_PATTERN.match(line)
        if line.startswith('Usage:'):
            result['usage'].append(line[len('Usage:'):].strip())
            target = None
        elif section:
            target = target_for_section(result, section.group(1))
        elif line.startswith((' ', '\t')) and target is not None:
            add_entry(target, line, column)
        elif line.strip():
            # Free text: intro before the usage line, notes afterwards.
            bucket = 'notes' if result['usage'] else 'intro'
            result[bucket].append(line.strip())
            target = None
        elif target is not None and not line.strip():
            # A blank line closes the current section.
            target = None
    return result


def parse_help_text(source_text, program=PROGRAM_PLACEHOLDER):
    """Extract and structure the help text of a shell script.

    Args: source_text - the script source; program - name shown for `$0`.
    Returns: dict (found, intro, usage, options, commands, sections, notes).
    """
    # Continuations are merged first so wrapped echo statements stay one entry.
    lines = logical_lines(source_text.split('\n'))
    values = shell_assignments(lines)
    # Locate the help block, expand constant variables, substitute the program name.
    block = [expand_variables(line, values).replace(PROGRAM_PLACEHOLDER, program)
             for line in find_help_block(lines)]
    # Structure the printed lines into usage, options and commands.
    return parse_help_lines(block)
