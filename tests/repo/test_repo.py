"""Repository-level checks: versions, packaging, install layout, workflows and documentation.

These tests guard the glue between the packages of hyprland-zoom: the one version number that
lives in six places, the PKGBUILD against its .SRCINFO, the files `make install` puts in a
package, the GitHub workflows and the handwritten documentation against the code. They need
only bash, make and the python standard library; nothing touches the user's real config.

Run: `python3 -m unittest discover -s tests/repo -p 'test_*.py'` from the repository root.
"""
# Standard library: paths, patterns, files, processes and the test framework.
import os
import re
import shutil
import subprocess
# Scratch directories and the interpreter path for the techdoc import.
import sys
import tempfile
import unittest

# The repository root is two levels above this file (tests/repo/).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The techdoc parsers are reused so that tests and documentation read files the same way.
sys.path.insert(0, os.path.join(REPO_ROOT, 'tools', 'techdoc'))

import techdoc_help  # noqa: E402
import techdoc_settings  # noqa: E402
import techdoc_workflows  # noqa: E402

# Where the workflows and the markdown documents live.
WORKFLOW_DIRECTORY = os.path.join(REPO_ROOT, '.github', 'workflows')
# Link target of the first README line (the user's rule for every repository).
PAGES_URL = 'https://artibex.github.io/hyprland-zoom/'
# An action reference pinned to a major version, as the workflows must use them.
PINNED_ACTION_PATTERN = re.compile(r'^[\w.\-]+/[\w.\-/]+@v\d+$')
# Branches that publish the documentation on GitHub Pages.
PAGES_BRANCHES = ('refs/heads/main', 'refs/heads/beta')


def read_path(path):
    """Read any file as UTF-8 text and close it again.

    Args: path - absolute file path.
    Returns: the file content.
    """
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def read_text(*parts):
    """Read a repository file as text.

    Args: parts - path components below the repository root.
    Returns: the file content.
    """
    return read_path(os.path.join(REPO_ROOT, *parts))


def first_match(pattern, text):
    """Find the first group of a regular expression in a text.

    Args: pattern - regex with one group; text - text to search.
    Returns: the captured string, or None when there is no match.
    """
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else None


def clean_environment(home):
    """Build a minimal environment that cannot reach the user's real configuration.

    Args: home - temporary directory used as HOME and as the parent of all state.
    Returns: dict of environment variables for subprocesses.
    """
    # Every path the tool might write to points into the temporary directory.
    return {
        'PATH': '/usr/bin:/bin', 'HOME': home, 'XDG_CONFIG_HOME': os.path.join(home, 'config'),
        'XDG_RUNTIME_DIR': os.path.join(home, 'run'),
        'ZOOMCTL_STATE_DIR': os.path.join(home, 'state'),
        'ZOOMCTL_USER_CONFIG': os.path.join(home, 'user.conf'),
        'ZOOMCTL_SYSTEM_CONFIG': os.path.join(home, 'system.conf'),
    }


class VersionTests(unittest.TestCase):
    """The version number must be identical everywhere it is written down."""

    def setUp(self):
        """Read the single source of the version.

        Args: none.
        Returns: nothing.
        """
        self.version = read_text('VERSION').strip()

    def test_version_file_is_a_semantic_version(self):
        """VERSION holds exactly one MAJOR.MINOR.PATCH number."""
        self.assertRegex(self.version, r'^\d+\.\d+\.\d+$')

    def test_packaging_files_carry_the_version(self):
        """PKGBUILD and .SRCINFO announce the same pkgver."""
        self.assertEqual(first_match(r'^pkgver=(\S+)$', read_text('PKGBUILD')), self.version)
        self.assertEqual(first_match(r'^\tpkgver = (\S+)$', read_text('.SRCINFO')), self.version)

    def test_code_carries_the_version(self):
        """The CLI, the engine and the plugin report the packaged version."""
        # The CLI, the engine and the plugin each spell the version in their own way.
        cli = first_match(r"^ZOOMCTL_VERSION='([^']+)'", read_text('src', 'lib', 'common.sh'))
        engine = first_match(r'^M\.VERSION = "([^"]+)"',
                             read_text('src', 'lua', 'hyprland-zoom', 'api.lua'))
        plugin = first_match(r'"artibex", "([^"]+)"', read_text('plugin', 'main.cpp'))
        self.assertEqual((cli, engine, plugin), (self.version,) * 3)

    def test_changelog_has_an_entry_for_the_version(self):
        """CHANGELOG.md has a section for the packaged version."""
        self.assertIn('## [%s]' % self.version, read_text('CHANGELOG.md'))


