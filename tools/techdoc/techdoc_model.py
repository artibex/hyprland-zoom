"""Assembles the complete documentation model (techdoc.json) of a repository.

The model is a plain, deterministic dict: sorted, no wall-clock, no absolute
paths.  The HTML pages and techdoc.json are both rendered from it.
"""
# Standard library: paths and patterns.
import os
import re

# Sibling modules: documents, help text and file access.
from techdoc_docs import build_docs
from techdoc_help import parse_help_text
from techdoc_repo import file_kind, read_text, revision_info, tracked_files
# Gate verdicts and script analysis.
from techdoc_rules import RULE_IDS, RULE_TITLES, check_files, violation_rule
from techdoc_scripts import (analyze_python, analyze_shell, count_documented,
                             header_coverage, link_script_graph)
from techdoc_settings import grouped_settings, load_settings
# Sources and workflows complete the model.
from techdoc_sources import build_sources
from techdoc_workflows import WORKFLOW_PATH_PATTERN, parse_workflow

# Pages that exist only when the repository has the matching input: (model key, file).
OPTIONAL_PAGES = (('settings', 'settings.html'), ('cli', 'cli.html'),
                  ('workflows', 'ci.html'))
# First markdown heading of a README, used as component description.
HEADING_PATTERN = re.compile(r'^#\s+(.+)$', re.MULTILINE)


def analyze_scripts(root, paths):
    """Analyse every tracked shell and python script.

    Args: root - repository root; paths - tracked relative paths.
    Returns: list of script dicts sorted by path, with calls linked.
    """
    scripts = []
    for path in sorted(paths):
        # Dispatch on the file kind; Lua and non-code files are handled elsewhere.
        kind = file_kind(root, path)
        if kind == 'shell':
            scripts.append(analyze_shell(root, path))
        # Python sources are read through the ast module.
        elif kind == 'python':
            scripts.append(analyze_python(root, path))
    # Resolve calls / called-by across the whole repository.
    link_script_graph(scripts)
    return scripts


def readme_title(root, directory):
    """Read the first heading of a directory's README.md.

    Args: root - repository root; directory - relative directory.
    Returns: heading text or ''.
    """
    # A missing README gives an empty description.
    text = read_text(root, os.path.join(directory, 'README.md'))
    match = HEADING_PATTERN.search(text)
    return match.group(1).strip() if match else ''


def build_components(root, scripts):
    """Group scripts by directory into components.

    Args: root - repository root; scripts - script dicts.
    Returns: list of dicts (path, title, scripts, lines, functions, coverage).
    """
    groups = {}
    for script in scripts:
        groups.setdefault(os.path.dirname(script['path']), []).append(script)
    # One component per directory, in sorted order.
    components = []
    for directory in sorted(groups):
        members = groups[directory]
        # Totals of the directory feed the coverage figure.
        functions = sum(len(script['functions']) for script in members)
        documented = sum(script['documented'] for script in members)
        components.append({
            'path': directory or '.',
            'title': readme_title(root, directory),
            'scripts': [script['path'] for script in members],
            'lines': sum(script['metrics']['total'] for script in members),
            'functions': functions,
            'coverage': documented * 100 // functions if functions else 100,
        })
    return components


def count_violations(violations, group_by):
    """Count violations per rule, optionally split by file.

    Args: violations - list of Violation; group_by - 'path' or None (one group).
    Returns: dict mapping the group (path or '') to a dict of rule id -> count.
    """
    counts = {}
    for violation in violations:
        group = violation.path if group_by == 'path' else ''
        # Every group starts with an empty rule table.
        per_rule = counts.setdefault(group, {})
        rule = violation_rule(violation)
        per_rule[rule] = per_rule.get(rule, 0) + 1
    return counts


def build_quality(root, paths, scripts, sources):
    """Run the gate over all tracked files and summarise the verdict.

    Args: root - repository root; paths - tracked paths; scripts - script dicts;
          sources - dict of Lua / C++ file dicts.
    Returns: dict (total, rules, files, violations, metrics).
    """
    violations = check_files(root, paths)
    by_rule = count_violations(violations, None).get('', {})
    by_file = count_violations(violations, 'path')
    # Scripts and Lua sources are the files the gate judges individually.
    judged = [item['path'] for item in scripts] + [item['path'] for item in sources['lua']]
    return {
        'total': len(violations),
        'rules': [{'id': rule, 'title': RULE_TITLES[rule], 'violations': by_rule.get(rule, 0)}
                  for rule in RULE_IDS],
        'files': [{'path': path, 'counts': by_file.get(path, {}),
                   'total': sum(by_file.get(path, {}).values())} for path in judged],
        'violations': [{'path': v.path, 'line': v.line, 'rule': violation_rule(v),
                        'text': v.text} for v in violations],
        'metrics': quality_metrics(scripts, sources),
    }


