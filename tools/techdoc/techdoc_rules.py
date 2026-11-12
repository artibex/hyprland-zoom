"""The code-quality gate of techdoc: rules R1-R8 for shell, python and Lua files.

R1-R7 are a 1:1 port of the frozen reference implementation (the parity test
compares both).  Shell files get R1-R5 and R7, python files get R6 and R2, Lua
files get R8 (function headers, see techdoc_lua) and R2; test suites and
fixtures only get R1 (shell) and R6 (python), Lua test doubles get nothing.
"""
# Standard library: parsing, paths, patterns and records.
import ast
import os
import re
from collections import namedtuple

# Lua rules and repository access.
from techdoc_lua import check_lua_source, is_lua_test_material
from techdoc_repo import file_kind, is_test_file, read_lines, read_text

# Maximum characters per line in production files (R2).
MAX_LINE_LENGTH = 100
# Maximum function body lines in production shell files, heredocs excluded (R3).
MAX_FUNCTION_LINES = 100
# Maximum consecutive uncommented statements in production shell files (R4).
MAX_UNCOMMENTED_RUN = 3
# Maximum lines of a free comment block in production shell files (R7).
MAX_COMMENT_BLOCK = 2
# Maximum statement lines of one top-level case arm (dispatcher) in shell (R5).
MAX_DISPATCH_ARM = 10

# Rule identifiers in report order.
RULE_IDS = ('R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8')
# One-line rule titles for reports and the generated quality page.
RULE_TITLES = {
    'R1': 'Shell function header (purpose, Args, Returns, Globals)',
    'R2': 'Line length <= 100 characters',
    'R3': 'Function body <= 100 lines',
    'R4': 'At most 3 consecutive statements without a comment',
    'R5': 'Thin dispatcher (case arm <= 10 lines)',
    'R6': 'Python docstrings (module, function, class)',
    'R7': 'Comment blocks <= 2 lines, header made of contract fields only',
    'R8': 'Lua function header (purpose, Args, Returns)',
}

# Function definition at any indentation: name() { (body may follow later).
FUNCTION_PATTERN = re.compile(
    r'^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?\s*(#.*)?$')
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
# A trailing comment inside a statement line resets the R4 run.
INLINE_COMMENT_PATTERN = re.compile(r'\s#\s')

# One finding of the gate: file, 1-based line and the "Rn message" text.
Violation = namedtuple('Violation', ['path', 'line', 'text'])


def violation_rule(violation):
    """Extract the rule id from a violation.

    Args: violation - a Violation.
    Returns: the rule id such as 'R4'.
    """
    # The text always starts with the rule id followed by a blank.
    return violation.text.split(' ', 1)[0]


def format_violation(violation):
    """Render a violation in the gate output format.

    Args: violation - a Violation.
    Returns: 'path:line: Rn message'.
    """
    # Same layout as the reference implementation, byte for byte.
    return '%s:%d: %s' % (violation.path, violation.line, violation.text)


def heredoc_mask(lines):
    """Mark every line that belongs to a heredoc body (terminator included).

    Args: lines - file lines.
    Returns: list of booleans, True inside heredocs.
    """
    # The mask grows in lockstep with the lines; terminator None = outside.
    mask = []
    terminator = None
    for line in lines:
        # Inside a heredoc: mark the line and look for the terminator.
        if terminator is not None:
            mask.append(True)
            # The terminator line closes the heredoc.
            if line.strip() == terminator:
                terminator = None
            continue
        # Outside: the line itself is code, but it may open a heredoc.
        mask.append(False)
        opener = HEREDOC_PATTERN.search(line)
        # Here-strings (<<<) and comments never open a heredoc.
        if opener and '<<<' not in line and not line.lstrip().startswith('#'):
            terminator = opener.group(1)
    return mask


def header_block(lines, index):
    """Collect the contiguous comment block directly above a line.

    Args: lines - file lines; index - definition line (0-based).
    Returns: list of stripped comment lines in file order.
    """
    # Walk upwards while the lines are comments and build the block reversed.
    block = []
    cursor = index - 1
    while cursor >= 0 and lines[cursor].lstrip().startswith('#'):
        # Insert at the front to keep file order.
        block.insert(0, lines[cursor].strip())
        cursor -= 1
    return block


def purpose_pattern(name):
    """Build the regex of the purpose line `# name — <purpose>`.

    Args: name - function name.
    Returns: compiled pattern (em dash or hyphen separator).
    """
    # The name is escaped because function names may contain hyphens.
    return re.compile(r'^#\s' + re.escape(name) + r'\s(—|-)\s\S')