class SrcinfoTests(unittest.TestCase):
    """.SRCINFO must describe the PKGBUILD (CI compares it with makepkg's own output)."""

    SCALARS = ('pkgname', 'pkgver', 'pkgrel', 'pkgdesc', 'url', 'install')
    ARRAYS = ('arch', 'license', 'depends', 'checkdepends', 'optdepends', 'backup')

    def pkgbuild_fields(self):
        """Evaluate the PKGBUILD in bash and print its fields.

        Args: none.
        Returns: list of (field, value) pairs, arrays expanded in order.
        """
        # Sourcing is how makepkg itself reads the file; the script prints every field.
        script = 'source ./PKGBUILD\n'
        # One printf line per scalar and per array element of the PKGBUILD.
        for name in self.SCALARS:
            script += 'printf "%s\\t%s\\n" ' + name + ' "$' + name + '"\n'
        for name in self.ARRAYS:
            script += ('for item in "${' + name + '[@]}"; do '
                       'printf "%s\\t%s\\n" ' + name + ' "$item"; done\n')
        # bash evaluates the file exactly like makepkg does.
        result = subprocess.run(['bash', '-c', script], cwd=REPO_ROOT, capture_output=True,
                                text=True, check=True, env={'PATH': '/usr/bin:/bin'})
        return [tuple(line.split('\t', 1)) for line in result.stdout.splitlines()]

    def srcinfo_fields(self):
        """Read the fields of the first (pkgbase) section of .SRCINFO.

        Args: none.
        Returns: list of (field, value) pairs in file order.
        """
        fields = []
        for line in read_text('.SRCINFO').split('\n'):
            # Tab-indented `key = value` lines belong to the pkgbase section.
            match = re.match(r'^\t(\w+) = (.*)$', line)
            # Indented lines of the pkgbase section are the fields; the first pkgname ends it.
            if match:
                fields.append((match.group(1), match.group(2)))
            elif line.startswith('pkgname'):
                break
        # The scan stops at the first section header.
        return fields

    def test_srcinfo_lists_every_pkgbuild_field(self):
        """Every scalar and array element of the PKGBUILD appears in .SRCINFO."""
        srcinfo = self.srcinfo_fields()
        for field, value in self.pkgbuild_fields():
            # pkgname lives in its own section of .SRCINFO.
            if field == 'pkgname':
                self.assertIn('pkgname = %s' % value, read_text('.SRCINFO'))
            else:
                self.assertIn((field, value), srcinfo, '%s = %s' % (field, value))

    def test_srcinfo_has_no_stale_dependencies(self):
        """.SRCINFO lists exactly as many dependencies as the PKGBUILD."""
        # Compare the multisets: order of dependencies is irrelevant.
        for field in ('depends', 'checkdepends', 'optdepends', 'backup'):
            declared = [value for name, value in self.pkgbuild_fields() if name == field]
            listed = [value for name, value in self.srcinfo_fields() if name == field]
            self.assertEqual(sorted(listed), sorted(declared), field)


