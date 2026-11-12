"""Static analysis of shell and python scripts for the generated documentation.

Produces one plain dict per script (header, purpose, functions with parsed
contract fields, metrics) and links calls / called-by across the repository.
The code is only read, never executed.
"""
import ast
import re

# Repository access and the gate's parsing helpers.
from techdoc_repo import is_test_file, read_lines
from techdoc_rules import (CONTINUATION_PATTERN, DIRECTIVE_PATTERN, FIELD_PATTERN,
                           check_header, function_extents, header_block, heredoc_mask,
                           purpose_pattern)

# Characters that separate commands inside one shell line.
COMMAND_SEPARATOR_PATTERN = re.compile(r'&&|\|\||\$\(|[;|(`]|\bthen\b|\bdo\b|\belse\b')
# A header line that only draws a rule (no letters or digits at all).
DECORATION_PATTERN = re.compile(r'^[\W_]*$')
# Lines at the top of a file that are searched for the header comment.
MAX_HEADER_SEARCH_LINES = 80
# A function definition line; the header is always above the first one.
FUNCTION_START_PATTERN = re.compile(r'^\s*(?:function\s+)?[A-Za-z_][\w-]*\s*\(\)')
# Maximum length of a purpose line in tables.
MAX_PURPOSE_LENGTH = 160
# Contract field names in documentation order.
CONTRACT_FIELDS = ('Args', 'Returns', 'Globals', 'Notes')


def shorten(text, limit=MAX_PURPOSE_LENGTH):
    """Shorten a text to a limit, marking the cut.

    Args: text - input; limit - maximum length (default MAX_PURPOSE_LENGTH).
    Returns: the text or its truncated form ending in an ellipsis.
    """
    # Short texts pass unchanged.
    if len(text) <= limit:
        return text
    return text[:limit - 1].rstrip() + '…'


def strip_comment_marker(line):
    """Remove the leading `#` marker and one blank from a comment line.

    Args: line - a comment line.
    Returns: the text after the marker.
    """
    # The hash may be indented; one blank after it belongs to the marker.
    text = line.strip()[1:]
    return text[1:] if text.startswith(' ') else text


def comment_block_texts(lines, start):
    """Read the contiguous comment block that starts at a line.

    Args: lines - file lines; start - index of the first comment line.
    Returns: tuple (texts without markers, decoration and directives, next index).
    """
    texts = []
    position = start
    while position < len(lines) and lines[position].lstrip().startswith('#'):
        text = strip_comment_marker(lines[position])
        position += 1
        # Pure rule lines (─────) and tool directives carry no information.
        is_rule = DECORATION_PATTERN.match(text) and text.strip()
        if not is_rule and not DIRECTIVE_PATTERN.match('# ' + text):
            texts.append(text)
    return texts, position


def file_header_lines(lines):
    """Extract the file header: the first prose comment block near the top.

    Args: lines - file lines.
    Returns: list of header texts without marker and decoration lines.
    """
    position = 0
    # Code (such as `set -euo pipefail`) may precede the header; stop at functions.
    while position < min(len(lines), MAX_HEADER_SEARCH_LINES):
        if FUNCTION_START_PATTERN.match(lines[position]):
            break
        if lines[position].lstrip().startswith('#') and not lines[position].startswith('#!'):
            texts, position = comment_block_texts(lines, position)
            # The first block with real words is the header.
            if any(re.search(r'\w', text) for text in texts):
                return texts
        else:
            position += 1
    return []


def header_purpose(header):
    """Pick the purpose sentence from a file header.

    Args: header - list of header texts.
    Returns: the first non-empty line, shortened ('' when there is none).
    """
    # The first meaningful line states what the script is.
    for text in header:
        if text.strip():
            return shorten(text.strip())
    return ''


def parse_contract(name, block):
    """Parse the contract header above a function.

    Args: name - function name; block - header comment lines.
    Returns: dict with purpose, Args, Returns, Globals, Notes (strings).
    """
    contract = {'purpose': '', 'Args': '', 'Returns': '', 'Globals': '', 'Notes': ''}
    purpose = purpose_pattern(name)
    current = None
    for line in block:
        # Directive lines are no contract content.
        if DIRECTIVE_PATTERN.match(line):
            continue
        field = FIELD_PATTERN.match(line)
        if purpose.match(line):
            # `# name — text`: the text after the separator is the purpose.
            current = 'purpose'
            contract[current] = re.split(r'\s(?:—|-)\s', line, maxsplit=1)[1].strip()
        elif field:
            # `# Args: text`: the field text starts after the colon.
            current = field.group(1)
            contract[current] = line.split(':', 1)[1].strip()
        elif CONTINUATION_PATTERN.match(line) and current:
            # Indented continuation of the previous item.
            contract[current] += ' ' + line.lstrip('#').strip()
        elif not contract['purpose'] and not current and line.lstrip('#').strip():
            # Legacy headers without the contract keep their first sentence.
            contract['purpose'] = line.lstrip('#').strip()
    return contract