def header_group_sizes(block, purpose, start):
    """Count the lines of every purpose/field group and flag stray lines.

    Args: block - header lines; purpose - purpose regex; start - purpose index.
    Returns: tuple (list of group sizes, list of stray-line messages).
    """
    # Each purpose line or field line opens a group of size one.
    sizes = []
    stray = []
    for line in block[start:]:
        if purpose.match(line) or FIELD_PATTERN.match(line):
            sizes.append(1)
        elif CONTINUATION_PATTERN.match(line) and sizes:
            # An indented line extends the group above it.
            sizes[-1] += 1
        else:
            # Anything else is prose that does not belong into a contract.
            stray.append('R7 header line is no contract field: %s' % line[:50])
    return sizes, stray


def check_header(name, block, strict):
    """Validate one function contract header (R1, plus the R7 shape if strict).

    Args: name - function; block - comment lines; strict - production file.
    Returns: list of violation messages (empty when valid).
    """
    # Directive lines (shellcheck ...) are no part of the contract.
    problems = []
    block = [line for line in block if not DIRECTIVE_PATTERN.match(line)]
    purpose = purpose_pattern(name)
    # R1: the purpose line and the three mandatory fields must exist.
    if not block or not any(purpose.match(line) for line in block):
        problems.append('R1 header lacks "# %s — <purpose>"' % name)
    for field in ('Args', 'Returns', 'Globals'):
        # A missing field is named in the message.
        if not any(line.startswith('# %s:' % field) for line in block):
            problems.append('R1 header lacks "# %s:"' % field)
    # R7 shape checks only apply to production files with a header.
    if strict and block:
        start = next((i for i, line in enumerate(block) if purpose.match(line)), 0)
        if start > 0:
            problems.append('R7 header has prose above the purpose line')
        # Group sizes and stray lines are judged together.
        sizes, stray = header_group_sizes(block, purpose, start)
        problems.extend(stray)
        # A field longer than two lines is too wordy.
        if any(size > 2 for size in sizes):
            problems.append('R7 a header field exceeds 2 lines')
    return problems


def function_extents(lines, mask):
    """Locate shell function definitions with their closing line and size.

    Args: lines - file lines; mask - heredoc mask.
    Returns: list of (name, start index, end index, body lines without heredocs).
    """
    extents = []
    for index, line in enumerate(lines):
        # Heredoc bodies may look like definitions; they are never code.
        if mask[index]:
            continue
        # Only lines that look like a definition are measured.
        match = FUNCTION_PATTERN.match(line)
        if not match:
            continue
        # The function ends at the first closing brace of equal indentation.
        indent = len(line) - len(line.lstrip())
        end_index, body_lines = find_function_end(lines, mask, index, indent)
        extents.append((match.group(1), index, end_index, body_lines))
    return extents


def find_function_end(lines, mask, index, indent):
    """Find the closing brace of the function that starts at a line.

    Args: lines - file lines; mask - heredoc mask; index - definition line;
          indent - indentation of the definition.
    Returns: tuple (end index, body lines excluding heredoc lines).
    """
    body_lines = 0
    cursor = index + 1
    while cursor < len(lines):
        current = lines[cursor]
        # A lone brace at the definition's indentation closes the function.
        current_indent = len(current) - len(current.lstrip())
        closes = not mask[cursor] and current.strip() == '}' and current_indent == indent
        if closes:
            break
        # Heredoc lines do not count towards the body size (R3).
        if not mask[cursor]:
            body_lines += 1
        cursor += 1
    return cursor, body_lines


def function_spans(lines, mask):
    """Locate shell function definitions and their body sizes.

    Args: lines - file lines; mask - heredoc mask.
    Returns: list of (name, definition index, body lines excluding heredocs).
    """
    # Reduce the extents to the triple the rules need.
    return [(name, start, body_lines)
            for name, start, _end, body_lines in function_extents(lines, mask)]


def comment_runs(lines, mask):
    """Find statement runs longer than MAX_UNCOMMENTED_RUN (R4).

    Args: lines - file lines; mask - heredoc mask.
    Returns: list of 1-based line numbers where a run exceeds the limit.
    """
    offenders = []
    run_length = 0
    continued = False
    # Line 1 (shebang or header) is skipped, like in the reference.
    for index, line in enumerate(lines[1:], start=1):
        stripped = line.strip()
        # Heredoc bodies are data, not statements.
        if mask[index]:
            continue
        # A blank line ends a backslash continuation but keeps the run.
        if not stripped:
            continued = False
            continue
        # A full-line comment resets the run.
        if stripped.startswith('#'):
            run_length = 0
            continue
        # Continuation lines belong to the statement that started above.
        is_continuation = continued
        continued = stripped.endswith('\\')
        if is_continuation:
            continue
        # An inline comment documents the statement and resets the run.
        if INLINE_COMMENT_PATTERN.search(line):
            run_length = 0
            continue
        # Structural lines (fi, done, ...) carry no statement.
        if STRUCTURAL_PATTERN.match(stripped):
            continue
        # A real statement: report once when the run first exceeds the limit.
        run_length += 1
        if run_length == MAX_UNCOMMENTED_RUN + 1:
            offenders.append(index + 1)
    return offenders


