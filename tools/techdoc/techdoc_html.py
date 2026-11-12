"""HTML building blocks of the techdoc site: escaping, tables, links, page frame.

Pure functions that return strings; no CDN, no JavaScript, one inline
stylesheet, so the site works offline and on GitHub Pages alike.
"""
import html

# Navigation entries of every page: (file name, label).
NAVIGATION = (
    ('index.html', 'Overview'),
    ('settings.html', 'Settings'),
    ('cli.html', 'CLI'),
    ('sources.html', 'Lua / C++'),
    ('ci.html', 'CI'),
    ('quality.html', 'Quality'),
)
# Pages that every site has; all others appear only when the model lists them.
ALWAYS_PRESENT = ('index.html', 'quality.html')
# Title suffix of every page.
SITE_TITLE = 'hyprland-zoom technical documentation'

# The single inline stylesheet of all pages.
STYLESHEET = """
body{font:15px/1.5 system-ui,sans-serif;margin:0;color:#1d2330;background:#f6f7f9}
header{background:#1d2330;color:#fff;padding:10px 24px}
header a{color:#cfe3ff;margin-right:14px;text-decoration:none}
header a.active{color:#fff;font-weight:700;border-bottom:2px solid #6cb2ff}
header .rev{float:right;font:12px monospace;color:#9fb1cc}
main{padding:16px 24px;max-width:1280px}
h1{font-size:24px}h2{margin-top:28px;border-bottom:1px solid #d5d9e0}
h3{margin-bottom:4px}
table{border-collapse:collapse;margin:8px 0;background:#fff}
th,td{border:1px solid #d5d9e0;padding:4px 8px;text-align:left;vertical-align:top}
th{background:#eceff4}
code,pre{font:13px/1.4 ui-monospace,Menlo,monospace}
pre{background:#fff;border:1px solid #d5d9e0;padding:8px;overflow-x:auto}
.ok{color:#176f2c;font-weight:700}.bad{color:#b3261e;font-weight:700}
.muted{color:#667085}.num{text-align:right}
details{margin:6px 0}
"""


class Raw(str):
    """Marks a string that already is HTML and must not be escaped again."""


def esc(value):
    """Escape a value for HTML unless it is already marked as HTML.

    Args: value - any value (None renders as '').
    Returns: HTML-safe string.
    """
    # Raw strings pass through, everything else is escaped.
    if isinstance(value, Raw):
        return str(value)
    # None renders as an empty cell.
    if value is None:
        return ''
    return html.escape(str(value), quote=True)


def tag(name, content, **attributes):
    """Render one HTML element.

    Args: name - tag name; content - inner value (escaped unless Raw);
          attributes - HTML attributes (`css_class` becomes `class`).
    Returns: Raw HTML string.
    """
    # `class` is a python keyword, so it is passed as css_class.
    rendered = ''.join(' %s="%s"' % (key.replace('css_class', 'class').replace('_', '-'),
                                     esc(value))
                       for key, value in sorted(attributes.items()) if value is not None)
    return Raw('<%s%s>%s</%s>' % (name, rendered, esc(content), name))


def join_html(parts):
    """Concatenate already rendered parts.

    Args: parts - iterable of values (escaped unless Raw).
    Returns: Raw HTML string.
    """
    # Each part is escaped individually; Raw parts stay untouched.
    return Raw(''.join(esc(part) for part in parts))


def link(href, text):
    """Render an anchor element.

    Args: href - target; text - label (escaped unless Raw).
    Returns: Raw HTML string.
    """
    # The label may be Raw (for example a <code> element).
    return tag('a', text, href=href)


def code(text):
    """Render inline code.

    Args: text - code text.
    Returns: Raw HTML string.
    """
    # Escaping happens inside tag().
    return tag('code', text)


def table(headers, rows, css_class=None):
    """Render a table.

    Args: headers - list of column titles; rows - list of cell lists;
          css_class - optional class of the table.
    Returns: Raw HTML string.
    """
    # Header row first, then one <tr> per row; every cell is escaped.
    head = tag('tr', join_html(tag('th', title) for title in headers))
    body = join_html(tag('tr', join_html(tag('td', cell) for cell in row)) for row in rows)
    return tag('table', join_html([head, body]), css_class=css_class)


def bullet_list(items):
    """Render an unordered list.

    Args: items - list of values (escaped unless Raw).
    Returns: Raw HTML string ('' for an empty list).
    """
    # Empty lists render as nothing instead of an empty <ul>.
    if not items:
        return Raw('')
    return tag('ul', join_html(tag('li', item) for item in items))


def preformatted(text):
    """Render a preformatted text block.

    Args: text - text (escaped).
    Returns: Raw HTML string.
    """
    # Whitespace is kept by <pre>.
    return tag('pre', text)


def verdict(passed, ok_text='passed', bad_text='violated'):
    """Render a coloured pass/fail marker.

    Args: passed - boolean; ok_text / bad_text - labels.
    Returns: Raw HTML string.
    """
    # Colour classes are defined in the stylesheet.
    if passed:
        return tag('span', ok_text, css_class='ok')
    return tag('span', bad_text, css_class='bad')


def navigation(active, prefix, pages=None):
    """Render the navigation bar.

    Args: active - file name of the current page; prefix - '' or '../';
          pages - file names of the optional pages that exist (None = all).
    Returns: Raw HTML string.
    """
    entries = []
    for file_name, label in NAVIGATION:
        # Pages without content (no workflows, no schema, ...) get no entry.
        if pages is not None and file_name not in ALWAYS_PRESENT + tuple(pages):
            continue
        # The current page is highlighted by a class.
        css = 'active' if file_name == active else None
        entries.append(tag('a', label, href=prefix + file_name, css_class=css))
    return join_html(entries)


def render_page(title, body, active, prefix, meta):
    """Wrap a body into the full HTML document.

    Args: title - page title; body - Raw HTML body; active - nav file name;
          prefix - relative path to the site root ('' or '../');
          meta - dict with 'sha', 'ref' and optionally 'pages'.
    Returns: complete HTML document text.
    """
    # The revision stamp shows which commit the documentation describes.
    revision = '%s @ %s' % (meta.get('ref', ''), str(meta.get('sha', ''))[:12])
    header = tag('header', join_html([navigation(active, prefix, meta.get('pages')),
                                      tag('span', revision, css_class='rev')]))
    document = [
        '<!DOCTYPE html>',
        '<html lang="en"><head><meta charset="utf-8">',
        '<title>%s</title>' % esc('%s – %s' % (title, SITE_TITLE)),
        '<style>%s</style></head><body>' % STYLESHEET,
        str(header),
        str(tag('main', join_html([tag('h1', title), body]))),
        '</body></html>',
    ]
    return '\n'.join(document) + '\n'