def command_words(lines, mask, start, end):
    """Collect the first word of every command in a line range.

    Args: lines - file lines; mask - heredoc mask; start/end - index range.
    Returns: set of words that appear in command position.
    """
    words = set()
    for index in range(start, end):
        stripped = lines[index].strip()
        # Heredoc bodies and comments contain no commands.
        if mask[index] or not stripped or stripped.startswith('#'):
            continue
        # Each separator-delimited segment starts with a command word.
        for segment in COMMAND_SEPARATOR_PATTERN.split(stripped):
            tokens = segment.strip().lstrip('!').split()
            if tokens:
                # The first word of a segment is the command that runs.
                words.add(tokens[0])
    return words


def count_line_kinds(lines, mask):
    """Count blank, comment and code lines of a script.

    Args: lines - file lines; mask - heredoc mask.
    Returns: dict (total, blank, comment, code).
    """
    # A trailing newline produces one empty element that is no line.
    if lines and lines[-1] == '':
        lines = lines[:-1]
    # Counters for the two non-code line kinds.
    blank = comment = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped and not mask[index]:
            blank += 1
        # A comment line outside heredocs counts as comment.
        elif stripped.startswith('#') and not mask[index]:
            comment += 1
    return {'total': len(lines), 'blank': blank, 'comment': comment,
            'code': len(lines) - blank - comment}


def analyze_shell_function(lines, mask, extent):
    """Describe one shell function.

    Args: lines - file lines; mask - heredoc mask; extent - tuple from
          function_extents (name, start, end, body lines).
    Returns: dict (name, line, end_line, body_lines, contract, header_ok, words).
    """
    name, start, end, body_lines = extent
    # The contract sits directly above the definition.
    block = header_block(lines, start)
    return {
        'name': name,
        'line': start + 1,
        'end_line': end + 1,
        'body_lines': body_lines,
        'contract': parse_contract(name, block),
        'header_ok': not check_header(name, block, False),
        'words': command_words(lines, mask, start + 1, end),
        'calls': [],
        'called_by': [],
    }


def analyze_shell(root, path):
    """Analyse one shell script.

    Args: root - repository root; path - relative path.
    Returns: dict describing header, functions and metrics.
    """
    lines = read_lines(root, path)
    mask = heredoc_mask(lines)
    # Functions in definition order with their parsed contracts.
    functions = [analyze_shell_function(lines, mask, extent)
                 for extent in function_extents(lines, mask)]
    header = file_header_lines(lines)
    return {
        'path': path,
        'kind': 'shell',
        'is_test': is_test_file(path),
        'header': header,
        'purpose': header_purpose(header),
        'functions': functions,
        'metrics': count_line_kinds(lines, mask),
    }


def docstring_summary(docstring):
    """Take the first line of a docstring.

    Args: docstring - full docstring or None.
    Returns: the first line ('' for None).
    """
    # Missing docstrings summarise to the empty string.
    if not docstring:
        return ''
    return docstring.strip().split('\n', 1)[0].strip()


def called_names(node):
    """Collect the names of everything called inside an AST node.

    Args: node - an ast node (function or class).
    Returns: set of called function / method names.
    """
    names = set()
    # Both plain calls (f()) and attribute calls (self.f()) count.
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            # Plain names and attributes are the two call forms.
            target = child.func
            if isinstance(target, ast.Name):
                names.add(target.id)
            # A method call contributes its attribute name.
            elif isinstance(target, ast.Attribute):
                names.add(target.attr)
    return names


def python_signature(node):
    """Render the parameter list of a function node.

    Args: node - FunctionDef / AsyncFunctionDef / ClassDef.
    Returns: text such as '(root, path)' ('' for classes).
    """
    # Classes have no parameter list of their own.
    if not hasattr(node, 'args'):
        return ''
    # Positional and keyword-only parameters in declaration order.
    arguments = node.args
    names = [item.arg for item in arguments.posonlyargs + arguments.args]
    if arguments.vararg:
        names.append('*' + arguments.vararg.arg)
    # Keyword-only arguments follow.
    names.extend(item.arg for item in arguments.kwonlyargs)
    if arguments.kwarg:
        names.append('**' + arguments.kwarg.arg)
    return '(%s)' % ', '.join(names)


def python_items(tree):
    """List classes, functions and methods of a module in source order.

    Args: tree - parsed module.
    Returns: list of dicts (name, kind, line, signature, docstring, words).
    """
    items = []
    # Walk module level and class level only; nested functions are details.
    scopes = [(tree, '')]
    while scopes:
        # Breadth-first: classes are visited after the module level.
        scope, prefix = scopes.pop(0)
        for node in scope.body:
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                continue
            # Class, method or function, decided by the scope.
            kind = 'class' if isinstance(node, ast.ClassDef) else (
                'method' if prefix else 'function')
            items.append({
                'name': prefix + node.name, 'kind': kind, 'line': node.lineno,
                'signature': python_signature(node),
                'body_lines': (node.end_lineno or node.lineno) - node.lineno,
                'docstring': ast.get_docstring(node) or '',
                'words': called_names(node), 'calls': [], 'called_by': []})
            # Classes are walked again for their methods.
            if isinstance(node, ast.ClassDef):
                scopes.append((node, prefix + node.name + '.'))
    return sorted(items, key=lambda item: item['line'])


