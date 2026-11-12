"""Unit tests of the techdoc tool (stdlib unittest, no network, no docker).

Run: `python3 -m unittest` inside tools/techdoc, or from the repository root
`python3 -m unittest discover -s tools/techdoc -p 'test_techdoc.py' -v`.
Covers every rule R1-R8 with positive and negative fixtures, the parsers (YAML subset,
GitHub workflows, settings schema, help text), the Lua / C++ source analysis, the site
generator (docs links, omitted pages) and a parity test against the frozen reference
implementation of R1-R7.
"""
# Standard library modules used by the fixtures and the harness.
import importlib.util
import json
import os
import random
# File, process and temporary-directory helpers.
import shutil
import subprocess
import sys
import tempfile
# The test framework and the HTML parser for link checks.
import unittest
from html.parser import HTMLParser
from unittest import mock

# The tool lives next to this file; make its modules importable.
TOOL_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOL_DIRECTORY)

import techdoc_docs  # noqa: E402
import techdoc_help  # noqa: E402
import techdoc_lua  # noqa: E402
import techdoc_model  # noqa: E402
import techdoc_pages  # noqa: E402
import techdoc_repo  # noqa: E402
import techdoc_rules  # noqa: E402
import techdoc_scripts  # noqa: E402
import techdoc_settings  # noqa: E402
import techdoc_sources  # noqa: E402
import techdoc_workflows  # noqa: E402
import techdoc_yaml  # noqa: E402

# Command line entry point of the tool and the vendored reference.
TECHDOC_SCRIPT = os.path.join(TOOL_DIRECTORY, 'techdoc.py')
REFERENCE_SCRIPT = os.path.join(TOOL_DIRECTORY, 'fixtures', 'reference_precheck.py')
# True when a git binary is available (needed for tracked-file tests).
HAS_GIT = shutil.which('git') is not None

# A shell function with a complete, valid contract header.
VALID_FUNCTION = """\
# greet — print a greeting for a name.
# Args:    $1 name (optional, default world)
# Returns: 0 always; stdout: the greeting
# Globals: none
greet() {
    # Default the name when it is missing.
    local who="${1:-world}"
    # Print the greeting.
    echo "hello ${who}"
}
"""

# A shell script whose functions break several rules at once.
MESSY_SCRIPT = """\
#!/bin/bash
# Messy fixture.
set -u
a=1
b=2
c=3
d=4
undocumented() {
    echo one
    echo two
    echo three
    echo four
}

# long free comment
# second line
# third line
case "$1" in
    up)
        echo 1
        echo 2
        echo 3
        echo 4
        echo 5
        echo 6
        echo 7
        echo 8
        echo 9
        echo 10
        echo 11
        ;;
    down) echo down ;;
esac
cat <<'EOF'
inside heredoc a=1
EOF
"""


def numbered_lines(count, template='echo %d'):
    """Build indented shell lines for fixtures.

    Args: count - number of lines; template - printf template with one %d.
    Returns: list of lines indented by four blanks.
    """
    # Each line gets its own number so statements stay distinct.
    return ['    ' + template % number for number in range(count)]


def shell_findings(text, path='tools/sample.sh'):
    """Run the shell rules over a fixture text.

    Args: text - fixture script; path - virtual relative path.
    Returns: list of (line, rule) tuples.
    """
    # The text is split exactly like a file read from disk.
    violations = techdoc_rules.check_shell_lines_of(path, text.split('\n'))
    return [(violation.line, techdoc_rules.violation_rule(violation))
            for violation in violations]


def rules_of(findings):
    """Reduce findings to the sorted set of rule ids.

    Args: findings - list of (line, rule).
    Returns: sorted list of unique rule ids.
    """
    # Duplicates are irrelevant for presence checks.
    return sorted({rule for _line, rule in findings})


class RuleR1Tests(unittest.TestCase):
    """R1: the function contract header."""

    def test_complete_header_passes(self):
        """A function with purpose, Args, Returns and Globals has no R1 finding."""
        self.assertNotIn('R1', rules_of(shell_findings(VALID_FUNCTION)))

    def test_missing_header_fails(self):
        """A function without any header violates R1 four times."""
        findings = shell_findings('f() {\n    echo hi\n}\n')
        self.assertEqual([rule for _line, rule in findings].count('R1'), 4)

    def test_missing_field_is_named(self):
        """Dropping the Globals line yields exactly that message."""
        text = VALID_FUNCTION.replace('# Globals: none\n', '')
        violations = techdoc_rules.check_shell_lines_of('tools/x.sh', text.split('\n'))
        self.assertEqual([v.text for v in violations], ['R1 header lacks "# Globals:"'])

    def test_hyphen_separator_and_continuation_pass(self):
        """A hyphen separator and an indented continuation line are accepted."""
        text = VALID_FUNCTION.replace('— print', '- print').replace(
            '# Returns: 0 always;', '# Returns: 0 always;\n#          more text;')
        self.assertNotIn('R1', rules_of(shell_findings(text)))

    def test_test_suites_only_get_r1(self):
        """Test suites still need headers but are exempt from R2-R5 and R7."""
        text = 'x() {\n' + 'echo ' + 'y' * 120 + '\n}\n'
        findings = shell_findings(text, 'tools/test-sample.sh')
        self.assertEqual(rules_of(findings), ['R1'])


class RuleR2Tests(unittest.TestCase):
    """R2: line length <= 100."""

    def test_exactly_100_chars_pass(self):
        """A line of exactly 100 characters is fine."""
        text = '#!/bin/bash\n# h\n# ' + 'x' * 98 + '\n'
        self.assertNotIn('R2', rules_of(shell_findings(text)))

    def test_101_chars_fail(self):
        """A line of 101 characters violates R2 and names the length."""
        text = '#!/bin/bash\n# h\n# ' + 'x' * 99 + '\n'
        violations = techdoc_rules.check_shell_lines_of('tools/x.sh', text.split('\n'))
        self.assertIn('R2 line has 101 chars', [v.text for v in violations])

    def test_python_long_line_fails_and_test_is_exempt(self):
        """Production python is limited, test_*.py is not."""
        # Arrange: a module with one 110-character line.
        source = '"""Doc."""\nX = "' + 'y' * 110 + '"\n'
        production = techdoc_rules.check_python_source('tools/tool.py', source)
        exempt = techdoc_rules.check_python_source('tools/test_tool.py', source)
        self.assertEqual([v.text for v in production], ['R2 line has 116 chars'])
        # Only the production file is limited.
        self.assertEqual(exempt, [])


class RuleR3Tests(unittest.TestCase):
    """R3: function body <= 100 lines, heredocs not counted."""

    def build(self, body_lines):
        """Build a documented function with a given number of body lines.

        Args: body_lines - number of statement lines.
        Returns: script text.
        """
        # Comments keep R4 quiet; the body size is what matters.
        header = VALID_FUNCTION.split('greet() {')[0].replace('greet', 'big')
        body = ['    echo %d # note' % number for number in range(body_lines)]
        return header + 'big() {\n' + '\n'.join(body) + '\n}\n'

    def test_100_lines_pass(self):
        """A body of exactly 100 lines is accepted."""
        self.assertNotIn('R3', rules_of(shell_findings(self.build(100))))

    def test_101_lines_fail(self):
        """A body of 101 lines violates R3."""
        self.assertIn('R3', rules_of(shell_findings(self.build(101))))

    def test_heredoc_lines_are_not_counted(self):
        """Heredoc body lines do not count towards the limit."""
        text = self.build(60).replace(
            '\n}\n', "\n    cat <<'EOF'\n" + 'text\n' * 80 + 'EOF\n}\n')
        self.assertNotIn('R3', rules_of(shell_findings(text)))