def is_file_header_start(lines, start):
    """Tell whether a comment block at a line is the file header.

    Args: lines - file lines; start - first line index of the block.
    Returns: True when only blank or comment lines precede the block.
    """
    # The file header is everything above the first code line.
    return all(not line.strip() or line.lstrip().startswith('#')
               for line in lines[:start])


def free_comment_blocks(lines, mask, header_starts):
    """Find free comment blocks longer than MAX_COMMENT_BLOCK lines (R7).

    Args: lines - file lines; mask - heredoc mask; header_starts - indexes
          where function headers begin.
    Returns: list of 1-based line numbers where an oversized block starts.
    """
    offenders = []
    index = 0
    while index < len(lines):
        # Skip code and heredoc lines until a comment block begins.
        if mask[index] or not lines[index].lstrip().startswith('#'):
            index += 1
            continue
        # Consume the whole contiguous block.
        start = index
        while (index < len(lines) and lines[index].lstrip().startswith('#')
               and not mask[index]):
            index += 1
        # Directive lines never count as prose.
        prose = [line for line in lines[start:index] if not DIRECTIVE_PATTERN.match(line)]
        # Function headers and the file header may be longer.
        if start in header_starts or is_file_header_start(lines, start):
            continue
        # Prose lines beyond the limit are findings.
        if len(prose) > MAX_COMMENT_BLOCK:
            offenders.append(start + 1)
    return offenders


def dispatcher_arms(lines, mask):
    """Find oversized arms of top-level (column 0) case statements (R5).

    Args: lines - file lines; mask - heredoc mask.
    Returns: list of 1-based line numbers where an oversized arm starts.
    """
    offenders = []
    inside_case = False
    # No arm is open before the first pattern.
    arm_start = None
    arm_lines = 0
    for index, line in enumerate(lines):
        if mask[index]:
            continue
        # A column-0 `case` opens a dispatcher and resets the arm state.
        if re.match(r'^case\s', line):
            inside_case, arm_start, arm_lines = True, None, 0
            continue
        # Outside a dispatcher nothing is judged.
        if not inside_case:
            continue
        # `esac` at column 0 closes it.
        if re.match(r'^esac\b', line):
            inside_case = False
            continue
        # Blank and comment lines are no statements.
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        # The first line after a terminator is the arm pattern itself.
        if arm_start is None:
            arm_start, arm_lines = index, 0
            continue
        # A `;;` ends the arm: judge its size and start over.
        if stripped.startswith(';;') or stripped.endswith(';;'):
            if arm_lines > MAX_DISPATCH_ARM:
                offenders.append(arm_start + 1)
            # The next line starts a new arm.
            arm_start = None
            continue
        # Count the statement lines of the open arm.
        arm_lines += 1
    return offenders


def check_shell_functions(path, lines, mask, strict):
    """Apply R1, R3 and the R7 header shape to every function of a script.

    Args: path - relative path; lines - file lines; mask - heredoc mask;
          strict - True for production files.
    Returns: tuple (violations, set of header start indexes).
    """
    violations = []
    header_starts = set()
    for name, index, body_lines in function_spans(lines, mask):
        # The header block above the definition is the contract.
        block = header_block(lines, index)
        header_starts.add(index - len(block))
        for problem in check_header(name, block, strict):
            violations.append(Violation(path, index + 1, problem))
        # R3 only restricts production files.
        if strict and body_lines > MAX_FUNCTION_LINES:
            message = 'R3 function %s has %d body lines' % (name, body_lines)
            violations.append(Violation(path, index + 1, message))
    return violations, header_starts