def analyze_python(root, path):
    """Analyse one python script through the ast module.

    Args: root - repository root; path - relative path.
    Returns: dict describing the module docstring, items and metrics.
    """
    lines = read_lines(root, path)
    # An unparsable file is documented with its metrics only.
    try:
        tree = ast.parse('\n'.join(lines))
    except SyntaxError:
        tree = ast.parse('')
    # The module docstring is the file header.
    module_doc = ast.get_docstring(tree) or ''
    return {
        'path': path,
        'kind': 'python',
        'is_test': is_test_file(path),
        'header': module_doc.split('\n') if module_doc else [],
        'purpose': shorten(docstring_summary(module_doc)),
        'functions': python_items(tree),
        'metrics': count_python_lines(lines),
    }


def count_python_lines(lines):
    """Count blank, comment and code lines of a python file.

    Args: lines - file lines.
    Returns: dict (total, blank, comment, code).
    """
    # A trailing newline produces one empty element that is no line.
    if lines and lines[-1] == '':
        lines = lines[:-1]
    blank = sum(1 for line in lines if not line.strip())
    # Comment lines start with a hash.
    comment = sum(1 for line in lines if line.strip().startswith('#'))
    return {'total': len(lines), 'blank': blank, 'comment': comment,
            'code': len(lines) - blank - comment}


def item_is_documented(script, item):
    """Tell whether a function or class carries its documentation contract.

    Args: script - script dict; item - function dict.
    Returns: True for a valid R1 header (shell) or a docstring (python).
    """
    # Shell: the R1 verdict; python: any docstring.
    if script['kind'] == 'shell':
        return item['header_ok']
    return bool(item['docstring'])


def count_documented(script):
    """Count the documented functions of a script.

    Args: script - script dict.
    Returns: number of functions with a valid header / docstring.
    """
    # Each function is judged by item_is_documented().
    return sum(1 for item in script['functions'] if item_is_documented(script, item))


def header_coverage(script):
    """Compute the share of documented functions of a script.

    Args: script - script dict.
    Returns: integer percent (100 when the script has no functions).
    """
    # Scripts without functions have nothing to document.
    functions = script['functions']
    if not functions:
        return 100
    return count_documented(script) * 100 // len(functions)


def index_definitions(scripts):
    """Index every function name of all scripts.

    Args: scripts - list of script dicts.
    Returns: dict mapping the bare name to a list of (path, qualified name).
    """
    definitions = {}
    for script in scripts:
        for item in script['functions']:
            # Methods are found by their bare name, like attribute calls.
            bare_name = item['name'].split('.')[-1]
            definitions.setdefault(bare_name, []).append((script['path'], item['name']))
    return definitions


def resolve_calls(script, item, definitions):
    """Resolve the callees of one function.

    Args: script - script dict; item - function dict;
          definitions - map name -> list of (path, qualified name).
    Returns: list of dicts (path, name) in sorted word order.
    """
    own_name = item['name'].split('.')[-1]
    resolved = []
    for word in sorted(item['words']):
        # Only names defined somewhere in the repository are call edges.
        targets = definitions.get(word, [])
        # Scripts never source each other, so only same-file definitions are callees.
        same_file = [target for target in targets if target[0] == script['path']]
        chosen = same_file
        # A function that merely mentions its own name is no call edge.
        if word == own_name and not same_file:
            continue
        # A function never calls itself through this list.
        for target_path, target_name in chosen:
            if (target_path, target_name) != (script['path'], item['name']):
                resolved.append({'path': target_path, 'name': target_name})
    return resolved


def link_script_graph(scripts):
    """Fill calls / called_by of all functions across the scripts.

    Args: scripts - list of script dicts (modified in place).
    Returns: nothing.
    """
    definitions = index_definitions(scripts)
    # Lookup (path, name) -> function dict for the reverse edges.
    lookup = {(script['path'], item['name']): item
              for script in scripts for item in script['functions']}
    for script in scripts:
        for item in script['functions']:
            item['calls'] = resolve_calls(script, item, definitions)
            caller = {'path': script['path'], 'name': item['name']}
            # Register the caller on every callee (no duplicates).
            for target in item['calls']:
                called_by = lookup[(target['path'], target['name'])]['called_by']
                if caller not in called_by:
                    called_by.append(caller)
    # The raw command words are only needed while resolving.
    for script in scripts:
        for item in script['functions']:
            item.pop('words', None)
