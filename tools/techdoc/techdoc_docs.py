"""Link list to the handwritten documentation in docs/*.md.

The generated site does not copy the markdown files; it links to them: to the
GitHub file view when the Actions variables of the repository are known, otherwise
to the relative repository path.
"""
import re

from techdoc_repo import read_text

# Handwritten documents: markdown files directly in docs/.
DOCS_PATTERN = re.compile(r'^docs/[^/]+\.md$')
# First markdown heading, used as link text.
TITLE_PATTERN = re.compile(r'^#\s+(.+)$', re.MULTILINE)
# Actions variables that identify the repository page and the documented ref.
SERVER_URL_VARIABLE = 'GITHUB_SERVER_URL'
REPOSITORY_VARIABLE = 'GITHUB_REPOSITORY'
REF_VARIABLE = 'GITHUB_REF_NAME'
# Reading order of the documents: users first, then contributors; the rest follows.
DOCUMENT_ORDER = (
    'docs/usage.md', 'docs/configuration.md', 'docs/troubleshooting.md', 'docs/plugin.md',
    'docs/packaging.md', 'docs/architecture.md', 'docs/roadmap.md',
)


def docs_href(path, environment):
    """Build the link target of one handwritten document.

    Args: path - repository-relative path such as 'docs/usage.md';
          environment - mapping of environment variables (os.environ).
    Returns: GitHub blob URL when server, repository and ref are set, else the
             relative repository path.
    """
    server = environment.get(SERVER_URL_VARIABLE, '').rstrip('/')
    repository = environment.get(REPOSITORY_VARIABLE, '')
    ref_name = environment.get(REF_VARIABLE, '')
    # All three variables are needed for a working link into the GitHub file view.
    if server and repository and ref_name:
        return '%s/%s/blob/%s/%s' % (server, repository, ref_name, path)
    return path


def document_sort_key(path):
    """Order documents: the reading order first, then alphabetically.

    Args: path - repository-relative path.
    Returns: sortable key.
    """
    # Unknown documents sort behind the known ones, by name.
    known = DOCUMENT_ORDER.index(path) if path in DOCUMENT_ORDER else len(DOCUMENT_ORDER)
    return (known, path)


def build_docs(root, paths, environment):
    """List the handwritten documents that exist at build time.

    Args: root - repository root; paths - tracked relative paths;
          environment - mapping of environment variables.
    Returns: list of dicts (path, title, href) in display order.
    """
    documents = []
    for path in sorted((p for p in paths if DOCS_PATTERN.match(p)), key=document_sort_key):
        # A document without heading is listed under its file name.
        match = TITLE_PATTERN.search(read_text(root, path))
        documents.append({'path': path, 'title': match.group(1).strip() if match else path,
                          'href': docs_href(path, environment)})
    return documents