class InstallLayoutTests(unittest.TestCase):
    """`make install` puts every runtime file in place, and the installed tool works."""

    PREFIX = 'usr'

    @classmethod
    def setUpClass(cls):
        """Install into a staging directory once for all tests of this class.

        Args: none.
        Returns: nothing.
        """
        # A scratch directory keeps the staging tree out of the repository.
        cls.stage = tempfile.mkdtemp(prefix='hzoom-stage-')
        subprocess.run(['make', 'install', 'DESTDIR=' + cls.stage, 'PREFIX=/usr'],
                       cwd=REPO_ROOT, check=True, capture_output=True)
        cls.share = os.path.join(cls.stage, 'usr', 'share', 'hyprland-zoom')

    @classmethod
    def tearDownClass(cls):
        """Remove the staging directory.

        Args: none.
        Returns: nothing.
        """
        shutil.rmtree(cls.stage, ignore_errors=True)

    def installed_files(self):
        """List every installed file relative to the staging root.

        Args: none.
        Returns: sorted list of paths such as 'usr/bin/zoomctl'.
        """
        # Walk the whole staging tree and report paths relative to its root.
        found = []
        for base, _directories, files in os.walk(self.stage):
            found.extend(os.path.relpath(os.path.join(base, name), self.stage) for name in files)
        return sorted(found)

    def expected_files(self):
        """Compute the layout table of docs/architecture.md from the source tree.

        Args: none.
        Returns: sorted list of paths that the package must contain.
        """
        share = 'usr/share/hyprland-zoom/'
        expected = ['usr/bin/zoomctl', 'usr/bin/hyprland-zoom-settings', 'etc/zoomctl.conf',
                    share + 'settings.schema', share + 'hyprland-zoom.lua', share + 'VERSION',
                    share + 'hyprland-bindings.lua', share + 'hyprland-bindings.conf',
                    'usr/share/licenses/hyprland-zoom/LICENSE',
                    'usr/share/applications/io.github.artibex.HyprlandZoom.desktop',
                    'usr/share/doc/hyprland-zoom/README.md',
                    'usr/share/doc/hyprland-zoom/CHANGELOG.md']
        # Whole directories are installed by glob; new files need no Makefile edit.
        groups = (('src/lib', '.sh', share + 'lib/'), ('src/shaders', '.glsl', share + 'shaders/'),
                  ('src/lua/hyprland-zoom', '.lua', share + 'lua/hyprland-zoom/'),
                  ('src/ui/hyprland_zoom_settings', '.py', share + 'ui/hyprland_zoom_settings/'),
                  ('docs', '.md', 'usr/share/doc/hyprland-zoom/'))
        for source, suffix, target in groups:
            expected.extend(target + name for name in os.listdir(os.path.join(REPO_ROOT, source))
                            if name.endswith(suffix))
        return sorted(expected + self.icon_paths())

    def icon_paths(self):
        """List the icon files that must be installed below the hicolor theme.

        Args: none.
        Returns: list of installed paths.
        """
        # Icons keep their theme-relative path below hicolor.
        icons = []
        root = os.path.join(REPO_ROOT, 'data', 'icons', 'hicolor')
        for base, _directories, files in os.walk(root):
            for name in files:
                # Installed icon paths mirror the source tree.
                relative = os.path.relpath(os.path.join(base, name), root)
                icons.append('usr/share/icons/hicolor/' + relative)
        return icons

    def test_every_runtime_file_is_installed_and_nothing_else(self):
        """The package contains exactly the files of the layout table."""
        self.assertEqual(self.installed_files(), self.expected_files())

    def test_no_python_bytecode_is_installed(self):
        """Only source files are shipped, no __pycache__."""
        self.assertFalse([path for path in self.installed_files() if '__pycache__' in path])

    def test_executables_and_data_have_the_right_modes(self):
        """The two commands are executable, every other file is plain data."""
        # Only the two commands carry the executable bit.
        executables = {'usr/bin/zoomctl', 'usr/bin/hyprland-zoom-settings'}
        for path in self.installed_files():
            mode = os.stat(os.path.join(self.stage, path)).st_mode & 0o777
            self.assertEqual(mode, 0o755 if path in executables else 0o644, path)

    def test_system_config_is_the_shipped_default_file(self):
        """/etc/zoomctl.conf is config/defaults.conf (listed in backup=)."""
        installed = read_path(os.path.join(self.stage, 'etc', 'zoomctl.conf'))
        self.assertEqual(read_text('config', 'defaults.conf'), installed)

    def run_installed(self, arguments):
        """Run the installed zoomctl with a scratch environment.

        Args: arguments - zoomctl arguments.
        Returns: CompletedProcess with text output.
        """
        # A scratch HOME keeps the run away from the real configuration.
        with tempfile.TemporaryDirectory(prefix='hzoom-home-') as home:
            environment = clean_environment(home)
            environment['ZOOMCTL_SHARE_DIR'] = self.share
            command = ['bash', os.path.join(self.stage, 'usr', 'bin', 'zoomctl')] + arguments
            # The staged script finds its libraries through ZOOMCTL_SHARE_DIR.
            return subprocess.run(command, capture_output=True, text=True, env=environment)

    def test_installed_help_and_version_work(self):
        """`zoomctl help` and `zoomctl version` run from the staged copy."""
        # help must succeed and print the usage line.
        helped = self.run_installed(['help'])
        self.assertEqual(helped.returncode, 0, helped.stderr)
        self.assertIn('Usage: zoomctl', helped.stdout)
        versioned = self.run_installed(['version'])
        # version prints the packaged version.
        self.assertEqual(versioned.stdout.strip(), 'zoomctl ' + read_text('VERSION').strip())

    def test_installed_config_lists_every_schema_key_in_order(self):
        """`zoomctl config --porcelain` prints one KEY=VALUE line per schema key."""
        # The porcelain output is the contract with the settings app.
        result = self.run_installed(['config', '--porcelain'])
        self.assertEqual(result.returncode, 0, result.stderr)
        keys = [line.split('=', 1)[0] for line in result.stdout.splitlines()]
        schema = techdoc_settings.load_settings(REPO_ROOT)
        # Keys must follow the schema order.
        self.assertEqual(keys, [item['key'] for item in schema])