class RuleR4Tests(unittest.TestCase):
    """R4: at most 3 consecutive statements without a comment."""

    def test_three_statements_pass(self):
        """Three statements in a row are allowed."""
        self.assertNotIn('R4', rules_of(shell_findings('#!/bin/bash\na=1\nb=2\nc=3\n')))

    def test_fourth_statement_fails_at_its_line(self):
        """The fourth statement is reported with its line number."""
        findings = shell_findings('#!/bin/bash\na=1\nb=2\nc=3\nd=4\n')
        self.assertEqual(findings, [(5, 'R4')])

    def test_comment_and_inline_comment_reset(self):
        """A full-line comment or an inline comment resets the run."""
        text = '#!/bin/bash\na=1\nb=2\n# why\nc=3\nd=4 # inline\ne=5\nf=6\n'
        self.assertNotIn('R4', rules_of(shell_findings(text)))

    def test_continuation_and_structure_are_one_statement(self):
        """Backslash continuations count once; fi/done lines are free."""
        text = '#!/bin/bash\na=1\nb=2 \\\n   --more\nif true; then\nfi\n'
        self.assertNotIn('R4', rules_of(shell_findings(text)))
        # One more real statement tips it over the limit.
        self.assertIn('R4', rules_of(shell_findings(text + 'c=3\n')))

    def test_heredoc_body_is_ignored(self):
        """Statements inside a heredoc body are data, not code."""
        text = "#!/bin/bash\n# start\ncat <<'EOF'\na=1\nb=2\nc=3\nd=4\ne=5\nEOF\n"
        self.assertNotIn('R4', rules_of(shell_findings(text)))


class RuleR5Tests(unittest.TestCase):
    """R5: thin dispatcher (case arms <= 10 statement lines)."""

    def case_text(self, arm_lines, indent=''):
        """Build a case statement with one arm of a given size.

        Args: arm_lines - statement lines in the arm; indent - case indentation.
        Returns: script text.
        """
        # Inline comments keep R4 out of the picture.
        arm = [indent + '        echo %d # n' % number for number in range(arm_lines)]
        return '\n'.join(['#!/bin/bash', indent + 'case "$1" in', indent + '    up)'] + arm
                         + [indent + '        ;;', indent + 'esac', ''])

    def test_ten_lines_pass(self):
        """An arm with ten statements is accepted."""
        self.assertNotIn('R5', rules_of(shell_findings(self.case_text(10))))

    def test_eleven_lines_fail(self):
        """An arm with eleven statements violates R5."""
        self.assertIn('R5', rules_of(shell_findings(self.case_text(11))))

    def test_indented_case_is_not_a_dispatcher(self):
        """Only column-0 case statements are judged."""
        self.assertNotIn('R5', rules_of(shell_findings(self.case_text(11, '    '))))


class RuleR6Tests(unittest.TestCase):
    """R6: python docstrings for module, functions and classes."""

    def test_documented_module_passes(self):
        """Module, class, method and function with docstrings are clean."""
        source = ('"""Module."""\n\n\nclass A:\n    """Class."""\n\n'
                  '    def run(self):\n        """Method."""\n\n\n'
                  'def helper():\n    """Function."""\n')
        self.assertEqual(techdoc_rules.check_python_source('tools/a.py', source), [])

    def test_missing_docstrings_are_reported(self):
        """Missing module, class, method and function docstrings are all found."""
        source = 'class A:\n    def run(self):\n        pass\n\n\ndef helper():\n    pass\n'
        texts = [v.text for v in techdoc_rules.check_python_source('tools/a.py', source)]
        self.assertEqual(texts, ['R6 module docstring missing', 'R6 docstring missing for A',
                                 'R6 docstring missing for helper',
                                 'R6 docstring missing for run'])

    def test_test_files_still_need_docstrings(self):
        """R6 also applies to test_*.py files."""
        findings = techdoc_rules.check_python_source('tools/test_a.py', 'def t():\n    pass\n')
        self.assertEqual(len(findings), 2)

    def test_syntax_error_is_reported_not_raised(self):
        """Unparsable python is reported as R6 instead of crashing the gate."""
        findings = techdoc_rules.check_python_source('tools/a.py', 'def (:\n')
        self.assertEqual(len(findings), 1)
        self.assertTrue(findings[0].text.startswith('R6 python syntax error'))


class RuleR7Tests(unittest.TestCase):
    """R7: comment blocks <= 2 lines and pure contract headers."""

    def test_two_line_comment_passes(self):
        """A free comment block of two lines is fine."""
        text = '#!/bin/bash\n# head\nset -u\n\n# one\n# two\nx=1\n'
        self.assertNotIn('R7', rules_of(shell_findings(text)))

    def test_three_line_comment_fails(self):
        """A free comment block of three lines violates R7 at its start."""
        text = '#!/bin/bash\n# head\nset -u\n\n# one\n# two\n# three\nx=1\n'
        self.assertEqual(shell_findings(text), [(5, 'R7')])

    def test_file_header_may_be_long(self):
        """The file header block at the top is exempt."""
        text = '#!/bin/bash\n# one\n# two\n# three\n# four\nset -u\n'
        self.assertNotIn('R7', rules_of(shell_findings(text)))

    def test_directives_are_not_prose(self):
        """shellcheck directives do not count towards the block size."""
        text = ('#!/bin/bash\n# head\nset -u\n\n# shellcheck disable=SC2034\n'
                '# one\n# two\nx=1\n')
        self.assertNotIn('R7', rules_of(shell_findings(text)))

    def test_prose_inside_header_fails(self):
        """Extra prose between purpose and fields breaks the header shape."""
        text = VALID_FUNCTION.replace('# Args:', '# Some prose here.\n# Args:')
        self.assertIn('R7', rules_of(shell_findings(text)))

    def test_header_field_longer_than_two_lines_fails(self):
        """A field with three lines violates R7."""
        text = VALID_FUNCTION.replace(
            '# Globals: none', '# Globals: none\n#          one more\n#          and more')
        self.assertIn('R7', rules_of(shell_findings(text)))


class YamlParserTests(unittest.TestCase):
    """The YAML-subset parser."""

    def test_mapping_sequence_and_scalars(self):
        """Nested mappings, lists, quotes and flow sequences are parsed."""
        parsed = techdoc_yaml.parse_yaml(
            'a: 1\nb:\n  - x\n  - "y z"\nc: [p, q]\nd:\n  e: f  # trailing comment\n')
        self.assertEqual(parsed, {'a': '1', 'b': ['x', 'y z'], 'c': ['p', 'q'],
                                  'd': {'e': 'f'}})

    def test_list_of_mappings(self):
        """`- key: value` items become dicts with aligned follow-up keys."""
        parsed = techdoc_yaml.parse_yaml('rules:\n  - if: $X\n    when: never\n  - when: always\n')
        self.assertEqual(parsed, {'rules': [{'if': '$X', 'when': 'never'},
                                            {'when': 'always'}]})

    def test_block_scalar_and_anchor(self):
        """Block scalars (also behind anchors) are kept as one string."""
        parsed = techdoc_yaml.parse_yaml('.t: &t |\n  line one\n  line two\nnext: 1\n')
        self.assertEqual(parsed, {'.t': 'line one\nline two', 'next': '1'})

    def test_same_indent_sequence_and_empty_flow(self):
        """A sequence at the key's indentation and `[]` are understood."""
        parsed = techdoc_yaml.parse_yaml('a:\n- 1\n- 2\nb: []\n')
        self.assertEqual(parsed, {'a': ['1', '2'], 'b': []})

    def test_hash_inside_quotes_is_no_comment(self):
        """A # inside quotes stays part of the value."""
        self.assertEqual(techdoc_yaml.parse_yaml('a: "x # y"\n'), {'a': 'x # y'})

    def test_empty_document(self):
        """An empty or comment-only document parses to None."""
        self.assertIsNone(techdoc_yaml.parse_yaml('# nothing\n'))


