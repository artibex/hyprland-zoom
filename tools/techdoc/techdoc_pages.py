"""Core page builders of the techdoc site: index, per-script pages, quality and assembly.

File layout of the site: index.html and quality.html always; settings.html, cli.html,
ci.html and sources.html only when the repository has the matching input (see
techdoc_pages_reference); one scripts/<slug>.html per tracked shell or python script.
"""
# Standard library: model file and output paths.
import json
import os

from techdoc_html import (Raw, bullet_list, code, join_html, link, preformatted,
                          render_page, table, tag, verdict)
# Link helpers, reference pages and script analysis.
from techdoc_links import function_anchor, script_link, script_page_name, source_link
from techdoc_pages_reference import (render_ci, render_cli, render_settings,
                                     render_sources)
from techdoc_scripts import item_is_documented

# Name of the machine-readable model next to the pages.
MODEL_FILE = 'techdoc.json'


def render_index(model):
    """Render index.html: components and the scripts table.

    Args: model - documentation model.
    Returns: page text.
    """
    metrics = model['quality']['metrics']
    total = model['quality']['total']
    # Overview numbers first, then the documents, components and the scripts table.
    summary = bullet_list([
        'Scripts: %d (%d lines), Lua files: %d, C++ files: %d' % (
            metrics['scripts'], metrics['lines'], metrics['lua_files'], metrics['cpp_files']),
        'Functions: %d, documented: %d (%d %%)' % (
            metrics['functions'], metrics['documented_functions'], metrics['coverage']),
        join_html(['Gate verdict: ', verdict(total == 0, 'green (0 violations)',
                                             'red (%d violations)' % total),
                   ' – ', link('quality.html', 'details')]),
    ])
    body = join_html([summary, docs_section(model), tag('h2', 'Components'),
                      components_table(model), tag('h2', 'Scripts'), scripts_table(model)])
    return render_page('Technical documentation', body, 'index.html', '', model['meta'])


def docs_section(model):
    """Render the link list to the handwritten documents (docs/*.md).

    Args: model - documentation model.
    Returns: Raw HTML; empty when the repository has no docs/ folder.
    """
    # Without documents there is nothing to link, so no empty heading appears.
    if not model['docs']:
        return Raw('')
    items = [join_html([link(document['href'], document['title']), ' – ',
                        code(document['path'])]) for document in model['docs']]
    return join_html([tag('h2', 'Handwritten documentation'), bullet_list(items)])


def components_table(model):
    """Render the components table of the index page.

    Args: model - documentation model.
    Returns: Raw HTML table.
    """
    rows = []
    for component in model['components']:
        # One row per directory with its aggregate numbers.
        rows.append([code(component['path']), component['title'], len(component['scripts']),
                     component['lines'], component['functions'],
                     '%d %%' % component['coverage']])
    return table(['Component', 'Description', 'Scripts', 'Lines', 'Functions',
                  'Header coverage'], rows)


def scripts_table(model):
    """Render the scripts table of the index page.

    Args: model - documentation model.
    Returns: Raw HTML table.
    """
    rows = []
    for script in model['scripts']:
        # Path (linked), purpose from the file header and the key metrics.
        rows.append([script_link(script['path'], ''), script['kind'], script['purpose'],
                     script['metrics']['total'], len(script['functions']),
                     '%d %%' % script['coverage']])
    return table(['Path', 'Kind', 'Purpose (file header)', 'Lines', 'Functions',
                  'Header coverage'], rows)


def contract_rows(item):
    """Render the contract fields of a shell function as table rows.

    Args: item - function dict with 'contract'.
    Returns: list of [label, text] rows (empty fields omitted).
    """
    # Only fields that actually carry text are listed.
    contract = item['contract']
    labels = [('Purpose', 'purpose'), ('Args', 'Args'), ('Returns', 'Returns'),
              ('Globals', 'Globals'), ('Notes', 'Notes')]
    return [[label, contract[key]] for label, key in labels if contract[key]]


def call_links(entries, prefix, current_path):
    """Render call / called-by entries as links.

    Args: entries - list of {path, name}; prefix - relative prefix;
          current_path - path of the page being rendered.
    Returns: Raw HTML ('–' for an empty list).
    """
    # Same-file targets link to the anchor on the same page.
    if not entries:
        return Raw('–')
    # Collect the links together with their separators.
    parts = []
    for position, entry in enumerate(entries):
        parts.append(', ' if position else '')
        # Functions of other files are prefixed with their path.
        label = entry['name'] if entry['path'] == current_path else '%s: %s' % (
            entry['path'], entry['name'])
        parts.append(script_link(entry['path'], prefix, label, function_anchor(entry['name'])))
    return join_html(parts)


def render_function(script, item):
    """Render the detail section of one function.

    Args: script - script dict; item - function dict.
    Returns: Raw HTML section.
    """
    heading = tag('h3', join_html([code(item['name'] + item.get('signature', '')),
                                   tag('span', ' line %d' % item['line'],
                                       css_class='muted')]),
                  id=function_anchor(item['name']))
    # Shell functions show the parsed contract, python ones the docstring.
    if script['kind'] == 'shell':
        detail = table(['Field', 'Content'], contract_rows(item)
                       or [['Purpose', 'no function header (R1)']])
    else:
        detail = preformatted(item['docstring'] or '(no docstring)')
    # Call relations are the same for shell and python.
    relations = table(['Relation', 'Functions'], [
        ['calls', call_links(item['calls'], '../', script['path'])],
        ['called by', call_links(item['called_by'], '../', script['path'])]])
    return join_html([heading, detail, relations])


