"""Lua support of techdoc: the function-header gate (R8) and the contract parser.

Lua functions follow the same contract as shell functions, written with `--`:

    -- name — purpose in one sentence.
    -- Args:    what comes in
    -- Returns: what goes out
    -- Notes:   optional trap or reason

The rules return plain `(line, message)` tuples; techdoc_rules wraps them into
Violation objects so that this module needs no import from the rule module.
"""
import os
import re

# Maximum characters per line in production Lua files (R2).
MAX_LUA_LINE_LENGTH = 100
# `local function name(` or `function a.b:name(` at any indentation; group 1 is the name.
LUA_FUNCTION_PATTERN = re.compile(
    r'^\s*(?:local\s+function\s+([A-Za-z_]\w*)|function\s+([A-Za-z_][\w.:]*))\s*\(')
# A comment line of any indentation (block comments are not used in this project).
LUA_COMMENT_PATTERN = re.compile(r'^\s*--')
# One field line of the contract; group 1 is the field name.
LUA_FIELD_PATTERN = re.compile(r'^--\s(Args|Returns|Notes):\s+\S')
# Continuation of the previous field or purpose line (three or more blanks).
LUA_CONTINUATION_PATTERN = re.compile(r'^--\s{3,}\S')
# Fields every function header must carry.
REQUIRED_FIELDS = ('Args', 'Returns')
# Contract fields in documentation order.
LUA_CONTRACT_FIELDS = ('Args', 'Returns', 'Notes')


def function_name(line):
    """Extract the name of the function defined on a line.

    Args: line - one source line.
    Returns: the last identifier of the definition (`M.trim` gives 'trim');
             None when the line defines no named function.
    """
    # Anonymous callbacks (`function(`) never match, so they need no header.
    match = LUA_FUNCTION_PATTERN.match(line)
    if not match:
        return None
    # Either the local or the global form matched.
    dotted = match.group(1) or match.group(2)
    return re.split(r'[.:]', dotted)[-1]


def purpose_pattern(name):
    """Build the regex of the purpose line `-- name — purpose`.

    Args: name - function name (the last identifier).
    Returns: compiled pattern; an optional `Module.` prefix is accepted.
    """
    # The qualifier allows `-- M.check_file — ...` for `function M.check_file`.
    return re.compile(r'^--\s(?:[\w.:]*[.:])?' + re.escape(name) + r'\s(—|-)\s\S')


def header_block(lines, index):
    """Collect the contiguous comment block directly above a line.

    Args: lines - file lines; index - definition line (0-based).
    Returns: list of stripped comment lines in file order.
    """
    # Walk upwards while the lines are comments and build the block reversed.
    block = []
    cursor = index - 1
    while cursor >= 0 and LUA_COMMENT_PATTERN.match(lines[cursor]):
        # Insert at the front to keep file order.
        block.insert(0, lines[cursor].strip())
        cursor -= 1
    return block


def check_header(name, block):
    """Validate the contract header of one Lua function.

    Args: name - function name; block - comment lines above the definition.
    Returns: list of problem messages (empty when valid).
    """
    problems = []
    # The purpose line names the function and states what it does.
    purpose = purpose_pattern(name)
    if not any(purpose.match(line) for line in block):
        problems.append('R8 header lacks "-- %s — <purpose>"' % name)
    # Args and Returns are mandatory, Notes is optional.
    for field in REQUIRED_FIELDS:
        if not any(line.startswith('-- %s:' % field) for line in block):
            problems.append('R8 header lacks "-- %s:"' % field)
    return problems


def is_lua_test_material(path):
    """Tell whether a Lua file belongs to the test tree (exempt from the Lua gate).

    Args: path - repository-relative path.
    Returns: True for anything below tests/ and for test_*.lua / fixtures.
    """
    # Test doubles define dozens of one-line fake methods; they stay outside the gate.
    base_name = os.path.basename(path)
    in_test_tree = path.startswith('tests/') or '/fixtures/' in path
    return in_test_tree or base_name.startswith(('test_', 'test-'))


def check_lua_source(text):
    """Apply R8 (function headers) and R2 (line length) to a production Lua file.

    Args: text - file content.
    Returns: list of (line number, message) tuples in file order.
    """
    findings = []
    lines = text.split('\n')
    for index, line in enumerate(lines):
        # R2: the same limit as for shell and python.
        if len(line) > MAX_LUA_LINE_LENGTH:
            findings.append((index + 1, 'R2 line has %d chars' % len(line)))
        # R8: every named function carries the contract header.
        name = function_name(line)
        if name:
            # Each missing field becomes one finding.
            for problem in check_header(name, header_block(lines, index)):
                findings.append((index + 1, problem))
    return findings


def strip_marker(line):
    """Remove the leading `--` marker and one blank from a comment line.

    Args: line - a Lua comment line.
    Returns: the text after the marker.
    """
    # The marker may be indented; one blank after it belongs to the marker.
    text = line.strip()[2:]
    return text[1:] if text.startswith(' ') else text


def parse_lua_contract(name, block):
    """Parse the contract header above a Lua function.

    Args: name - function name; block - header comment lines.
    Returns: dict with purpose, Args, Returns, Notes (strings, '' when absent).
    """
    contract = {'purpose': '', 'Args': '', 'Returns': '', 'Notes': ''}
    purpose = purpose_pattern(name)
    current = None
    for line in block:
        field = LUA_FIELD_PATTERN.match(line)
        if purpose.match(line):
            # `-- name — text`: the text after the separator is the purpose.
            current = 'purpose'
            contract[current] = re.split(r'\s(?:—|-)\s', line, maxsplit=1)[1].strip()
        elif field:
            # `-- Args: text`: the field text starts after the colon.
            current = field.group(1)
            contract[current] = line.split(':', 1)[1].strip()
        elif LUA_CONTINUATION_PATTERN.match(line) and current:
            # Indented continuation of the previous item.
            contract[current] += ' ' + strip_marker(line).strip()
    return contract


def lua_functions(text):
    """List the named functions of a Lua file with their parsed contracts.

    Args: text - file content.
    Returns: list of dicts (name, line, public, documented, contract).
    """
    lines = text.split('\n')
    functions = []
    for index, line in enumerate(lines):
        name = function_name(line)
        if not name:
            continue
        # The comment block above the line is the contract.
        block = header_block(lines, index)
        # `local function` is private to the module; everything else is its interface.
        functions.append({
            'name': name, 'line': index + 1,
            'public': not line.lstrip().startswith('local '),
            'documented': not check_header(name, block),
            'contract': parse_lua_contract(name, block),
        })
    return functions


def lua_file_purpose(text):
    """Read the purpose from the first comment line of a Lua file.

    Args: text - file content.
    Returns: the text after `-- name — ` of the first line, else the whole first
             comment line; '' when the file starts with code.
    """
    # Only a comment on the very first lines can be the file header.
    for line in text.split('\n')[:3]:
        if LUA_COMMENT_PATTERN.match(line):
            body = strip_marker(line).strip()
            # `name — text` yields the text; anything else is used whole.
            parts = re.split(r'\s(?:—|-)\s', body, maxsplit=1)
            return parts[1].strip() if len(parts) == 2 else body
    return ''