class RuleR8Tests(unittest.TestCase):
    """R8: Lua function headers (purpose, Args, Returns) and R2 for production Lua."""

    VALID_LUA = (
        '-- trim — strip whitespace.\n-- Args:    text string\n-- Returns: the trimmed string\n'
        'local function trim(text)\n  -- Drop both ends.\n  return text\nend\n')

    def findings(self, text, path='src/lua/mod.lua'):
        """Run the Lua rules over a fixture through the public file check.

        Args: text - Lua source; path - virtual relative path.
        Returns: list of (line, message) tuples.
        """
        # The path decides whether the file counts as test material.
        with tempfile.TemporaryDirectory() as directory:
            # The file lands below a temporary root.
            target = os.path.join(directory, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, 'w', encoding='utf-8') as handle:
                handle.write(text)
            # Findings are compared as (line, message) pairs.
            return [(v.line, v.text) for v in techdoc_rules.check_file(directory, path)]

    def test_complete_header_passes(self):
        """A function with purpose, Args and Returns is clean."""
        self.assertEqual(self.findings(self.VALID_LUA), [])

    def test_missing_header_reports_three_findings_at_the_function(self):
        """No header gives the purpose, Args and Returns findings on the function line."""
        findings = self.findings('local function f()\nend\n')
        self.assertEqual([line for line, _text in findings], [1, 1, 1])
        self.assertIn('R8 header lacks "-- f — <purpose>"', [text for _l, text in findings])

    def test_qualified_names_and_methods_are_accepted(self):
        """`function M.name` is documented by `-- name — ...` or `-- M.name — ...`."""
        for purpose in ('-- check — x.', '-- M.check — x.'):
            text = purpose + '\n-- Args:    a\n-- Returns: b\nfunction M.check(a)\nend\n'
            self.assertEqual(self.findings(text), [], purpose)

    def test_missing_returns_is_named(self):
        """Dropping the Returns line yields exactly that message."""
        text = self.VALID_LUA.replace('-- Returns: the trimmed string\n', '')
        self.assertEqual([message for _line, message in self.findings(text)],
                         ['R8 header lacks "-- Returns:"'])

    def test_anonymous_functions_need_no_header(self):
        """Callbacks (`function(`) are not named functions."""
        self.assertEqual(self.findings('run(function()\nend)\n'), [])

    def test_long_lines_fail_in_production_but_not_in_tests(self):
        """R2 applies to src Lua; the test tree is exempt."""
        text = '-- ' + 'x' * 120 + '\n'
        self.assertEqual([m for _l, m in self.findings(text)], ['R2 line has 123 chars'])
        self.assertEqual(self.findings(text, 'tests/lua/stub.lua'), [])

    def test_contract_parser_reads_fields_and_continuations(self):
        """Purpose, Args, Returns and continuation lines are split correctly."""
        # Arrange: a header with a continuation line and a Notes field.
        block = ['-- trim — strip it.', '-- Args:    text string;', '--          more',
                 '-- Returns: result', '-- Notes:   careful']
        contract = techdoc_lua.parse_lua_contract('trim', block)
        self.assertEqual((contract['purpose'], contract['Args']),
                         ('strip it.', 'text string; more'))
        self.assertEqual((contract['Returns'], contract['Notes']), ('result', 'careful'))


# A GitHub workflow with filters, a container job, needs, permissions and block scalars.
WORKFLOW_SAMPLE = """\
name: CI
on:
  push:
    branches: [main, beta]
    tags:
      - "v*"
  pull_request:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  static:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - name: Lint
        run: |
          make check
          make lint
  package:
    needs: [static]
    runs-on: ubuntu-latest
    container:
      image: archlinux:latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/upload-artifact@v4
"""

# A minimal settings schema with a comment, a blank line and a help text containing a pipe.
SCHEMA_SAMPLE = """\
# comment

ZOOM_STEP|float|0.10|0.01..2.00|zoom|Zoom step|How much one notch zooms.
ZOOM_STEP_MODE|enum|multiply|multiply,add|zoom|Step mode|multiply | add.
BIND_KEY_IN|key|I||shortcuts|Zoom in key|Key that zooms in.
SCROLL_EVENT_DELAY_MS|int|0|0..300|advanced|Delay|Delay in ms.
NEW_THING|bool|on||future|New|Added later.
"""


class WorkflowParserTests(unittest.TestCase):
    """The GitHub Actions workflow summary."""

    def setUp(self):
        """Parse the sample workflow.

        Args: none.
        Returns: nothing.
        """
        # One parse serves every assertion.
        self.workflow = techdoc_workflows.parse_workflow('.github/workflows/ci.yml',
                                                         WORKFLOW_SAMPLE)

    def test_triggers_show_filters(self):
        """Branch and tag filters are part of the trigger text."""
        self.assertEqual(self.workflow['triggers'], [
            'push (branches: main, beta; tags: v*)', 'pull_request', 'workflow_dispatch'])

    def test_short_trigger_forms(self):
        """`on: push` and `on: [push, pull_request]` give plain event names."""
        self.assertEqual(techdoc_workflows.parse_triggers('push'), ['push'])
        self.assertEqual(techdoc_workflows.parse_triggers(['push', 'pull_request']),
                         ['push', 'pull_request'])

    def test_workflow_level_facts(self):
        """Name, permissions and the concurrency group are summarised."""
        self.assertEqual((self.workflow['name'], self.workflow['permissions']),
                         ('CI', 'contents: read'))
        self.assertEqual(self.workflow['concurrency'], 'ci-${{ github.ref }}')

    def test_jobs_carry_runner_container_needs_and_actions(self):
        """Every job lists where it runs, what it needs and which actions it uses."""
        # Static job: runner, timeout, step count and action pins.
        static, package = self.workflow['jobs']
        self.assertEqual((static['id'], static['runs_on'], static['timeout'], static['steps']),
                         ('static', 'ubuntu-latest', '10', 2))
        self.assertEqual(static['actions'], ['actions/checkout@v4'])
        self.assertEqual((package['container'], package['needs']), ('archlinux:latest',
                                                                    ['static']))
        # Job-level permissions and the used actions.
        self.assertEqual(package['permissions'], 'contents: write')
        self.assertEqual(package['actions'], ['actions/checkout@v4', 'actions/upload-artifact@v4'])

    def test_path_pattern_selects_workflow_files_only(self):
        """Only .github/workflows/*.yml|yaml count as workflows."""
        # Only files directly in .github/workflows count.
        pattern = techdoc_workflows.WORKFLOW_PATH_PATTERN
        self.assertTrue(pattern.match('.github/workflows/ci.yml'))
        self.assertTrue(pattern.match('.github/workflows/docs.yaml'))
        self.assertIsNone(pattern.match('.github/dependabot.yml'))
        # Nested paths are no workflows.
        self.assertIsNone(pattern.match('docs/.github/workflows/x.yml'))