def quality_metrics(scripts, sources):
    """Compute repository-wide code metrics.

    Args: scripts - script dicts (with 'documented'); sources - Lua / C++ file dicts.
    Returns: dict of totals; functions count shell, python and Lua functions together.
    """
    # Lua functions carry their own documented flag; scripts were counted by finalize.
    lua_functions = [item for source in sources['lua'] for item in source['functions']]
    functions = sum(len(script['functions']) for script in scripts) + len(lua_functions)
    documented = (sum(script['documented'] for script in scripts)
                  + sum(1 for item in lua_functions if item['documented']))
    return {
        'scripts': len(scripts),
        'lua_files': len(sources['lua']),
        'cpp_files': len(sources['cpp']),
        'lines': sum(script['metrics']['total'] for script in scripts),
        'comment_lines': sum(script['metrics']['comment'] for script in scripts),
        'functions': functions,
        'documented_functions': documented,
        'coverage': documented * 100 // functions if functions else 100,
    }


def finalize_scripts(scripts):
    """Add coverage numbers to every script.

    Args: scripts - script dicts (modified).
    Returns: nothing.
    """
    for script in scripts:
        # Documented functions drive the header coverage metric.
        script['documented'] = count_documented(script)
        script['coverage'] = header_coverage(script)
        script['max_function_lines'] = max(
            [item.get('body_lines', 0) for item in script['functions']] or [0])


def build_cli(root, scripts):
    """Parse the help text of every shell source that has a statically readable one.

    Args: root - repository root; scripts - analysed script dicts.
    Returns: list of dicts (path, program, help); sources without help text are not listed.
    """
    tools = []
    for script in scripts:
        # Only shell sources that are not test suites can hold a help text.
        if script['kind'] != 'shell' or script['is_test']:
            continue
        help_text = parse_help_text(read_text(root, script['path']))
        if help_text['found']:
            # The program name is the first word of the `Usage:` line.
            usage = (help_text['usage'] or [script['path']])[0]
            tools.append({'path': script['path'], 'help': help_text,
                          'program': usage.split()[0]})
    return tools


def build_workflows(root, paths):
    """Summarise every GitHub Actions workflow of the repository.

    Args: root - repository root; paths - tracked relative paths.
    Returns: list of workflow dicts sorted by path.
    """
    return [parse_workflow(path, read_text(root, path)) for path in sorted(paths)
            if WORKFLOW_PATH_PATTERN.match(path)]


def present_pages(model):
    """List the optional pages that have content (all others are omitted).

    Args: model - documentation model without 'pages'.
    Returns: sorted list of page file names.
    """
    pages = [name for key, name in OPTIONAL_PAGES if model[key]]
    # The Lua / C++ page needs at least one documented source file.
    if model['sources']['lua'] or model['sources']['cpp']:
        pages.append('sources.html')
    return sorted(pages)


def build_model(root):
    """Build the complete documentation model.

    Args: root - repository root (a git checkout).
    Returns: JSON-serialisable dict with meta, components, scripts, cli, settings,
             workflows, sources (Lua / C++), docs (handwritten) and quality.
    """
    paths = tracked_files(root)
    scripts = analyze_scripts(root, paths)
    # Coverage numbers are needed by the components below.
    finalize_scripts(scripts)
    sources = build_sources(root, paths)
    model = {
        'meta': dict(revision_info(root), generator='techdoc'),
        'components': build_components(root, scripts),
        'scripts': scripts,
        'cli': build_cli(root, scripts),
        'settings': [{'group': group, 'title': title, 'settings': members}
                     for group, title, members in grouped_settings(load_settings(root))],
        'workflows': build_workflows(root, paths),
        'sources': sources,
        'docs': build_docs(root, paths, os.environ),
        'quality': build_quality(root, paths, scripts, sources),
    }
    # The navigation of every page lists exactly the pages that exist.
    model['meta']['pages'] = present_pages(model)
    return model