def functions_summary(script):
    """Render the function overview table of a script page.

    Args: script - script dict.
    Returns: Raw HTML table.
    """
    rows = []
    for item in script['functions']:
        # Jump links to the detail sections below.
        purpose = item['contract']['purpose'] if script['kind'] == 'shell' else (
            item['docstring'].split('\n', 1)[0])
        rows.append([link('#' + function_anchor(item['name']), item['name']), item['line'],
                     purpose, verdict(item_is_documented(script, item), 'yes', 'no')])
    return table(['Function', 'Line', 'Purpose', 'Header / docstring'], rows)


def render_script(model, script):
    """Render the page of one script.

    Args: model - documentation model; script - script dict.
    Returns: page text.
    """
    metrics = script['metrics']
    facts = table(['Metric', 'Value'], [
        ['Kind', script['kind'] + (' (test)' if script['is_test'] else '')],
        ['Lines', '%d (code %d, comment %d, blank %d)' % (
            metrics['total'], metrics['code'], metrics['comment'], metrics['blank'])],
        ['Functions', len(script['functions'])],
        ['Header coverage', '%d %%' % script['coverage']],
        ['Longest function (lines)', script['max_function_lines']]])
    # Only the violations of this script belong on its page.
    violations = [v for v in model['quality']['violations'] if v['path'] == script['path']]
    header = preformatted('\n'.join(script['header']) or '(no file header)')
    body = join_html([
        tag('p', script['purpose']), facts, tag('h2', 'File header'), header,
        tag('h2', 'Functions'), functions_summary(script),
        join_html(render_function(script, item) for item in script['functions']),
        tag('h2', 'Gate violations (%d)' % len(violations)), violations_table(violations)])
    return render_page(script['path'], body, '', '../', model['meta'])


def violations_table(violations):
    """Render a table of gate violations.

    Args: violations - list of dicts (line, rule, text).
    Returns: Raw HTML table, or a note when empty.
    """
    # A clean file is stated explicitly instead of showing an empty table.
    if not violations:
        return tag('p', 'no violations', css_class='ok')
    return table(['Line', 'Rule', 'Message'],
                 [[v['line'], v['rule'], v['text']] for v in violations])


def quality_file_link(entry):
    """Render the file cell of the quality table (scripts and Lua files have pages).

    Args: entry - file dict (path, counts, total).
    Returns: Raw HTML link.
    """
    # Lua files have no page of their own; they live on the sources page.
    if entry['path'].endswith('.lua'):
        return source_link(entry['path'], '')
    return script_link(entry['path'], '')


def render_quality(model):
    """Render quality.html: gate verdict per rule and per file plus metrics.

    Args: model - documentation model.
    Returns: page text.
    """
    quality = model['quality']
    rules = table(['Rule', 'Meaning', 'Violations', 'Verdict'],
                  [[rule['id'], rule['title'], rule['violations'],
                    verdict(rule['violations'] == 0)] for rule in quality['rules']])
    # One row per judged file with its per-rule counts.
    files = table(['File', 'Violations', 'Per rule'],
                  [[quality_file_link(entry), entry['total'],
                    ', '.join('%s: %d' % pair for pair in sorted(entry['counts'].items()))]
                   for entry in quality['files']])
    metrics = quality['metrics']
    overall = verdict(quality['total'] == 0, 'green', 'red (%d violations)' % quality['total'])
    # Verdict first, then rules, files and metrics.
    body = join_html([
        tag('p', join_html(['Overall: ', overall])),
        tag('h2', 'Rules'), rules, tag('h2', 'Files'), files,
        tag('h2', 'Metrics'), bullet_list([
            'Scripts: %d' % metrics['scripts'], 'Lines: %d' % metrics['lines'],
            'Comment lines: %d' % metrics['comment_lines'],
            'Functions: %d (documented: %d, %d %%)' % (
                metrics['functions'], metrics['documented_functions'], metrics['coverage'])])])
    return render_page('Code quality', body, 'quality.html', '', model['meta'])


def site_pages(model):
    """Collect every page of the site.

    Args: model - documentation model.
    Returns: dict mapping site-relative file name to page text.
    """
    renderers = {'settings.html': render_settings, 'cli.html': render_cli,
                 'ci.html': render_ci, 'sources.html': render_sources}
    pages = {'index.html': render_index(model), 'quality.html': render_quality(model)}
    # Optional pages are written only when the model says they have content.
    for name in model['meta']['pages']:
        pages[name] = renderers[name](model)
    # One page per tracked script.
    for script in model['scripts']:
        pages[script_page_name(script['path'])] = render_script(model, script)
    return pages


def write_site(model, out_directory):
    """Write all pages and techdoc.json into a directory.

    Args: model - documentation model; out_directory - target directory.
    Returns: sorted list of written site-relative file names.
    """
    pages = site_pages(model)
    pages[MODEL_FILE] = json.dumps(model, ensure_ascii=False, indent=2) + '\n'
    for name, content in pages.items():
        # Create the sub-directory (scripts/) on demand.
        target = os.path.join(out_directory, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        # Pages are UTF-8 so that dashes and arrows survive.
        with open(target, 'w', encoding='utf-8') as handle:
            handle.write(content)
    return sorted(pages)