class SettingsTests(unittest.TestCase):
    """The schema reader and the generated settings tables."""

    def setUp(self):
        """Parse the sample schema.

        Args: none.
        Returns: nothing.
        """
        # One parse serves every assertion.
        self.settings = techdoc_settings.parse_schema(SCHEMA_SAMPLE)

    def test_comments_and_blank_lines_are_skipped(self):
        """Only the five setting lines remain, in file order."""
        self.assertEqual([item['key'] for item in self.settings],
                         ['ZOOM_STEP', 'ZOOM_STEP_MODE', 'BIND_KEY_IN', 'SCROLL_EVENT_DELAY_MS',
                          'NEW_THING'])

    def test_help_text_keeps_pipe_characters(self):
        """The help text is the seventh field and may contain separators."""
        self.assertEqual(self.settings[1]['help'], 'multiply | add.')

    def test_cli_names_follow_contract_c1(self):
        """Lower case, hyphens, ZOOM_ prefix dropped."""
        self.assertEqual([item['cli'] for item in self.settings],
                         ['step', 'step-mode', 'bind-key-in', 'scroll-event-delay-ms',
                          'new-thing'])

    def test_allowed_values_per_type(self):
        """Ranges, enum options and fixed texts per type."""
        # Ranges, enums, booleans and empty defaults each have their own text.
        self.assertEqual(techdoc_settings.allowed_values(self.settings[0]), '0.01 to 2.00')
        self.assertEqual(techdoc_settings.allowed_values(self.settings[1]), 'multiply, add')
        self.assertEqual(techdoc_settings.allowed_values(self.settings[4]), 'on, off')
        self.assertEqual(techdoc_settings.default_text(self.settings[2]), 'I')

    def test_groups_follow_window_order_and_unknown_groups_come_last(self):
        """zoom, shortcuts, advanced in window order, then the unknown group."""
        groups = [group for group, _title, _members in
                  techdoc_settings.grouped_settings(self.settings)]
        self.assertEqual(groups, ['zoom', 'shortcuts', 'advanced', 'future'])

    def test_markdown_lists_every_key_once_and_escapes_pipes(self):
        """The table has one row per key and the pipe of a help text is escaped."""
        markdown = techdoc_settings.render_settings_markdown(self.settings)
        self.assertEqual(sorted(techdoc_settings.documented_keys(markdown)),
                         sorted(item['key'] for item in self.settings))
        self.assertIn('multiply \\| add.', markdown)

    def test_splice_replaces_only_the_generated_block(self):
        """Text outside the markers survives; a missing marker gives None."""
        # Arrange: a document with stale text between the markers.
        document = 'intro\n%s\nold\n%s\noutro\n' % (techdoc_settings.BEGIN_MARKER,
                                                     techdoc_settings.END_MARKER)
        updated = techdoc_settings.splice_generated_block(document, 'NEW\n')
        self.assertTrue(updated.startswith('intro\n'))
        self.assertTrue(updated.endswith('%s\noutro\n' % techdoc_settings.END_MARKER))
        # The new block replaced the stale one.
        self.assertIn('\nNEW\n', updated)
        self.assertNotIn('old', updated)
        self.assertIsNone(techdoc_settings.splice_generated_block('no markers', 'x'))


class HelpParserTests(unittest.TestCase):
    """Static help-text extraction (echo blocks and heredocs)."""

    ECHO_SCRIPT = ('if [ -z "$x" ]; then\n'
                   '    echo "Usage: $0 {up|down}"\n    echo ""\n    echo "Options:"\n'
                   '    echo "  -f file    Use a file"\n    echo ""\n    echo "Commands:"\n'
                   '    # comments between echo lines are skipped\n'
                   '    echo "  up      Start \\"all\\""\n    echo "  down    Stop"\n'
                   '    echo ""\n    echo "Environment: edit .env"\n    exit 0\nfi\n')
    HEREDOC_SCRIPT = ("print_usage() {\n    cat <<'EOF'\nTool intro.\n\n"
                      'Usage: ./t.sh {a|b} [options]\n\nOptions:\n  -x   Flag x\n\n'
                      'Commands:\n  a      Do a\n  b      Do b\n\nToken: set T.\nEOF\n}\n')
    # Help with custom section titles and descriptions in an aligned column.
    ALIGNED_SCRIPT = ("help() {\n  cat <<'EOF'\nUsage: tool <command>\n\nZoom:\n"
                      "  in [n]            zoom in\n"
                      "  set <key> <value> save one setting\n"
                      "  config            show it\n"
                      "                    (--porcelain: machine readable)\n\n"
                      "Maintenance:\n  doctor            check\n  version, help\n\n"
                      "Exit status: 0 ok.\nEOF\n}\n")

    def test_echo_block(self):
        """An echo run yields usage, options, commands and notes."""
        # The echo run is found and structured.
        result = techdoc_help.parse_help_text(self.ECHO_SCRIPT, './deploy.sh')
        self.assertTrue(result['found'])
        self.assertEqual(result['usage'], ['./deploy.sh {up|down}'])
        self.assertEqual(result['options'], [{'term': '-f file', 'text': 'Use a file'}])
        # Escapes and trailing notes are resolved.
        self.assertEqual(result['commands'][0], {'term': 'up', 'text': 'Start "all"'})
        self.assertEqual(result['notes'], ['Environment: edit .env'])

    def test_heredoc_block(self):
        """A heredoc yields the same structure including the intro."""
        # The heredoc form yields the same structure.
        result = techdoc_help.parse_help_text(self.HEREDOC_SCRIPT, './t.sh')
        self.assertEqual(result['intro'], ['Tool intro.'])
        self.assertEqual([entry['term'] for entry in result['commands']], ['a', 'b'])
        self.assertEqual(result['notes'], ['Token: set T.'])

    def test_wrapped_echo_and_constant_variables(self):
        """Continued multi-argument echoes and constant variables are resolved."""
        # Arrange: constants, a wrapped echo and a variable in the usage line.
        script = ('LIST="up|down"\nLIST+="|log"\nif true; then\n'
                  '    echo "Usage: $0 {${LIST}}"\n    echo "Commands:"\n'
                  '    echo "  up      Start the" \\\n        "stack"\n'
                  '    echo "  down    Stop"\nfi\n')
        result = techdoc_help.parse_help_text(script, './deploy.sh')
        self.assertEqual(result['usage'], ['./deploy.sh {up|down|log}'])
        self.assertEqual(result['commands'][0], {'term': 'up', 'text': 'Start the stack'})
        # Both commands survive the line wrapping.
        self.assertEqual(len(result['commands']), 2)

    def test_custom_sections_aligned_columns_and_continuations(self):
        """Sections other than Commands, one-blank terms and continuation lines work."""
        # Aligned columns split terms and descriptions correctly.
        result = techdoc_help.parse_help_text(self.ALIGNED_SCRIPT)
        zoom, maintenance = result['sections']
        self.assertEqual([entry['term'] for entry in zoom['entries']],
                         ['in [n]', 'set <key> <value>', 'config'])
        self.assertEqual(zoom['entries'][1]['text'], 'save one setting')
        # Continuation lines extend the description; bare terms stay empty.
        self.assertEqual(zoom['entries'][2]['text'], 'show it (--porcelain: machine readable)')
        self.assertEqual(maintenance['entries'][-1], {'term': 'version, help', 'text': ''})
        self.assertEqual(result['notes'], ['Exit status: 0 ok.'])

    def test_missing_help_is_reported(self):
        """A script without help text gives found == False, never an error."""
        self.assertFalse(techdoc_help.parse_help_text('echo hello\n')['found'])


