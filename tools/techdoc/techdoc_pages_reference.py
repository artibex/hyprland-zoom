"""Reference pages of the techdoc site: settings, CLI, CI workflows and Lua / C++ sources.

Every builder takes the documentation model (see techdoc_model) and returns the
complete page text.  The pages only exist when the model has content for them.
"""
from techdoc_html import (bullet_list, code, join_html, preformatted, render_page, table,
                          tag, verdict)
from techdoc_links import script_link, source_anchor
from techdoc_settings import allowed_values, default_text


def settings_rows(members):
    """Build the table rows of one settings group.

    Args: members - parsed settings of the group.
    Returns: list of cell lists.
    """
    rows = []
    for item in members:
        # The key carries the anchor other pages and documents can link to.
        rows.append([tag('code', item['key'], id=item['key']), code(item['cli']),
                     item['type'], code(default_text(item)), allowed_values(item),
                     join_html([tag('strong', item['label']), ' – ', item['help']])])
    return rows


def render_settings(model):
    """Render settings.html: every key of config/settings.schema.

    Args: model - documentation model.
    Returns: page text.
    """
    total = sum(len(group['settings']) for group in model['settings'])
    parts = [tag('p', '%d settings, generated from config/settings.schema.' % total)]
    for group in model['settings']:
        # One table per page of the settings window.
        parts.extend([tag('h2', group['title']),
                      table(['Key', 'zoomctl set', 'Type', 'Default', 'Allowed', 'Meaning'],
                            settings_rows(group['settings']))])
    return render_page('Settings reference', join_html(parts), 'settings.html', '',
                       model['meta'])


def entries_table(entries):
    """Render help entries (term / text) as table.

    Args: entries - list of dicts (term, text).
    Returns: Raw HTML table.
    """
    # Terms are code, descriptions plain text.
    return table(['Entry', 'Description'],
                 [[code(entry['term']), entry['text']] for entry in entries])


def render_cli_tool(tool):
    """Render the CLI section of one command line tool.

    Args: tool - dict (path, program, help).
    Returns: Raw HTML.
    """
    help_text = tool['help']
    parts = [tag('h2', tool['program']),
             tag('p', join_html(['Source: ', script_link(tool['path'], '')])),
             tag('p', ' '.join(help_text['intro'])),
             preformatted('\n'.join('Usage: ' + usage for usage in help_text['usage']))]
    for title, entries in (('Options', help_text['options']),
                           ('Commands', help_text['commands'])):
        # Sections without entries are not shown at all.
        if entries:
            parts.extend([tag('h3', title), entries_table(entries)])
    for section in help_text['sections']:
        parts.extend([tag('h3', section['title']), entries_table(section['entries'])])
    # Free text notes close the section.
    parts.append(preformatted('\n'.join(help_text['notes'])))
    return join_html(parts)


def render_cli(model):
    """Render cli.html: commands and options parsed statically from the help texts.

    Args: model - documentation model.
    Returns: page text.
    """
    # Each documented tool gets its own section.
    intro = tag('p', 'Parsed from the help text in the source; the tool is never run.',
                css_class='muted')
    body = join_html([intro] + [render_cli_tool(tool) for tool in model['cli']])
    return render_page('Command line', body, 'cli.html', '', model['meta'])


def job_row(job):
    """Render one job of a workflow as table cells.

    Args: job - job summary dict.
    Returns: list of cells.
    """
    where = job['container'] and '%s (container on %s)' % (job['container'], job['runs_on'])
    return [code(job['id']), job['name'], where or job['runs_on'],
            ', '.join(job['needs']) or '–', job['timeout'] or '–',
            job['permissions'] or '(workflow default)',
            bullet_list([code(action) for action in job['actions']])]


def render_workflow(workflow):
    """Render the section of one workflow file.

    Args: workflow - workflow summary dict.
    Returns: Raw HTML.
    """
    facts = bullet_list([
        join_html(['Triggers: ', ', '.join(workflow['triggers']) or '–']),
        join_html(['Default permissions: ', workflow['permissions'] or '–']),
        join_html(['Concurrency group: ', code(workflow['concurrency'] or '–')])])
    jobs = table(['Job', 'Name', 'Runs on', 'Needs', 'Timeout (min)', 'Permissions',
                  'Actions'], [job_row(job) for job in workflow['jobs']])
    return join_html([tag('h2', join_html([workflow['name'], ' ', code(workflow['path'])])),
                      facts, jobs])


def render_ci(model):
    """Render ci.html: the GitHub Actions workflows.

    Args: model - documentation model.
    Returns: page text.
    """
    body = join_html(render_workflow(workflow) for workflow in model['workflows'])
    return render_page('CI workflows', body, 'ci.html', '', model['meta'])


def lua_function_rows(source):
    """Render the function table rows of one Lua file.

    Args: source - Lua file dict.
    Returns: list of cell lists.
    """
    rows = []
    for item in source['functions']:
        contract = item['contract']
        # Public functions are the module interface; local ones are internal helpers.
        rows.append([code(item['name']), item['line'],
                     'public' if item['public'] else 'local', contract['purpose'],
                     contract['Args'], contract['Returns'],
                     verdict(item['documented'], 'yes', 'no')])
    return rows


def render_lua_source(source):
    """Render the section of one Lua file.

    Args: source - Lua file dict.
    Returns: Raw HTML.
    """
    heading = tag('h3', code(source['path']), id=source_anchor(source['path']))
    summary = tag('p', '%s (%d lines, header coverage %d %%)' % (
        source['purpose'] or 'no file header', source['lines'], source['coverage']))
    # The function table lists the parsed contracts.
    functions = table(['Function', 'Line', 'Scope', 'Purpose', 'Args', 'Returns', 'Header'],
                      lua_function_rows(source))
    return join_html([heading, summary, functions])


def render_cpp_source(source):
    """Render the section of one C++ file.

    Args: source - C++ file dict.
    Returns: Raw HTML.
    """
    heading = tag('h3', code(source['path']), id=source_anchor(source['path']))
    summary = tag('p', '%s (%d lines)' % (source['purpose'] or 'no file header',
                                          source['lines']))
    # One row per documented declaration.
    rows = [[code(item['name']), item['kind'], item['line'], item['brief']]
            for item in source['items']]
    return join_html([heading, summary, table(['Name', 'Kind', 'Line', 'Brief'], rows)])


def render_sources(model):
    """Render sources.html: the Lua engine and the C++ plugin.

    Args: model - documentation model.
    Returns: page text.
    """
    note = tag('p', 'Lua headers are checked by the gate (R8); the C++ overview lists the '
                    'declarations that carry a /// doc comment. Read statically, never '
                    'compiled or run.', css_class='muted')
    parts = [note, tag('h2', 'Lua engine')]
    parts.extend(render_lua_source(source) for source in model['sources']['lua'])
    # The plugin section follows the engine section.
    parts.append(tag('h2', 'C++ plugin'))
    parts.extend(render_cpp_source(source) for source in model['sources']['cpp'])
    return render_page('Lua and C++ sources', join_html(parts), 'sources.html', '',
                       model['meta'])
