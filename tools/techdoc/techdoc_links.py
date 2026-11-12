"""Link helpers of the techdoc site: page names and anchors of scripts and sources.

Shared by all page builders so that a link is built in exactly one place.
"""
import os

from techdoc_html import join_html, link

# Directory of the per-script pages inside the site.
SCRIPT_DIRECTORY = 'scripts'
# Page that documents the Lua and C++ sources.
SOURCES_PAGE = 'sources.html'


def script_page_name(path):
    """Compute the page file name of a script.

    Args: path - repository-relative script path.
    Returns: site-relative path such as 'scripts/src__zoomctl.html'.
    """
    # Slashes become double underscores; the name stays unique and readable.
    slug = path.replace('/', '__').replace(' ', '_')
    return '%s/%s.html' % (SCRIPT_DIRECTORY, slug)


def script_href(path, prefix, anchor=''):
    """Build a link target to a script page.

    Args: path - script path; prefix - '' (site root) or '../' (script page);
          anchor - optional fragment without '#'.
    Returns: relative URL.
    """
    # Script pages sit in one directory: siblings link by file name only.
    target = script_page_name(path)
    if prefix:
        target = os.path.basename(target)
    return target + ('#' + anchor if anchor else '')


def function_anchor(name):
    """Build the fragment id of a function section.

    Args: name - function name (qualified for methods).
    Returns: fragment text.
    """
    # Prefix keeps ids valid and distinct from other anchors.
    return 'fn-' + name


def source_anchor(path):
    """Build the fragment id of a source file section on the sources page.

    Args: path - repository-relative path.
    Returns: fragment text.
    """
    # Slashes and dots are legal in ids but awkward in URLs.
    return 'src-' + path.replace('/', '-').replace('.', '-')


def script_link(path, prefix, text=None, anchor=''):
    """Render a link to a script page.

    Args: path - script path; prefix - relative prefix; text - label (default
          the path); anchor - optional fragment.
    Returns: Raw HTML link.
    """
    # The label defaults to the repository path.
    return link(script_href(path, prefix, anchor), text or path)


def source_link(path, prefix):
    """Render a link to a source file section.

    Args: path - source path; prefix - relative prefix ('' or '../').
    Returns: Raw HTML link.
    """
    return link('%s%s#%s' % (prefix, SOURCES_PAGE, source_anchor(path)), path)


def script_links(paths, prefix):
    """Render a comma-separated list of script links.

    Args: paths - list of script paths; prefix - relative prefix.
    Returns: Raw HTML ('' for an empty list).
    """
    # Links are separated by a comma and a blank.
    parts = []
    for position, path in enumerate(paths):
        parts.append(', ' if position else '')
        # The link follows its separator.
        parts.append(script_link(path, prefix))
    return join_html(parts)
