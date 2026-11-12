"""Static overview of the Lua engine and the C++ plugin for the generated documentation.

Documentation only: Lua files (`src/lua/**`) are read with the same header parser
that the gate uses; C++ files (`plugin/*.cpp|hpp`) are read for their `///` doc
comments.  Nothing is compiled or executed.
"""
import re

# Header parser of the gate, file access and shortening.
from techdoc_lua import lua_file_purpose, lua_functions
from techdoc_repo import read_text
from techdoc_scripts import shorten

# Lua sources of the engine, nothing from the test tree.
LUA_PATH_PATTERN = re.compile(r'^src/lua/.+\.lua$')
# C++ sources and headers of the plugin (the tests live in tests/plugin).
CPP_PATH_PATTERN = re.compile(r'^plugin/[^/]+\.(cpp|hpp)$')
# The first sentence ends at a period followed by a blank or the end of the text.
SENTENCE_END_PATTERN = re.compile(r'\.(?=\s|$)')
# A `///` doc line; group 1 is the text after the marker.
DOC_LINE_PATTERN = re.compile(r'^\s*///\s?(.*)$')
# A `//` comment line (file header); group 1 is the text after the marker.
CPP_COMMENT_PATTERN = re.compile(r'^\s*//\s?(.*)$')
# Doc tags that start the parameter / return part of a Doxygen comment.
DOC_TAG_PATTERN = re.compile(r'^@(param|return|returns|tparam)\b')
# `struct Name` / `class Name` / `enum class Name` declaration (a template line may precede).
CPP_TYPE_PATTERN = re.compile(r'^\s*(struct|class|enum(?:\s+class)?)\s+(\w+)')
# A function declaration or definition: the name stands right before the first `(`.
CPP_FUNCTION_PATTERN = re.compile(r'^[\w:<>,&*\s]+?\b(\w+)\s*\(')
# A constant: `constexpr ... name =` or `const ... name =`.
CPP_CONSTANT_PATTERN = re.compile(r'^\s*(?:inline\s+)?(?:constexpr|const)\b[^=(]*?\b(\w+)\s*=')


def first_sentence(lines):
    """Reduce comment lines to their first sentence.

    Args: lines - comment texts without markers.
    Returns: one-line sentence ('' for no text), shortened for tables.
    """
    # Join the lines the way a reader would; a tag line ends the summary.
    summary = []
    for line in lines:
        if DOC_TAG_PATTERN.match(line.strip()):
            break
        # Plain lines belong to the summary.
        summary.append(line.strip())
    text = ' '.join(part for part in summary if part)
    # Cut after the first period that ends a sentence.
    match = SENTENCE_END_PATTERN.search(text)
    return shorten(text[:match.end()] if match else text)


def describe_declaration(line):
    """Classify the declaration line that follows a doc comment.

    Args: line - the first code line below `///` lines.
    Returns: tuple (kind, name) with kind in type / constant / function, or None.
    """
    # Types and constants are recognised by keyword; everything else with `(` is a function.
    type_match = CPP_TYPE_PATTERN.match(line)
    if type_match:
        return 'type', type_match.group(2)
    # Constants are recognised by their keyword.
    constant_match = CPP_CONSTANT_PATTERN.match(line)
    if constant_match:
        return 'constant', constant_match.group(1)
    # Everything else with a parenthesis is a function.
    function_match = CPP_FUNCTION_PATTERN.match(line.strip())
    return ('function', function_match.group(1)) if function_match else None


def cpp_items(text):
    """Collect the documented declarations of a C++ file.

    Args: text - file content.
    Returns: list of dicts (kind, name, line, brief) in source order.
    """
    items = []
    pending = []
    for index, line in enumerate(text.split('\n')):
        doc = DOC_LINE_PATTERN.match(line)
        # Collect the doc block; the first non-doc line is its declaration.
        if doc:
            pending.append(doc.group(1))
            continue
        # The first code line after the doc block is its declaration.
        declaration = describe_declaration(line) if pending and line.strip() else None
        if declaration:
            items.append({'kind': declaration[0], 'name': declaration[1],
                          'line': index + 1, 'brief': first_sentence(pending)})
        # Any non-doc line ends the block (a blank line between doc and code is tolerated).
        if line.strip():
            pending = []
    return items


def cpp_file_purpose(text):
    """Read the purpose from the first comment line of a C++ file.

    Args: text - file content.
    Returns: text after `// name — ` of the first line, else the first comment line.
    """
    # Only a comment at the very top is the file header.
    first = text.split('\n', 1)[0]
    match = CPP_COMMENT_PATTERN.match(first)
    if not match:
        return ''
    # `name — text` yields the text, anything else is used whole.
    parts = re.split(r'\s(?:—|-)\s', match.group(1), maxsplit=1)
    return shorten((parts[1] if len(parts) == 2 else parts[0]).strip())


def analyze_lua(text):
    """Describe one Lua source file.

    Args: text - file content.
    Returns: dict (purpose, functions, coverage) with the parsed function contracts.
    """
    functions = lua_functions(text)
    documented = sum(1 for item in functions if item['documented'])
    return {'purpose': shorten(lua_file_purpose(text)), 'functions': functions,
            'coverage': documented * 100 // len(functions) if functions else 100}


def analyze_cpp(text):
    """Describe one C++ source file.

    Args: text - file content.
    Returns: dict (purpose, items) with the documented declarations.
    """
    return {'purpose': cpp_file_purpose(text), 'items': cpp_items(text)}


def source_language(path):
    """Classify a tracked path as documented Lua or C++ source.

    Args: path - repository-relative path.
    Returns: 'lua', 'cpp' or None when the path is not documented here.
    """
    if LUA_PATH_PATTERN.match(path):
        return 'lua'
    return 'cpp' if CPP_PATH_PATTERN.match(path) else None


def build_sources(root, paths):
    """Analyse all Lua and C++ sources of the repository.

    Args: root - repository root; paths - tracked relative paths.
    Returns: dict with the keys 'lua' and 'cpp', each a list of file dicts sorted by
             path (path, language, lines and the analyzer's fields).
    """
    sources = {'lua': [], 'cpp': []}
    for path in sorted(paths):
        # Files that are no documented source are skipped.
        language = source_language(path)
        if not language:
            continue
        # Read once; the analyzers work on the text.
        text = read_text(root, path)
        analyzer = analyze_lua if language == 'lua' else analyze_cpp
        sources[language].append(dict(analyzer(text), path=path, language=language,
                                      lines=len(text.splitlines())))
    return sources