class WorkflowTests(unittest.TestCase):
    """Structural rules for the GitHub Actions workflows."""

    def workflows(self):
        """Parse every workflow file of the repository.

        Args: none.
        Returns: dict mapping the file name to (summary dict, raw text).
        """
        # Collect (summary, raw text) per workflow file name.
        parsed = {}
        for name in sorted(os.listdir(WORKFLOW_DIRECTORY)):
            text = read_text('.github', 'workflows', name)
            parsed[name] = (techdoc_workflows.parse_workflow('.github/workflows/' + name, text),
                            text)
        # The summaries are returned together.
        return parsed

    def test_the_three_workflows_exist(self):
        """CI, documentation and release workflows are present."""
        self.assertEqual(sorted(self.workflows()), ['ci.yml', 'docs.yml', 'release.yml'])

    def test_permissions_are_declared_and_minimal(self):
        """Every workflow limits the token; only named jobs may write."""
        for name, (workflow, _text) in self.workflows().items():
            self.assertEqual(workflow['permissions'], 'contents: read', name)
            for job in workflow['jobs']:
                # A job-level override is allowed only for publishing jobs.
                if job['permissions']:
                    self.assertIn(job['id'], ('deploy', 'release'), '%s/%s' % (name, job['id']))

    def test_every_job_has_a_timeout_and_a_known_dependency(self):
        """No job can hang forever and `needs` names existing jobs."""
        # Every job needs a timeout, and its dependencies must exist.
        for name, (workflow, _text) in self.workflows().items():
            job_ids = {job['id'] for job in workflow['jobs']}
            for job in workflow['jobs']:
                self.assertTrue(job['timeout'], '%s/%s has no timeout' % (name, job['id']))
                # Unknown dependencies would make the workflow invalid.
                self.assertLessEqual(set(job['needs']), job_ids, '%s/%s' % (name, job['id']))

    def test_every_action_is_pinned_to_a_major_version(self):
        """`uses:` references look like owner/name@vN."""
        for name, (_workflow, text) in self.workflows().items():
            for reference in re.findall(r'^\s*(?:-\s+)?uses:\s*(\S+)\s*$', text, re.MULTILINE):
                self.assertRegex(reference, PINNED_ACTION_PATTERN, '%s: %s' % (name, reference))

    def test_ci_runs_on_push_and_pull_request_with_concurrency(self):
        """CI covers pushes and pull requests and cancels superseded runs."""
        # CI covers pushes and pull requests and cancels superseded runs.
        workflow, text = self.workflows()['ci.yml']
        self.assertEqual(workflow['triggers'], ['push', 'pull_request'])
        self.assertIn('cancel-in-progress: true', text)
        self.assertEqual([job['id'] for job in workflow['jobs']],
                         ['static', 'tests', 'gui', 'package', 'plugin'])

    def test_arch_jobs_use_the_archlinux_container(self):
        """The jobs that need the target stack run in an Arch container."""
        # Jobs that need the target stack run in Arch; the static job needs none.
        workflow, _text = self.workflows()['ci.yml']
        containers = {job['id']: job['container'] for job in workflow['jobs']}
        for job_id in ('tests', 'gui', 'package', 'plugin'):
            self.assertEqual(containers[job_id], 'archlinux:latest', job_id)
        # The static job runs directly on the runner.
        self.assertEqual(containers['static'], '')

    def test_docs_deploy_only_main_and_beta(self):
        """The Pages deployment is limited to main and beta pushes."""
        # Only main and beta may publish.
        workflow, _text = self.workflows()['docs.yml']
        deploy = [job for job in workflow['jobs'] if job['id'] == 'deploy'][0]
        for branch in PAGES_BRANCHES:
            self.assertIn(branch, deploy['condition'])
        # The deployment follows the build and needs the Pages permissions.
        self.assertEqual(deploy['needs'], ['build'])
        self.assertEqual(deploy['permissions'], 'pages: write, id-token: write')

    def test_release_runs_on_version_tags(self):
        """The release workflow starts on v* tags and publishes with contents: write."""
        # Tags start the release; only the publishing job may write contents.
        workflow, _text = self.workflows()['release.yml']
        self.assertEqual(workflow['triggers'], ['push (tags: v*)'])
        release = [job for job in workflow['jobs'] if job['id'] == 'release'][0]
        self.assertEqual((release['needs'], release['permissions']),
                         (['package'], 'contents: write'))