class ScriptModelTests(unittest.TestCase):
    """Shell / python analysis and call linking."""

    def write(self, directory, name, text):
        """Write a fixture file.

        Args: directory - base directory; name - relative file; text - content.
        Returns: nothing.
        """
        # Parent directories are created on demand.
        target = os.path.join(directory, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'w', encoding='utf-8') as handle:
            handle.write(text)

    def test_contract_parsing(self):
        """Purpose and fields are split from the header, continuations joined."""
        # Arrange: a header with a continuation line.
        block = ['# greet — print a greeting.', '# Args:    $1 name', '#          second',
                 '# Returns: 0 always', '# Globals: none']
        contract = techdoc_scripts.parse_contract('greet', block)
        self.assertEqual(contract['purpose'], 'print a greeting.')
        self.assertEqual(contract['Args'], '$1 name second')
        # Fields without text beyond the label stay intact.
        self.assertEqual(contract['Globals'], 'none')

    def test_file_header_skips_code_and_decoration(self):
        """The first prose comment block is the header, rule lines are dropped."""
        lines = ['#!/bin/bash', 'set -u', '', '# ═════════', '# Tool — does things.',
                 '# ═════════', 'x=1']
        header = techdoc_scripts.file_header_lines(lines)
        self.assertEqual(techdoc_scripts.header_purpose(header), 'Tool — does things.')

    def test_calls_and_called_by(self):
        """A call links caller and callee in one file; other files never link."""
        # Arrange: two files where only the first one defines and calls greet.
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, 'a.sh', VALID_FUNCTION + '\nouter() {\n    greet "x"\n}\n')
            self.write(directory, 'b.sh', 'run() {\n    echo "greet"  # mentioned only\n'
                       '    greet "y"  # not sourced: no edge\n}\n')
            scripts = [techdoc_scripts.analyze_shell(directory, 'a.sh'),
                       techdoc_scripts.analyze_shell(directory, 'b.sh')]
            # Link the graph over both files.
            techdoc_scripts.link_script_graph(scripts)
        outer = scripts[0]['functions'][1]
        greet = scripts[0]['functions'][0]
        self.assertEqual(outer['calls'], [{'path': 'a.sh', 'name': 'greet'}])
        # The reverse edge exists as well, and the other file stays unlinked.
        self.assertEqual(greet['called_by'], [{'path': 'a.sh', 'name': 'outer'}])
        self.assertEqual(scripts[1]['functions'][0]['calls'], [])

    def test_python_analysis(self):
        """Docstrings, signatures and same-file calls of python are extracted."""
        # Arrange: a module with two functions where main calls helper.
        source = ('"""Module summary.\n\nMore."""\n\n\ndef helper(a, b=1):\n    """Help."""\n'
                  '    return a\n\n\ndef main():\n    """Run."""\n    return helper(1)\n')
        with tempfile.TemporaryDirectory() as directory:
            self.write(directory, 'p.py', source)
            script = techdoc_scripts.analyze_python(directory, 'p.py')
            # Link calls and called-by inside the module.
            techdoc_scripts.link_script_graph([script])
        self.assertEqual(script['purpose'], 'Module summary.')
        self.assertEqual(script['functions'][0]['signature'], '(a, b)')
        self.assertEqual(script['functions'][1]['calls'], [{'path': 'p.py', 'name': 'helper'}])
        # Both functions are documented.
        self.assertEqual(techdoc_scripts.header_coverage(script), 100)


# A Lua module with a file header, a documented public function, a local helper and a gap.
LUA_SAMPLE = """\
-- util.lua — small pure helpers.
-- Second header line.

local M = {}

-- trim — strip whitespace.
-- Args:    text string
-- Returns: the trimmed string
function M.trim(text)
  return text
end

-- helper — internal helper.
-- Args:    none
-- Returns: nothing
local function helper()
end

local function undocumented()
end

return M
"""

# A C++ header with a file comment, a constant, a struct, a documented and a plain function.
CPP_SAMPLE = """\
// camera_math.hpp — pure camera maths (no Hyprland types).
//
// More text.
#pragma once

namespace hyprzoom {

/// Margin that reproduces the native box.
constexpr double kNativeEdgeMargin = 0.05;

/// A point in world coordinates.
struct Vec2 {
    double x = 0.0; ///< Horizontal component.
};

/// Clamps a margin into the accepted range. Second sentence.
/// @param margin Raw value.
/// @return The clamped value.
inline double clampEdgeMargin(double margin) {
    return margin;
}

inline double undocumented(double value) {
    return value;
}

}  // namespace hyprzoom
"""


class SourceAnalysisTests(unittest.TestCase):
    """Lua and C++ extraction: purposes, functions and documented declarations."""

    def test_lua_file_purpose_functions_and_scope(self):
        """The first comment line is the purpose; local functions are marked private."""
        # Analyse the sample module.
        result = techdoc_sources.analyze_lua(LUA_SAMPLE)
        self.assertEqual(result['purpose'], 'small pure helpers.')
        names = [(item['name'], item['public'], item['documented'])
                 for item in result['functions']]
        self.assertEqual(names, [('trim', True, True), ('helper', False, True),
                                 ('undocumented', False, False)])
        # The contract fields are parsed and coverage counts documented functions.
        self.assertEqual(result['functions'][0]['contract']['Returns'], 'the trimmed string')
        self.assertEqual(result['coverage'], 66)

    def test_lua_file_without_header_has_no_purpose(self):
        """A file that starts with code has no purpose instead of a wrong one."""
        self.assertEqual(techdoc_sources.analyze_lua('local M = {}\nreturn M\n')['purpose'], '')

    def test_cpp_items_need_a_doc_comment(self):
        """Documented constants, types and functions appear; undocumented code does not."""
        items = techdoc_sources.analyze_cpp(CPP_SAMPLE)['items']
        self.assertEqual([(item['kind'], item['name']) for item in items], [
            ('constant', 'kNativeEdgeMargin'), ('type', 'Vec2'),
            ('function', 'clampEdgeMargin')])
        self.assertEqual(items[2]['brief'], 'Clamps a margin into the accepted range.')

    def test_cpp_file_purpose_is_the_first_comment_line(self):
        """`// name — text` gives the text; a file without header gives ''."""
        self.assertEqual(techdoc_sources.analyze_cpp(CPP_SAMPLE)['purpose'],
                         'pure camera maths (no Hyprland types).')
        self.assertEqual(techdoc_sources.analyze_cpp('#pragma once\n')['purpose'], '')

    def test_path_selection_covers_engine_and_plugin_but_not_tests(self):
        """Only src/lua/** and plugin/*.cpp|hpp are documented as sources."""
        # Engine files are Lua sources, plugin files are C++ sources.
        select = techdoc_sources.source_language
        self.assertEqual(select('src/lua/hyprland-zoom.lua'), 'lua')
        self.assertEqual(select('src/lua/hyprland-zoom/util.lua'), 'lua')
        self.assertEqual(select('plugin/main.cpp'), 'cpp')
        # Headers count too; the test trees and other files do not.
        self.assertEqual(select('plugin/camera_math.hpp'), 'cpp')
        self.assertIsNone(select('tests/lua/test_util.lua'))
        self.assertIsNone(select('tests/plugin/camera_math_test.cpp'))
        self.assertIsNone(select('plugin/Makefile'))


