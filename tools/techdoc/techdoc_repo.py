"""Repository access of the techdoc tool: tracked files and file classification.

Everything the gate and the site generator know about "which files exist"
comes from `git ls-files`, so untracked or ignored files never show up.
"""
import os
import re
import subprocess

# Environment variables that GitHub Actions sets for the commit being documented.
CI_SHA_VARIABLE = 'GITHUB_SHA'
CI_REF_VARIABLE = 'GITHUB_REF_NAME'
# Placeholder shown when neither CI variables nor git can answer.
UNKNOWN_REVISION = 'unknown'
# Shebang interpreters that mark a file as a shell script.
SHELL_SHEBANG_PATTERN = re.compile(rb'\b(ba)?sh\b')


class RepositoryError(Exception):
    """Raised when the repository root is unusable (for example not a git checkout)."""


def tracked_files(root):
    """Return all git-tracked file paths of the repository.

    Args: root - repository root directory.
    Returns: list of relative paths in git order.
    """
    # Ask git for the tracked paths; a missing git or repo is a hard error.
    try:
        listing = subprocess.run(['git', '-C', root, 'ls-files'],
                                 capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise RepositoryError('git ls-files failed in %s: %s' % (root, error))
    # Drop the empty element that the trailing newline produces.
    return [line for line in listing.stdout.split('\n') if line]


def is_shell_file(root, path):
    """Tell whether a tracked file is a shell script (.sh or sh/bash shebang).

    Args: root - repository root; path - relative path.
    Returns: True for shell scripts.
    """
    # The extension alone is decisive for *.sh files.
    if path.endswith('.sh'):
        return True
    # Files that vanished from the working tree cannot be classified.
    full_path = os.path.join(root, path)
    if not os.path.isfile(full_path):
        return False
    # Only the first line (the shebang) is needed, read it as bytes.
    with open(full_path, 'rb') as handle:
        first_line = handle.readline()
    # A shebang that names sh or bash makes the file a shell script.
    has_shebang = first_line.startswith(b'#!')
    return has_shebang and SHELL_SHEBANG_PATTERN.search(first_line) is not None


def is_test_file(path):
    """Tell whether a path is a test suite (relaxed rules) or a fixture.

    Args: path - relative path.
    Returns: True for test-*.sh / test_*.py / test_*.lua / anything under /fixtures/.
    """
    # Test suites are recognised by the basename prefix.
    base_name = os.path.basename(path)
    has_test_prefix = base_name.startswith('test-') or base_name.startswith('test_')
    # Fixture trees count as test material as well.
    return has_test_prefix or '/fixtures/' in path


def file_kind(root, path):
    """Classify a tracked file for the gate and the generator.

    Args: root - repository root; path - relative path.
    Returns: 'shell', 'python', 'lua' or None for everything else.
    """
    # Shell wins over python, exactly like the reference implementation.
    if is_shell_file(root, path):
        return 'shell'
    # Plain extension test for python and Lua sources.
    if path.endswith('.py'):
        return 'python'
    if path.endswith('.lua'):
        return 'lua'
    # Anything else is not documented as a script.
    return None


def read_lines(root, path):
    """Read a text file as a list of lines without line terminators.

    Args: root - repository root; path - relative path.
    Returns: list of lines (a final newline yields a trailing empty line).
    """
    # UTF-8 with replacement keeps odd bytes from aborting the run.
    full_path = os.path.join(root, path)
    with open(full_path, encoding='utf-8', errors='replace') as handle:
        return handle.read().split('\n')


def read_text(root, path):
    """Read a text file completely.

    Args: root - repository root; path - relative path.
    Returns: the file content as string ('' when the file does not exist).
    """
    # A missing file is reported as empty content, never as an error.
    full_path = os.path.join(root, path)
    if not os.path.isfile(full_path):
        return ''
    # UTF-8 with replacement keeps odd bytes from aborting the run.
    with open(full_path, encoding='utf-8', errors='replace') as handle:
        return handle.read()


def git_output(root, arguments):
    """Run a read-only git command and return its first output line.

    Args: root - repository root; arguments - git arguments after `-C root`.
    Returns: stripped stdout or '' when git fails.
    """
    # Never raise: documentation must still build outside a git checkout.
    try:
        result = subprocess.run(['git', '-C', root] + arguments,
                                capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ''
    # Only the first line is interesting for revision data.
    return result.stdout.strip()


def revision_info(root):
    """Determine commit and ref that the generated documentation describes.

    Args: root - repository root.
    Returns: dict with 'sha' and 'ref' (CI variables first, then git).
    """
    # CI provides both values; they win because the checkout may be detached.
    sha = os.environ.get(CI_SHA_VARIABLE, '')
    ref = os.environ.get(CI_REF_VARIABLE, '')
    # Fall back to git for whatever CI did not provide.
    if not sha:
        sha = git_output(root, ['rev-parse', 'HEAD'])
    if not ref:
        ref = git_output(root, ['rev-parse', '--abbrev-ref', 'HEAD'])
    # Never leave the header empty.
    return {'sha': sha or UNKNOWN_REVISION, 'ref': ref or UNKNOWN_REVISION}


def default_root(script_directory):
    """Guess the repository root for a tool living in tools/techdoc.

    Args: script_directory - directory of techdoc.py.
    Returns: git top-level directory, else two levels above the script.
    """
    # git knows the real top level, also for sparse checkouts.
    top_level = git_output(script_directory, ['rev-parse', '--show-toplevel'])
    if top_level:
        return top_level
    # Without git the fixed tool location (tools/techdoc) decides.
    return os.path.abspath(os.path.join(script_directory, '..', '..'))