def markdown_anchors(text):
    """Compute the GitHub anchors of the headings of a markdown text.

    Args: text - markdown source.
    Returns: set of anchor names (lower case, punctuation dropped, blanks to hyphens).
    """
    anchors = set()
    in_code_block = False
    for line in text.split('\n'):
        # Lines inside fenced code blocks are no headings.
        if line.startswith('```'):
            # Fenced code blocks may contain # lines that are no headings.
            in_code_block = not in_code_block
        match = None if in_code_block else re.match(r'^#{1,6}\s+(.*?)\s*$', line)
        if match:
            slug = re.sub(r'[^\w\- ]', '', match.group(1).replace('`', '').lower())
            # GitHub's anchor rule: lower case, no punctuation, blanks become hyphens.
            anchors.add(slug.replace(' ', '-'))
    return anchors


class DocumentationTests(unittest.TestCase):
    """The handwritten documentation must agree with the code."""

    def documents(self):
        """List the handwritten markdown documents of the repository.

        Args: none.
        Returns: list of repository-relative paths.
        """
        names = ['README.md', 'CHANGELOG.md']
        names += ['docs/' + name for name in sorted(os.listdir(os.path.join(REPO_ROOT, 'docs')))
                  if name.endswith('.md')]
        return names

    def test_readme_starts_with_the_link_to_the_technical_documentation(self):
        """The first README line links to the generated documentation on GitHub Pages."""
        first_line = read_text('README.md').split('\n', 1)[0]
        self.assertIn('(%s)' % PAGES_URL, first_line)

    def test_relative_links_and_anchors_resolve(self):
        """Every relative markdown link points to an existing file and heading."""
        for document in self.documents():
            base = os.path.dirname(document)
            for target in re.findall(r'\]\(([^)\s]+)\)', read_text(*document.split('/'))):
                # External links and mail addresses are not checked here.
                if re.match(r'^(https?:|mailto:)', target):
                    # External links are not checked here.
                    continue
                path, _hash, fragment = target.partition('#')
                resolved = os.path.normpath(os.path.join(base, path)) if path else document
                self.assertTrue(os.path.isfile(os.path.join(REPO_ROOT, resolved)),
                                '%s -> %s' % (document, target))
                # Anchors are checked against the headings of the target document.
                if fragment and resolved.endswith('.md'):
                    self.assertIn(fragment, markdown_anchors(read_text(*resolved.split('/'))),
                                  '%s -> %s' % (document, target))

    def test_configuration_reference_is_generated_from_the_schema(self):
        """docs/configuration.md lists every schema key and is up to date."""
        # The generated block lists exactly the schema keys, in window order.
        document = read_text('docs', 'configuration.md')
        schema = techdoc_settings.load_settings(REPO_ROOT)
        listed = techdoc_settings.documented_keys(document)
        self.assertEqual(listed, [item['key'] for group in techdoc_settings.grouped_settings(
            schema) for item in group[2]])
        # The tool's own verdict: no stale generated block.
        result = subprocess.run([sys.executable, 'tools/techdoc/techdoc.py', 'settings-doc',
                                 '--check'], cwd=REPO_ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_zoomctl_command_is_documented(self):
        """Each command of `zoomctl help` appears as `zoomctl <command>` in the docs."""
        help_text = techdoc_help.parse_help_text(read_text('src', 'lib', 'cmd_info.sh'))
        documentation = ' '.join(read_text(*name.split('/')) for name in self.documents())
        for section in help_text['sections']:
            for entry in section['entries']:
                # `version, help` names two commands in one entry.
                for command in entry['term'].split(', '):
                    word = command.split(' ')[0]
                    self.assertIn('zoomctl ' + word, documentation, word)

    def test_every_tracking_mode_and_filter_is_described(self):
        """The usage guide names every enum value of ZOOM_TRACKING and FILTER."""
        # The usage guide must describe every selectable mode and filter.
        usage = read_text('docs', 'usage.md')
        for item in techdoc_settings.load_settings(REPO_ROOT):
            if item['key'] in ('ZOOM_TRACKING', 'FILTER'):
                # Enum options appear in code font, as in the tables.
                for value in item['constraint'].split(','):
                    self.assertIn('`%s`' % value, usage, '%s=%s' % (item['key'], value))

    def test_documented_environment_variables_exist_in_the_code(self):
        """Every ZOOMCTL_* variable of the configuration reference is read by the code."""
        # Environment variables of the reference must be read by the code.
        document = read_text('docs', 'configuration.md')
        code = ''.join(read_text('src', 'lib', name) for name in os.listdir(
            os.path.join(REPO_ROOT, 'src', 'lib')))
        for variable in sorted(set(re.findall(r'\| `(ZOOMCTL_[A-Z_]+)` \|', document))):
            self.assertIn(variable, code, variable)

    def test_build_outputs_are_ignored_by_git(self):
        """The generated site and the makepkg output never show up as changes."""
        # Build outputs must never show up as changes.
        ignored = read_text('.gitignore').split('\n')
        for pattern in ('/public/', '/pkg/', '*.pkg.tar.*'):
            self.assertIn(pattern, ignored)


if __name__ == '__main__':
    # The test module runs standalone as well.
    unittest.main()
