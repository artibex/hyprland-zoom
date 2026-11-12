#!/usr/bin/env python3
"""Reference implementation of the frozen code-quality rules (R1-R7, R6 = Python).

Wave-1 children use it to self-check; the techdoc gate must reproduce the
exact same verdicts. Usage: qa-precheck.py <repo> [file ...]
"""
import ast
import os
import re
import subprocess
import sys

# Maximum characters per line in production files (R2).
MAX_LINE_LENGTH = 100
# Maximum function body lines in production shell files, heredocs excluded (R3).
MAX_FUNCTION_LINES = 100
# Maximum consecutive uncommented statements in production shell files (R4).
MAX_UNCOMMENTED_RUN = 3
# Maximum lines of a free comment block in production shell files (R7).
MAX_COMMENT_BLOCK = 2
# Maximum statement lines of one top-level case arm (dispatcher) in production shell (R5).
MAX_DISPATCH_ARM = 10

# Function definition at any indentation: name() { (body may follow later).
FUNCTION_PATTERN = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?\s*(#.*)?$')
# Lines that only close or continue control structures carry no statement.
STRUCTURAL_PATTERN = re.compile(
    r'^(fi|done|esac|\}|;;|;&|;;&|else|then|do|\{|\(|\)|\};?|done\s*[<|].*|'
    r'esac\s*[;|].*|fi\s*[;|].*|[^()]*\)|\*\))$')
# Heredoc opener; the captured word is the terminator line.
HEREDOC_PATTERN = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')
# Header field lines of the function contract.
FIELD_PATTERN = re.compile(r'^#\s(Args|Returns|Globals|Notes):\s+\S')
# Continuation of a header field or purpose (indented by at least 3 blanks).
CONTINUATION_PATTERN = re.compile(r'^#\s{3,}\S')
# Comment lines that are tool directives, never counted as prose.
DIRECTIVE_PATTERN = re.compile(r'^\s*#\s*(shellcheck|hisinone-entrypoint-capability)\b')


def tracked_files(repo):
    """Return all git-tracked file paths of the repository.

    Args: repo - repository root. Returns: list of relative paths.
    """
    listing = subprocess.run(['git', '-C', repo, 'ls-files'],
                             capture_output=True, text=True, check=True)
    return [line for line in listing.stdout.split('\n') if line]


def is_shell_file(repo, path):
    """Tell whether a tracked file is a shell script (.sh or sh shebang).

    Args: repo - root; path - relative path. Returns: True for shell scripts.
    """
    if path.endswith('.sh'):
        return True
    full_path = os.path.join(repo, path)
    if not os.path.isfile(full_path):
        return False
    with open(full_path, 'rb') as handle:
        first_line = handle.readline()
    return first_line.startswith(b'#!') and re.search(rb'\b(ba)?sh\b', first_line) is not None


def is_test_file(path):
    """Tell whether a path is a test suite (headers only, R1).

    Args: path - relative path. Returns: True for test-*.sh / test_*.py / fixtures.
    """
    base_name = os.path.basename(path)
    return (base_name.startswith('test-') or base_name.startswith('test_')
            or '/fixtures/' in path)


def heredoc_mask(lines):
    """Mark every line that belongs to a heredoc body (terminator included).

    Args: lines - file lines. Returns: list of booleans, True inside heredocs.
    """
    mask = []
    terminator = None
    for line in lines:
        if terminator is not None:
            mask.append(True)
            if line.strip() == terminator:
                terminator = None
            continue
        mask.append(False)
        opener = HEREDOC_PATTERN.search(line)
        if opener and '<<<' not in line and not line.lstrip().startswith('#'):
            terminator = opener.group(1)
    return mask


def header_block(lines, index):
    """Collect the contiguous comment block directly above line index.

    Args: lines - file lines; index - definition line. Returns: list of lines.
    """
    block = []
    cursor = index - 1
    while cursor >= 0 and lines[cursor].lstrip().startswith('#'):
        block.insert(0, lines[cursor].strip())
        cursor -= 1
    return block


def check_header(name, block, strict):
    """Validate one function contract header (R1, plus R7 shape when strict).

    Args: name - function; block - comment lines; strict - production file.
    Returns: list of violation messages (empty when valid).
    """
    problems = []
    block = [line for line in block if not DIRECTIVE_PATTERN.match(line)]
    purpose = re.compile(r'^#\s' + re.escape(name) + r'\s(—|-)\s\S')
    if not block or not any(purpose.match(line) for line in block):
        problems.append('R1 header lacks "# %s — <purpose>"' % name)
    for field in ('Args', 'Returns', 'Globals'):
        if not any(line.startswith('# %s:' % field) for line in block):
            problems.append('R1 header lacks "# %s:"' % field)
    if strict and block:
        start = next((i for i, line in enumerate(block) if purpose.match(line)), 0)
        if start > 0:
            problems.append('R7 header has prose above the purpose line')
        groups = []
        for line in block[start:]:
            if purpose.match(line) or FIELD_PATTERN.match(line):
                groups.append(1)
            elif CONTINUATION_PATTERN.match(line) and groups:
                groups[-1] += 1
            else:
                problems.append('R7 header line is no contract field: %s' % line[:50])
        if any(size > 2 for size in groups):
            problems.append('R7 a header field exceeds 2 lines')
    return problems


def function_spans(lines, mask):
    """Locate shell function definitions and their body sizes.

    Args: lines - file lines; mask - heredoc mask.
    Returns: list of (name, definition index, body lines excluding heredocs).
    """
    spans = []
    for index, line in enumerate(lines):
        if mask[index]:
            continue
        match = FUNCTION_PATTERN.match(line)
        if not match:
            continue
        indent = len(line) - len(line.lstrip())
        body_lines = 0
        cursor = index + 1
        while cursor < len(lines):
            current = lines[cursor]
            closes = (not mask[cursor] and current.strip() == '}'
                      and len(current) - len(current.lstrip()) == indent)
            if closes:
                break
            if not mask[cursor]:
                body_lines += 1
            cursor += 1
        spans.append((match.group(1), index, body_lines))
    return spans


def comment_runs(lines, mask):
    """Find statement runs longer than MAX_UNCOMMENTED_RUN (R4).

    Args: lines - file lines; mask - heredoc mask. Returns: list of line numbers.
    """
    offenders = []
    run_length = 0
    continued = False
    for index, line in enumerate(lines[1:], start=1):
        stripped = line.strip()
        if mask[index]:
            continue
        if not stripped:
            continued = False
            continue
        if stripped.startswith('#'):
            run_length = 0
            continue
        is_continuation = continued
        continued = stripped.endswith('\\')
        if is_continuation:
            continue
        if re.search(r'\s#\s', line):
            run_length = 0
            continue
        if STRUCTURAL_PATTERN.match(stripped):
            continue
        run_length += 1
        if run_length == MAX_UNCOMMENTED_RUN + 1:
            offenders.append(index + 1)
    return offenders


def free_comment_blocks(lines, mask, header_starts):
    """Find free comment blocks longer than MAX_COMMENT_BLOCK lines (R7).

    Args: lines; mask; header_starts - indexes of function headers.
    Returns: list of line numbers where an oversized block starts.
    """
    offenders = []
    index = 0
    while index < len(lines):
        if mask[index] or not lines[index].lstrip().startswith('#'):
            index += 1
            continue
        start = index
        while index < len(lines) and lines[index].lstrip().startswith('#') and not mask[index]:
            index += 1
        prose = [line for line in lines[start:index] if not DIRECTIVE_PATTERN.match(line)]
        is_file_header = all(not l.strip() or l.lstrip().startswith('#')
                             for l in lines[:start])
        if start in header_starts or is_file_header:
            continue
        if len(prose) > MAX_COMMENT_BLOCK:
            offenders.append(start + 1)
    return offenders


def dispatcher_arms(lines, mask):
    """Find oversized arms of top-level (column 0) case statements (R5).

    Args: lines - file lines; mask - heredoc mask. Returns: list of line numbers.
    """
    offenders = []
    inside_case = False
    arm_start = None
    arm_lines = 0
    for index, line in enumerate(lines):
        if mask[index]:
            continue
        if re.match(r'^case\s', line):
            inside_case, arm_start, arm_lines = True, None, 0
            continue
        if not inside_case:
            continue
        if re.match(r'^esac\b', line):
            inside_case = False
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if arm_start is None:
            arm_start, arm_lines = index, 0
            continue
        if stripped.startswith(';;') or stripped.endswith(';;'):
            if arm_lines > MAX_DISPATCH_ARM:
                offenders.append(arm_start + 1)
            arm_start = None
            continue
        arm_lines += 1
    return offenders


def check_shell(repo, path):
    """Apply R1-R5 and R7 to one shell script.

    Args: repo - root; path - relative path. Returns: list of violation strings.
    """
    with open(os.path.join(repo, path), errors='replace') as handle:
        lines = handle.read().split('\n')
    strict = not is_test_file(path)
    mask = heredoc_mask(lines)
    violations = []
    header_starts = set()
    for name, index, body_lines in function_spans(lines, mask):
        block = header_block(lines, index)
        header_starts.add(index - len(block))
        for problem in check_header(name, block, strict):
            violations.append('%s:%d: %s' % (path, index + 1, problem))
        if strict and body_lines > MAX_FUNCTION_LINES:
            violations.append('%s:%d: R3 function %s has %d body lines'
                              % (path, index + 1, name, body_lines))
    if not strict:
        return violations
    for number, line in enumerate(lines, start=1):
        if len(line) > MAX_LINE_LENGTH:
            violations.append('%s:%d: R2 line has %d chars' % (path, number, len(line)))
    for number in comment_runs(lines, mask):
        violations.append('%s:%d: R4 more than %d uncommented statements'
                          % (path, number, MAX_UNCOMMENTED_RUN))
    for number in dispatcher_arms(lines, mask):
        violations.append('%s:%d: R5 top-level case arm longer than %d lines'
                          % (path, number, MAX_DISPATCH_ARM))
    for number in free_comment_blocks(lines, mask, header_starts):
        violations.append('%s:%d: R7 comment block longer than %d lines'
                          % (path, number, MAX_COMMENT_BLOCK))
    return violations


def check_python(repo, path):
    """Apply R6 (docstrings) and R2 (line length) to one Python file.

    Args: repo - root; path - relative path. Returns: list of violation strings.
    """
    with open(os.path.join(repo, path), errors='replace') as handle:
        source = handle.read()
    tree = ast.parse(source)
    violations = []
    if not ast.get_docstring(tree):
        violations.append('%s:1: R6 module docstring missing' % path)
    for node in ast.walk(tree):
        kinds = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
        if isinstance(node, kinds) and not ast.get_docstring(node):
            violations.append('%s:%d: R6 docstring missing for %s'
                              % (path, node.lineno, node.name))
    if not is_test_file(path):
        for number, line in enumerate(source.split('\n'), start=1):
            if len(line) > MAX_LINE_LENGTH:
                violations.append('%s:%d: R2 line has %d chars'
                                  % (path, number, len(line)))
    return violations


def main(arguments):
    """Run the checks over the given files or the whole repository.

    Args: arguments - argv tail. Returns: process exit code (0 clean, 1 dirty).
    """
    repo = os.path.abspath(arguments[0])
    selected = arguments[1:] or tracked_files(repo)
    violations = []
    for path in selected:
        if is_shell_file(repo, path):
            violations += check_shell(repo, path)
        elif path.endswith('.py'):
            violations += check_python(repo, path)
    for violation in violations:
        print(violation)
    print('TOTAL %d violation(s)' % len(violations))
    return 1 if violations else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