class LinkChecker(HTMLParser):
    """Collects hrefs and ids of one HTML page."""

    def __init__(self):
        """Create an empty collector.

        Args: none.
        Returns: nothing.
        """
        # HTMLParser needs its own initialisation first.
        super().__init__()
        self.hrefs = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        """Record href and id attributes.

        Args: tag - tag name; attrs - list of (name, value).
        Returns: nothing.
        """
        # Only anchors and ids matter for link checking.
        values = dict(attrs)
        # Links are checked against the collected ids later.
        if 'href' in values:
            self.hrefs.append(values['href'])
        if 'id' in values:
            self.ids.add(values['id'])


def write_files(directory, files):
    """Write fixture files below a directory.

    Args: directory - base directory; files - mapping of relative path to text.
    Returns: nothing.
    """
    for name, text in files.items():
        # Parent directories are created on demand.
        target = os.path.join(directory, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'w', encoding='utf-8') as handle:
            handle.write(text)


def make_repository(files):
    """Create a temporary git repository with staged files.

    Args: files - mapping of relative path to text.
    Returns: path of the repository (the caller removes it).
    """
    # Files are staged so that `git ls-files` lists them.
    directory = tempfile.mkdtemp(prefix='techdoc-test-')
    # Initialise a repository, write the files and stage them.
    subprocess.run(['git', 'init', '-q', directory], check=True)
    write_files(directory, files)
    subprocess.run(['git', '-C', directory, 'add', '-A'], check=True)
    return directory


