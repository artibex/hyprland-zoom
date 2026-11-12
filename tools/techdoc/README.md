# techdoc — code-quality gate and generated technical documentation

`techdoc.py` is the repository's own tool for three jobs. It needs Python ≥ 3.8 and the
standard library only: no third-party packages, no network, no AI, and it **never runs
scripts of the repository**, it only reads them.

| Job | Call | Result |
|---|---|---|
| **Gate** — rules R1–R8 | `techdoc.py check` | lines `path:line: Rn message`, final line `TOTAL n violation(s)`, exit code 0 / 1 / 2 |
| **Documentation** — static HTML site + model | `techdoc.py build --out DIR` | `DIR/index.html`, more pages, `DIR/techdoc.json` |
| **Settings tables** — `docs/configuration.md` | `techdoc.py settings-doc [--check]` | refreshes (or verifies) the generated tables from `config/settings.schema` |

## Origin and changes

Vendored from `hio-fake-hotfixes`, folder `tools/techdoc`, commit
`47d24e2e22e01197602131f31f441bf2ca639fee` (itself a copy of `hisinone-docker`,
branch `beta`, commit `42ad2249c2cbeae00b750f6612c9e8aa7a8eab5e`). Changes for
hyprland-zoom:

- All texts are English; the site targets GitHub Pages and GitHub Actions
  (`GITHUB_SHA`, `GITHUB_REF_NAME`, `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`) instead of GitLab.
- Removed: `.env.example`, Compose, Dockerfile, `.gitlab-ci.yml`, Java and TypeScript
  support (`techdoc_config.py`, the old `techdoc_sources.py`).
- New `techdoc_lua.py`: **R8**, the Lua function-header gate (`-- name — purpose`, `Args:`,
  `Returns:`, optional `Notes:`), and the Lua contract parser.
- New `techdoc_sources.py`: `sources.html` documents the Lua engine (`src/lua/**`, contracts
  from the headers) and the C++ plugin (`plugin/*.cpp|hpp`, declarations with a `///`
  comment).
- New `techdoc_settings.py`: `settings.html` and the key tables of `docs/configuration.md`
  come from `config/settings.schema`, the single source of keys.
- New `techdoc_workflows.py`: `ci.html` summarises `.github/workflows/*.yml`.
- `techdoc_help.py` reads help texts with arbitrary section titles and hand-aligned
  columns, so `cli.html` is parsed statically from `zoomctl help`
  (`src/lib/cmd_info.sh`).
- `techdoc_pages.py` is split into `techdoc_pages.py` (index, scripts, quality),
  `techdoc_pages_reference.py` (settings, CLI, CI, sources) and `techdoc_links.py`.

## Local use

```bash
# Gate over all tracked shell, python and Lua files (root = git top level)
python3 tools/techdoc/techdoc.py check

# Gate over single files (paths relative to the root)
python3 tools/techdoc/techdoc.py check src/zoomctl

# Build the documentation OUTSIDE the repository tree (or into the ignored public/)
python3 tools/techdoc/techdoc.py build --out /tmp/hzoom-site
xdg-open /tmp/hzoom-site/index.html      # works offline (file://)

# Refresh / verify the generated tables of docs/configuration.md
python3 tools/techdoc/techdoc.py settings-doc
python3 tools/techdoc/techdoc.py settings-doc --check

# Unit tests of the tool itself
cd tools/techdoc && python3 -m unittest -v
```

`make qa`, `make docs` and `make test` wrap these calls.

Exit codes of `check`: `0` clean, `1` violations, `2` usage or environment error (for
example no git repository). `build` never fails on rule violations, only on internal
errors; the violations are listed on `quality.html`.

## The rules R1–R8

A **production file** is every tracked shell script (`*.sh` or an `sh`/`bash` shebang, for
example a hook without extension), every `*.py` and every `*.lua` whose name does not start
with `test-`/`test_` and that does not live under `/fixtures/`. Test suites only get R1
(shell) and R6 (python). Lua below `tests/` (test doubles with dozens of one-line fake
methods) is outside the Lua gate.

| Rule | Applies to | Content |
|---|---|---|
| **R1** function header | all shell files (tests too) | the comment block directly above `name() {` holds purpose, `Args:`, `Returns:`, `Globals:` (optional `Notes:`) |
| **R2** line length | production shell, python and Lua | at most 100 characters per line, heredoc lines included |
| **R3** function length | production shell | function body at most 100 lines (heredoc lines do not count) |
| **R4** comment density | production shell | never more than 3 consecutive statements without a comment |
| **R5** thin dispatcher | production shell | an arm of a column-0 `case` has at most 10 statement lines |
| **R6** docstrings | all python files | module docstring and a docstring for every `def`/`class` |
| **R7** comment blocks | production shell | free comment blocks at most 2 lines; a function header holds only the contract fields |
| **R8** Lua header | production Lua | every named `function`/`local function` has `-- name — purpose` plus `-- Args:` and `-- Returns:` above it |

R1–R7 are a 1:1 port of the frozen reference implementation
(`fixtures/reference_precheck.py`); `check` gives the same verdicts and output format. The
parity test in `test_techdoc.py` compares both on fixtures (including random mutations)
and on every shell and python file of this repository. R4 for Python is not part of
techdoc: `tools/qa/comment-runs.py` checks it (`make qa`).

Shell header example:

```bash
# greet — print a greeting for a name.
# Args:    $1 name (optional, default world)
# Returns: 0 always; stdout: the greeting
# Globals: none
greet() {
```

Lua header example:

```lua
-- trim — strip whitespace from both ends of a string.
-- Args:    text string
-- Returns: the trimmed string
-- Notes:   optional, one line: a trap or the reason
local function trim(text)
```

## The generated site

`build` writes a static site without CDN and without JavaScript (one inline stylesheet),
deterministic: sorted, no wall clock, the header shows `GITHUB_SHA` / `GITHUB_REF_NAME`
(else `git rev-parse`).

| Page | Content |
|---|---|
| `index.html` | link list to `docs/*.md`, components (one per directory), script table: path, purpose from the file header, lines, functions, header coverage |
| `settings.html` | every key of `config/settings.schema`: type, default, allowed values, CLI name, meaning |
| `cli.html` | commands of `zoomctl`, parsed statically from the help text |
| `sources.html` | Lua engine functions with their contracts, C++ plugin declarations |
| `ci.html` | GitHub Actions workflows: triggers, jobs, runner, container, needs, actions |
| `quality.html` | gate verdict per rule and file, metrics |
| `scripts/<path>.html` | per shell/python script: file header, functions with contract fields, calls / called by, metrics, violations |
| `techdoc.json` | the complete model all pages are rendered from |

Pages without input are omitted (no schema, no workflows, ...), together with their
navigation entry.

Limits: help text is recognised as a run of `echo "…"` lines or a here-document with a
`Usage:` line and at least one section title (`Commands:`, `Zoom:`, …). Entries are
`  term  description` with two blanks, or hand-aligned in one column; lines indented
deeper continue the previous description. Calls between shell functions are recognised by
name in command position inside the same file.

## Extending

1. New rule: add a function to `techdoc_rules.py` (or a language module such as
   `techdoc_lua.py`), call it from `check_file`, add positive and negative fixture tests
   to `test_techdoc.py`. If it deviates from the reference, adjust the parity test on
   purpose and document it here.
2. New page: put the data into `techdoc_model.py`, render it in `techdoc_pages_reference.py`
   and register it in `site_pages()` and in `NAVIGATION` (`techdoc_html.py`).
3. The tool's own files obey the same rules (docstrings, ≤ 100 columns, small functions,
   comments for every statement group).