def check_shell_lines(path, lines, mask, header_starts):
    """Apply R2, R4, R5 and R7 (free comment blocks) to a production script.

    Args: path - relative path; lines - file lines; mask - heredoc mask;
          header_starts - function header start indexes.
    Returns: list of Violation.
    """
    violations = []
    # R2: every line, heredoc bodies included.
    for number, line in enumerate(lines, start=1):
        if len(line) > MAX_LINE_LENGTH:
            violations.append(Violation(path, number, 'R2 line has %d chars' % len(line)))
    # R4: runs of uncommented statements.
    for number in comment_runs(lines, mask):
        message = 'R4 more than %d uncommented statements' % MAX_UNCOMMENTED_RUN
        violations.append(Violation(path, number, message))
    # R5: oversized dispatcher arms.
    for number in dispatcher_arms(lines, mask):
        message = 'R5 top-level case arm longer than %d lines' % MAX_DISPATCH_ARM
        violations.append(Violation(path, number, message))
    # R7: oversized free comment blocks.
    for number in free_comment_blocks(lines, mask, header_starts):
        message = 'R7 comment block longer than %d lines' % MAX_COMMENT_BLOCK
        violations.append(Violation(path, number, message))
    return violations


def check_shell_lines_of(path, lines):
    """Apply every shell rule to the lines of one script.

    Args: path - relative path (decides production or test); lines - file lines.
    Returns: list of Violation in the reference order.
    """
    # Tests and fixtures only get the relaxed rule set.
    strict = not is_test_file(path)
    mask = heredoc_mask(lines)
    # Headers and function length apply to every shell file.
    violations, header_starts = check_shell_functions(path, lines, mask, strict)
    if not strict:
        return violations
    # Production files additionally get the line-based rules.
    return violations + check_shell_lines(path, lines, mask, header_starts)


def check_python_source(path, source):
    """Apply R6 (docstrings) and R2 (line length) to python source text.

    Args: path - relative path; source - file content.
    Returns: list of Violation.
    """
    # A file that does not parse cannot be judged further.
    try:
        tree = ast.parse(source)
    except SyntaxError as error:
        message = 'R6 python syntax error: %s' % error.msg
        return [Violation(path, error.lineno or 1, message)]
    # The findings of the checks below are collected here.
    violations = []
    # R6: the module itself needs a docstring.
    if not ast.get_docstring(tree):
        violations.append(Violation(path, 1, 'R6 module docstring missing'))
    # R6: every def and class, nested ones included.
    kinds = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
    for node in ast.walk(tree):
        if isinstance(node, kinds) and not ast.get_docstring(node):
            # The message names the undocumented unit.
            message = 'R6 docstring missing for %s' % node.name
            violations.append(Violation(path, node.lineno, message))
    # R2 only restricts production files.
    if not is_test_file(path):
        violations.extend(long_python_lines(path, source))
    return violations


def long_python_lines(path, source):
    """Find python lines longer than MAX_LINE_LENGTH (R2).

    Args: path - relative path; source - file content.
    Returns: list of Violation.
    """
    found = []
    # Count characters per physical line, starting at line 1.
    for number, line in enumerate(source.split('\n'), start=1):
        if len(line) > MAX_LINE_LENGTH:
            found.append(Violation(path, number, 'R2 line has %d chars' % len(line)))
    return found


def check_lua_file(root, path):
    """Apply R8 and R2 to one Lua file.

    Args: root - repository root; path - relative path.
    Returns: list of Violation.
    """
    # Test doubles are exempt; the Lua rules return plain tuples, wrapped below.
    if is_lua_test_material(path):
        return []
    findings = check_lua_source(read_text(root, path))
    return [Violation(path, number, message) for number, message in findings]


def check_file(root, path):
    """Run the matching rule set over one tracked file.

    Args: root - repository root; path - relative path.
    Returns: list of Violation (empty for files that are not code).
    """
    # Shell scripts: R1-R5 and R7.
    kind = file_kind(root, path)
    if kind == 'shell':
        return check_shell_lines_of(path, read_lines(root, path))
    # Python files: R6 and R2.
    if kind == 'python':
        return check_python_source(path, read_text(root, path))
    # Lua files: R8 and R2.
    if kind == 'lua':
        return check_lua_file(root, path)
    return []


def check_files(root, paths):
    """Run the gate over a list of files.

    Args: root - repository root; paths - relative paths in report order.
    Returns: list of Violation in report order.
    """
    # Concatenate per-file findings; order follows the given path order.
    violations = []
    for path in paths:
        violations.extend(check_file(root, path))
    return violations


def render_report(violations):
    """Render the gate output: one line per violation plus the total line.

    Args: violations - list of Violation.
    Returns: output text with a trailing newline.
    """
    # The total line is the last line, exactly as in the reference.
    lines = [format_violation(violation) for violation in violations]
    lines.append('TOTAL %d violation(s)' % len(violations))
    return '\n'.join(lines) + '\n'


def absolute_root(root):
    """Normalise the repository root like the reference does.

    Args: root - path given on the command line.
    Returns: absolute path.
    """
    # Relative roots are resolved against the current directory.
    return os.path.abspath(root)
