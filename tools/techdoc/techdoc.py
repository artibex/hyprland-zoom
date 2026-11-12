#!/usr/bin/env python3
"""techdoc — code-quality gate and generated technical documentation.

Subcommands:
  check [--root R] [files...]   gate R1-R8 (exit 0 clean, 1 violations, 2 usage)
  build --out DIR [--root R]    static HTML site + techdoc.json (offline, no CDN)
  settings-doc [--root R] [--check]
                                refresh (or verify) the generated settings tables of
                                docs/configuration.md from config/settings.schema

Python >= 3.8, standard library only; the repository is only read, never executed.
"""
# Standard library: options, paths and streams.
import argparse
import os
import sys

# Repository access, the gate and the settings tables.
from techdoc_repo import RepositoryError, default_root, read_text, tracked_files
from techdoc_rules import absolute_root, check_files, render_report
from techdoc_settings import CONFIGURATION_DOC_PATH, expected_configuration_doc

# Exit codes of the tool.
EXIT_CLEAN = 0
EXIT_VIOLATIONS = 1
EXIT_USAGE = 2


def build_parser(default_repository):
    """Create the command line parser.

    Args: default_repository - root used when --root is not given.
    Returns: configured argparse.ArgumentParser.
    """
    parser = argparse.ArgumentParser(
        prog='techdoc.py', description='Code-quality gate and technical documentation.')
    commands = parser.add_subparsers(dest='command', metavar='{check,build,settings-doc}')
    commands.required = True
    # `check` takes an optional explicit file list.
    check = commands.add_parser('check', help='check rules R1-R8 (the gate)')
    check.add_argument('--root', default=default_repository, help='repository root')
    check.add_argument('files', nargs='*', help='relative files (default: all tracked)')
    # `build` needs an output directory.
    build = commands.add_parser('build', help='write the HTML site and techdoc.json')
    build.add_argument('--root', default=default_repository, help='repository root')
    build.add_argument('--out', required=True, help='output directory')
    # `settings-doc` keeps docs/configuration.md in step with the schema.
    settings = commands.add_parser('settings-doc', help='refresh or verify the settings tables')
    settings.add_argument('--root', default=default_repository, help='repository root')
    settings.add_argument('--check', action='store_true',
                          help='only verify; exit 1 when the document is out of date')
    return parser


def run_check(root, files):
    """Run the gate and print its report.

    Args: root - repository root; files - explicit relative files or [].
    Returns: EXIT_CLEAN or EXIT_VIOLATIONS.
    """
    # Without an explicit list every tracked file is checked.
    root = absolute_root(root)
    selected = files or tracked_files(root)
    violations = check_files(root, selected)
    # The report is the contract with CI: one line per violation.
    sys.stdout.write(render_report(violations))
    return EXIT_VIOLATIONS if violations else EXIT_CLEAN


def run_build(root, out_directory):
    """Build the documentation site.

    Args: root - repository root; out_directory - target directory.
    Returns: EXIT_CLEAN (rule violations never fail the build).
    """
    # Imported lazily so `check` stays independent of the renderer.
    from techdoc_model import build_model
    from techdoc_pages import write_site
    model = build_model(absolute_root(root))
    written = write_site(model, os.path.abspath(out_directory))
    # The summary names the gate verdict, which never fails the build.
    print('techdoc: wrote %d files to %s (gate: %d violations)'
          % (len(written), out_directory, model['quality']['total']))
    return EXIT_CLEAN


def run_settings_doc(root, verify_only):
    """Refresh or verify the generated settings tables of docs/configuration.md.

    Args: root - repository root; verify_only - True to compare without writing.
    Returns: EXIT_CLEAN when the document is current (or was refreshed),
             EXIT_VIOLATIONS when --check finds it stale, EXIT_USAGE without markers.
    """
    root = absolute_root(root)
    expected = expected_configuration_doc(root)
    # A missing document or marker is an environment problem, not staleness.
    if expected is None:
        print('techdoc: %s or its generated-settings markers are missing'
              % CONFIGURATION_DOC_PATH, file=sys.stderr)
        return EXIT_USAGE
    # Nothing to do when the document is current.
    if read_text(root, CONFIGURATION_DOC_PATH) == expected:
        return EXIT_CLEAN
    # Verification mode reports staleness without touching files.
    if verify_only:
        print('techdoc: %s is out of date; run techdoc.py settings-doc' % CONFIGURATION_DOC_PATH)
        return EXIT_VIOLATIONS
    # Rewrite in place; git shows the change.
    with open(os.path.join(root, CONFIGURATION_DOC_PATH), 'w', encoding='utf-8') as handle:
        handle.write(expected)
    print('techdoc: refreshed %s' % CONFIGURATION_DOC_PATH)
    return EXIT_CLEAN


def main(arguments):
    """Entry point: parse arguments and dispatch to the subcommand.

    Args: arguments - argv without the program name.
    Returns: process exit code.
    """
    script_directory = os.path.dirname(os.path.abspath(__file__))
    parser = build_parser(default_root(script_directory))
    options = parser.parse_args(arguments)
    # Environment problems are usage errors (exit 2), not violations.
    try:
        if options.command == 'check':
            return run_check(options.root, options.files)
        # The refresh command rewrites the configuration document.
        if options.command == 'settings-doc':
            return run_settings_doc(options.root, options.check)
        # Everything else is the site build.
        return run_build(options.root, options.out)
    except (RepositoryError, OSError) as error:
        print('techdoc: %s' % error, file=sys.stderr)
        return EXIT_USAGE


# Run only as a script, never when the tests import the module.
if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