@unittest.skipUnless(HAS_GIT, 'git is required')
class SiteTests(unittest.TestCase):
    """Model building and HTML site on a small temporary git repository."""

    FILES = {
        'config/settings.schema': SCHEMA_SAMPLE,
        '.github/workflows/ci.yml': WORKFLOW_SAMPLE,
        'src/tool.sh': ('#!/bin/bash\n# Tool.\n\n' + VALID_FUNCTION),
        'src/lib/help.sh': ("# help.sh — help.\n\nusage() {\n  cat <<'EOF'\nUsage: tool <cmd>\n\n"
                            "Zoom:\n  in [n]   zoom in\nEOF\n}\n"),
        'src/ui/app.py': '"""App."""\n\n\ndef run():\n    """Run."""\n    return 1\n',
        'src/lua/mod.lua': LUA_SAMPLE,
        'plugin/main.cpp': CPP_SAMPLE,
        'docs/usage.md': '# Usage\n',
        'docs/extra.md': '# Extra\n',
    }

    def setUp(self):
        """Create the temporary repository and register its cleanup.

        Args: none.
        Returns: nothing.
        """
        self.directory = make_repository(self.FILES)
        self.addCleanup(shutil.rmtree, self.directory, True)

    def build_site(self, name):
        """Build the site into a fresh directory outside the repository.

        Args: name - label for the directory name.
        Returns: path of the site directory.
        """
        # The output lives outside the repository, like in real use.
        site = tempfile.mkdtemp(prefix='techdoc-site-%s-' % name)
        self.addCleanup(shutil.rmtree, site, True)
        techdoc_pages.write_site(techdoc_model.build_model(self.directory), site)
        return site

    def read_page(self, site, name):
        """Read one page of a built site.

        Args: site - site directory; name - site-relative file name.
        Returns: the page text.
        """
        with open(os.path.join(site, name), encoding='utf-8') as handle:
            return handle.read()

    def test_all_pages_exist_and_links_resolve(self):
        """Every page exists, every internal link and anchor resolves."""
        # Build the site and parse every page for links and ids.
        site = self.build_site('links')
        pages = {}
        for base, _directories, files in os.walk(site):
            for file_name in files:
                # Only HTML pages are parsed.
                if file_name.endswith('.html'):
                    checker = LinkChecker()
                    path = os.path.join(base, file_name)
                    checker.feed(self.read_page(site, os.path.relpath(path, site)))
                    # Pages are keyed by their site-relative path.
                    pages[os.path.relpath(path, site)] = checker
        for name in ('index.html', 'settings.html', 'cli.html', 'ci.html', 'sources.html',
                     'quality.html'):
            self.assertIn(name, pages)
        self.assertIn('scripts/src__tool.sh.html', pages)
        # Shell and python scripts get their own page.
        self.assertIn('scripts/src__ui__app.py.html', pages)
        for name, checker in pages.items():
            for href in checker.hrefs:
                # Links to the handwritten docs leave the site (repository paths / URLs).
                if href.startswith(('docs/', 'http')):
                    # External and document links leave the site.
                    continue
                target, _hash, fragment = href.partition('#')
                resolved = os.path.normpath(os.path.join(os.path.dirname(name), target)
                                            ) if target else name
                self.assertIn(resolved, pages, '%s -> %s' % (name, href))
                # A fragment must exist as an id on the target page.
                if fragment:
                    self.assertIn(fragment, pages[resolved].ids, '%s -> %s' % (name, href))

    def test_settings_page_lists_every_key_with_an_anchor(self):
        """settings.html has one anchored row per schema key."""
        # Every key has an anchored row and a CLI name column.
        page = self.read_page(self.build_site('settings'), 'settings.html')
        for key in ('ZOOM_STEP', 'ZOOM_STEP_MODE', 'BIND_KEY_IN', 'NEW_THING'):
            self.assertIn('id="%s"' % key, page)
        self.assertIn('<code>step-mode</code>', page)

    def test_cli_page_reads_help_text(self):
        """cli.html shows the program and the entries parsed from the help text."""
        page = self.read_page(self.build_site('cli'), 'cli.html')
        self.assertIn('<code>in [n]</code>', page)
        self.assertIn('Usage: tool &lt;cmd&gt;', page)

    def test_ci_page_lists_workflows_and_jobs(self):
        """ci.html shows triggers, runner, container and needs of the sample workflow."""
        page = self.read_page(self.build_site('ci'), 'ci.html')
        for text in ('push (branches: main, beta; tags: v*)', 'archlinux:latest',
                     '<code>package</code>', 'actions/upload-artifact@v4'):
            self.assertIn(text, page)

    def test_sources_page_lists_lua_functions_and_cpp_items(self):
        """sources.html carries the Lua contracts and the documented C++ declarations."""
        # Lua contracts and C++ declarations are both rendered.
        page = self.read_page(self.build_site('sources'), 'sources.html')
        self.assertIn('the trimmed string', page)
        self.assertIn('<code>clampEdgeMargin</code>', page)
        self.assertIn('id="src-src-lua-mod-lua"', page)

    def test_model_json_is_deterministic(self):
        """Two builds of the same state are byte-identical, including JSON."""
        # Two builds of the same state must be identical.
        first = self.build_site('one')
        second = self.build_site('two')
        for name in ('techdoc.json', 'index.html', 'scripts/src__tool.sh.html'):
            self.assertEqual(self.read_page(first, name), self.read_page(second, name), name)
        # The model has exactly the documented top-level keys.
        model = json.loads(self.read_page(first, 'techdoc.json'))
        self.assertEqual(sorted(model), ['cli', 'components', 'docs', 'meta', 'quality',
                                         'scripts', 'settings', 'sources', 'workflows'])

    def test_header_uses_github_variables(self):
        """GITHUB_SHA / GITHUB_REF_NAME win over git."""
        # The Actions variables win over what git reports.
        environment = {'GITHUB_SHA': 'abc123def456', 'GITHUB_REF_NAME': 'feature-x'}
        with mock.patch.dict(os.environ, environment):
            site = self.build_site('ci-vars')
        self.assertIn('feature-x @ abc123def456', self.read_page(site, 'index.html'))

    def test_lua_violations_appear_on_the_quality_page(self):
        """A Lua function without header is listed with its rule."""
        # Arrange: a Lua function without any header.
        directory = make_repository({'src/lua/bad.lua': 'local function f()\nend\n'})
        self.addCleanup(shutil.rmtree, directory, True)
        model = techdoc_model.build_model(directory)
        self.assertEqual(model['quality']['total'], 3)
        # All three findings are R8 and the file is linked on the page.
        self.assertEqual({v['rule'] for v in model['quality']['violations']}, {'R8'})
        page = techdoc_pages.render_quality(model)
        self.assertIn('src-src-lua-bad-lua', page)

    def test_build_does_not_fail_on_violations(self):
        """Rule violations are reported but never fail the build command."""
        # Arrange: a script that violates R1 four times.
        directory = make_repository({'bad.sh': '#!/bin/bash\n\nf() {\n    echo\n}\n'})
        self.addCleanup(shutil.rmtree, directory, True)
        out = tempfile.mkdtemp(prefix='techdoc-out-')
        self.addCleanup(shutil.rmtree, out, True)
        # Run the real command line; violations must not change the exit code.
        result = subprocess.run([sys.executable, TECHDOC_SCRIPT, 'build', '--root', directory,
                                 '--out', os.path.join(out, 'public')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('4 violations', result.stdout)


class DocsLinkTests(unittest.TestCase):
    """Link targets of the handwritten documents."""

    ENVIRONMENT = {'GITHUB_SERVER_URL': 'https://github.com/', 'GITHUB_REPOSITORY': 'a/b',
                   'GITHUB_REF_NAME': 'beta'}

    def test_github_variables_give_a_blob_url(self):
        """With server, repository and ref the link points into the GitHub file view."""
        self.assertEqual(techdoc_docs.docs_href('docs/a.md', self.ENVIRONMENT),
                         'https://github.com/a/b/blob/beta/docs/a.md')

    def test_missing_variables_give_the_relative_path(self):
        """Without CI (or with only some variables) the repository path is used."""
        self.assertEqual(techdoc_docs.docs_href('docs/a.md', {}), 'docs/a.md')
        partial = {'GITHUB_SERVER_URL': 'https://github.com', 'GITHUB_REF_NAME': 'main'}
        self.assertEqual(techdoc_docs.docs_href('docs/a.md', partial), 'docs/a.md')

    def test_reading_order_comes_first_and_only_docs_markdown_counts(self):
        """usage leads, known documents follow their order, deeper folders are ignored."""
        # Documents of other folders and types are ignored.
        paths = ['docs/zzz.md', 'docs/plugin.md', 'docs/usage.md', 'docs/img/a.md',
                 'docs/x.txt', 'README.md']
        with tempfile.TemporaryDirectory(prefix='techdoc-docs-') as root:
            documents = techdoc_docs.build_docs(root, paths, {})
        self.assertEqual([d['path'] for d in documents],
                         ['docs/usage.md', 'docs/plugin.md', 'docs/zzz.md'])
        # A missing file has no heading: the path stands in as link text.
        self.assertEqual(documents[0]['title'], 'docs/usage.md')


@unittest.skipUnless(HAS_GIT, 'git is required')
class OptionalPageTests(unittest.TestCase):
    """Pages for missing inputs are omitted, present ones appear in the navigation."""

    def build(self, files, environment=None):
        """Build the model and the pages of a temporary repository.

        Args: files - mapping of relative path to text; environment - GITHUB_* variables
              to set (the real ones of the running pipeline are cleared first).
        Returns: tuple (model, pages dict file name -> page text).
        """
        directory = make_repository(files)
        self.addCleanup(shutil.rmtree, directory, True)
        # The tests must not depend on the variables of the pipeline running them.
        with mock.patch.dict(os.environ, environment or {}):
            # Clear every variable the test does not set itself.
            for variable in ('GITHUB_SERVER_URL', 'GITHUB_REPOSITORY', 'GITHUB_REF_NAME',
                             'GITHUB_SHA'):
                if variable not in (environment or {}):
                    os.environ.pop(variable, None)
            model = techdoc_model.build_model(directory)
        # Pages are rendered from the finished model.
        return model, techdoc_pages.site_pages(model)

    def test_repository_without_inputs_has_only_index_and_quality(self):
        """No schema / workflow / help text / Lua / C++: no such pages, no nav entries."""
        # A repository without inputs yields only the two mandatory pages.
        model, pages = self.build({'tool.py': '"""Tool."""\n'})
        self.assertEqual(sorted(name for name in pages if '/' not in name),
                         ['index.html', 'quality.html'])
        self.assertEqual(model['meta']['pages'], [])
        for page in pages.values():
            # No page may link to an omitted page.
            for omitted in ('settings.html', 'cli.html', 'ci.html', 'sources.html'):
                self.assertNotIn(omitted, page)

    def test_sources_page_appears_with_lua_or_cpp(self):
        """A Lua file alone creates sources.html and its navigation entry."""
        # Lua alone is enough for the sources page.
        model, pages = self.build({'src/lua/m.lua': LUA_SAMPLE})
        self.assertEqual(model['meta']['pages'], ['sources.html'])
        self.assertIn('href="sources.html"', pages['index.html'])
        self.assertNotIn('href="ci.html"', pages['index.html'])

    def test_index_lists_docs_only_when_they_exist(self):
        """The docs link list is absent without docs/ and present with it."""
        # Without docs/ the section is absent.
        _model, without = self.build({'tool.py': '"""Tool."""\n'})
        self.assertNotIn('Handwritten documentation', without['index.html'])
        _model, with_docs = self.build({'tool.py': '"""Tool."""\n', 'docs/a.md': '# Title A\n'})
        self.assertIn('Handwritten documentation', with_docs['index.html'])
        # With docs/ it lists the title and the link.
        self.assertIn('href="docs/a.md"', with_docs['index.html'])
        self.assertIn('Title A', with_docs['index.html'])

    def test_docs_links_use_the_github_blob_url(self):
        """With the Actions variables the index links into the GitHub file view."""
        environment = {'GITHUB_SERVER_URL': 'https://github.com',
                       'GITHUB_REPOSITORY': 'artibex/hyprland-zoom',
                       'GITHUB_REF_NAME': 'main'}
        _model, pages = self.build({'docs/a.md': '# Title A\n'}, environment)
        self.assertIn('href="https://github.com/artibex/hyprland-zoom/blob/main/docs/a.md"',
                      pages['index.html'])

    def test_cli_page_lists_only_sources_with_a_readable_help_text(self):
        """A script without help text is not listed as CLI tool."""
        model, _pages = self.build({'a/tool.sh': '#!/bin/bash\n# Tool.\n'})
        self.assertEqual(model['cli'], [])


class CommandLineTests(unittest.TestCase):
    """Exit codes and usage handling of techdoc.py."""

    def run_tool(self, arguments):
        """Run techdoc.py in a subprocess.

        Args: arguments - argv tail.
        Returns: CompletedProcess.
        """
        # A separate interpreter proves the real entry point works.
        return subprocess.run([sys.executable, TECHDOC_SCRIPT] + arguments,
                              capture_output=True, text=True)

    def test_clean_file_exits_zero(self):
        """A clean file gives exit code 0 and the TOTAL line."""
        # A file with one valid function passes the gate.
        with tempfile.TemporaryDirectory() as directory:
            write_files(directory, {'ok.sh': '#!/bin/bash\n# Fine.\n\n' + VALID_FUNCTION})
            result = self.run_tool(['check', '--root', directory, 'ok.sh'])
        self.assertEqual((result.returncode, result.stdout), (0, 'TOTAL 0 violation(s)\n'))

    def test_violation_exits_one_with_reference_format(self):
        """A dirty file gives exit code 1 and `path:line: Rn message` lines."""
        # A function without a header breaks R1 four times.
        with tempfile.TemporaryDirectory() as directory:
            write_files(directory, {'bad.sh': '#!/bin/bash\n\nf() {\n    echo\n}\n'})
            result = self.run_tool(['check', '--root', directory, 'bad.sh'])
        self.assertEqual(result.returncode, 1)
        # The report names file, line and rule.
        self.assertIn('bad.sh:3: R1 header lacks "# f — <purpose>"\n', result.stdout)
        self.assertTrue(result.stdout.endswith('TOTAL 4 violation(s)\n'))

    def test_usage_errors_exit_two(self):
        """Missing subcommand, unknown subcommand and missing --out exit with 2."""
        self.assertEqual(self.run_tool([]).returncode, 2)
        self.assertEqual(self.run_tool(['frobnicate']).returncode, 2)
        self.assertEqual(self.run_tool(['build']).returncode, 2)

    def test_not_a_repository_exits_two(self):
        """check without file list outside a git repository is a usage error."""
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_tool(['check', '--root', directory])
        self.assertEqual(result.returncode, 2)

    def settings_document_root(self, directory, body='stale'):
        """Create a root with schema and a configuration document with markers.

        Args: directory - temporary directory; body - text between the markers.
        Returns: nothing.
        """
        document = 'Intro\n\n%s\n\n%s\n%s\n\nOutro\n' % (
            techdoc_settings.BEGIN_MARKER, body, techdoc_settings.END_MARKER)
        write_files(directory, {'config/settings.schema': SCHEMA_SAMPLE,
                                'docs/configuration.md': document})

    def test_settings_doc_check_detects_stale_and_write_fixes_it(self):
        """--check fails on a stale document, a plain run refreshes it, --check passes."""
        # Arrange: a document with a stale generated block.
        with tempfile.TemporaryDirectory() as directory:
            self.settings_document_root(directory)
            self.assertEqual(self.run_tool(['settings-doc', '--root', directory,
                                            '--check']).returncode, 1)
            self.assertEqual(self.run_tool(['settings-doc', '--root', directory]).returncode, 0)
            # After the refresh the check passes.
            self.assertEqual(self.run_tool(['settings-doc', '--root', directory,
                                            '--check']).returncode, 0)
            with open(os.path.join(directory, 'docs', 'configuration.md'),
                      encoding='utf-8') as handle:
                document = handle.read()
        self.assertIn('| `SCROLL_EVENT_DELAY_MS` | `scroll-event-delay-ms` |', document)
        # Text outside the markers is untouched.
        self.assertTrue(document.startswith('Intro\n'))
        self.assertTrue(document.endswith('Outro\n'))

    def test_settings_doc_without_markers_exits_two(self):
        """A document without markers is an environment problem."""
        # Without markers the tool cannot decide: an environment problem.
        with tempfile.TemporaryDirectory() as directory:
            write_files(directory, {'config/settings.schema': SCHEMA_SAMPLE,
                                    'docs/configuration.md': 'no markers\n'})
            result = self.run_tool(['settings-doc', '--root', directory, '--check'])
        self.assertEqual(result.returncode, 2)


def load_reference():
    """Import the vendored frozen reference implementation of the rules.

    Args: none.
    Returns: the module, or None when the file is not present.
    """
    # The reference is optional: without it the parity tests skip.
    if not os.path.isfile(REFERENCE_SCRIPT):
        # Without the reference there is nothing to import.
        return None
    spec = importlib.util.spec_from_file_location('reference_precheck', REFERENCE_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The loaded module exposes the reference rule functions.
    return module


def mutate(text, seed):
    """Create a deterministic random variant of a script text.

    Args: text - base script; seed - random seed.
    Returns: mutated script text.
    """
    generator = random.Random(seed)
    lines = text.split('\n')
    # A handful of structural edits stress every rule's edge cases.
    for _step in range(generator.randint(1, 6)):
        # Pick a random line and a random edit.
        position = generator.randrange(len(lines))
        action = generator.choice(['delete', 'duplicate', 'comment', 'blank', 'long', 'brace'])
        if action == 'delete':
            del lines[position]
        # Duplicating a line shifts statement and brace counts.
        elif action == 'duplicate':
            lines.insert(position, lines[position])
        elif action == 'comment':
            lines.insert(position, '# extra comment')
        # A blank line splits comment blocks and runs.
        elif action == 'blank':
            lines.insert(position, '')
        elif action == 'long':
            lines[position] = lines[position] + ' ' + 'z' * 95
        else:
            # A stray brace tests the function end detection.
            lines.insert(position, '}')
        if not lines:
            lines = ['']
    return '\n'.join(lines)


class ParityTests(unittest.TestCase):
    """`techdoc.py check` must equal the frozen reference (R1-R7) on fixtures and the repo."""

    def setUp(self):
        """Load the reference or skip.

        Args: none.
        Returns: nothing.
        """
        # Without the vendored reference nothing can be compared.
        self.reference = load_reference()
        if self.reference is None:
            self.skipTest('reference implementation not vendored')

    def reference_output(self, directory, path):
        """Render the reference verdict for one file in the gate format.

        Args: directory - repository root; path - relative file.
        Returns: list of 'path:line: message' strings.
        """
        # Shell vs python dispatch mirrors the reference main().
        if self.reference.is_shell_file(directory, path):
            return self.reference.check_shell(directory, path)
        return self.reference.check_python(directory, path)

    def new_output(self, directory, path):
        """Render the techdoc verdict for one file.

        Args: directory - repository root; path - relative file.
        Returns: list of 'path:line: message' strings.
        """
        # The same formatter the CLI uses.
        return [techdoc_rules.format_violation(violation)
                for violation in techdoc_rules.check_file(directory, path)]

    def test_fixture_corpus_matches_reference(self):
        """Hand-written and mutated fixtures give identical verdicts."""
        # Hand-written fixtures plus one mutant per seed.
        texts = {'valid.sh': '#!/bin/bash\n# Fine.\n\n' + VALID_FUNCTION,
                 'messy.sh': MESSY_SCRIPT, 'test-messy.sh': MESSY_SCRIPT,
                 'mod.py': '"""Doc."""\n\n\ndef f():\n    pass\n',
                 'test_mod.py': 'def t():\n    pass\n'}
        for seed in range(60):
            texts['mutant%02d.sh' % seed] = mutate(MESSY_SCRIPT + VALID_FUNCTION, seed)
        with tempfile.TemporaryDirectory() as directory:
            # Both implementations judge every file.
            write_files(directory, texts)
            for name in sorted(texts):
                self.assertEqual(self.new_output(directory, name),
                                 self.reference_output(directory, name), name)

    @unittest.skipUnless(HAS_GIT, 'git is required')
    def test_every_shell_and_python_file_of_this_repository_matches_reference(self):
        """Per-file verdicts of all tracked shell / python files equal the reference."""
        # The files of this very repository are the corpus.
        root = techdoc_repo.default_root(TOOL_DIRECTORY)
        paths = [path for path in techdoc_repo.tracked_files(root)
                 if techdoc_repo.file_kind(root, path) in ('shell', 'python')]
        if not paths:
            self.skipTest('no tracked shell or python files')
        # Each file must get the same verdict from both implementations.
        for path in paths:
            self.assertEqual(self.new_output(root, path), self.reference_output(root, path),
                             path)


if __name__ == '__main__':
    unittest.main()
