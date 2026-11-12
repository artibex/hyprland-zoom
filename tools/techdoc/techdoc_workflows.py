"""Summary of the GitHub Actions workflows (`.github/workflows/*.yml`) for the documentation.

The files are read with the YAML-subset parser of techdoc; nothing is executed.  The
summary lists what triggers a workflow and what each job needs, runs on and uses.
"""
import re

from techdoc_yaml import parse_yaml

# Workflow files live in this directory of the repository.
WORKFLOW_PATH_PATTERN = re.compile(r'^\.github/workflows/[^/]+\.ya?ml$')
# Marker of a `uses:` step; the action reference stands after it.
ACTION_REFERENCE_PATTERN = re.compile(r'^[\w.\-]+/[\w.\-/]+@[\w.\-]+$')


def as_text_list(value):
    """Normalise a scalar, list or mapping to a list of strings.

    Args: value - parsed YAML value (str, list, dict or None).
    Returns: list of strings (mapping keys for a dict, [] for None).
    """
    # None and empty values give an empty list.
    if value is None or value == '':
        return []
    # A mapping contributes its keys.
    if isinstance(value, dict):
        return [str(key) for key in value]
    if isinstance(value, list):
        return [str(item) for item in value]
    # A plain scalar becomes a one-element list.
    return [str(value)]


def describe_trigger(name, options):
    """Render one trigger of the `on:` block as short text.

    Args: name - event name such as 'push'; options - its mapping or None.
    Returns: text like 'push (branches: main, beta; tags: v*)'.
    """
    # Filters (branches, tags, paths) are listed in reading order.
    if not isinstance(options, dict) or not options:
        return name
    filters = ['%s: %s' % (key, ', '.join(as_text_list(value)))
               for key, value in options.items()]
    return '%s (%s)' % (name, '; '.join(filters))


def parse_triggers(value):
    """Turn the `on:` block into a list of readable triggers.

    Args: value - parsed `on:` value (str, list or mapping).
    Returns: list of strings, one per event.
    """
    # The short forms `on: push` and `on: [push, pull_request]` carry no filters.
    if not isinstance(value, dict):
        return as_text_list(value)
    return [describe_trigger(name, options) for name, options in value.items()]


def describe_permissions(value):
    """Render a `permissions:` block as `name: level` pairs.

    Args: value - parsed value (mapping or a scalar such as read-all).
    Returns: text; '' when no permissions are declared.
    """
    # A mapping lists every scope; a scalar is shown as it is.
    if isinstance(value, dict):
        return ', '.join('%s: %s' % (scope, level) for scope, level in value.items())
    return str(value or '')


def describe_container(value):
    """Render the `container:` of a job.

    Args: value - parsed value (image string or mapping with `image`).
    Returns: image name, '' when the job runs directly on the runner.
    """
    # A mapping form carries the image under its own key.
    if isinstance(value, dict):
        return str(value.get('image') or '')
    return str(value or '')


def summarize_job(job_id, job):
    """Summarise one job of a workflow.

    Args: job_id - key of the job; job - parsed mapping.
    Returns: dict (id, name, runs_on, container, needs, timeout, permissions, steps,
             actions, condition).
    """
    job = job if isinstance(job, dict) else {}
    steps = [step for step in job.get('steps') or [] if isinstance(step, dict)]
    # Third-party and first-party actions used by the steps, without duplicates.
    actions = sorted({str(step['uses']) for step in steps
                      if ACTION_REFERENCE_PATTERN.match(str(step.get('uses', '')))})
    return {
        'id': job_id,
        'name': str(job.get('name') or job_id),
        'runs_on': ', '.join(as_text_list(job.get('runs-on'))),
        'container': describe_container(job.get('container')),
        'needs': as_text_list(job.get('needs')),
        'timeout': str(job.get('timeout-minutes') or ''),
        'permissions': describe_permissions(job.get('permissions')),
        'steps': len(steps),
        'actions': actions,
        'condition': str(job.get('if') or ''),
    }


def parse_workflow(path, text):
    """Summarise one workflow file.

    Args: path - repository-relative path; text - file content.
    Returns: dict (path, name, triggers, permissions, concurrency, jobs).
    """
    document = parse_yaml(text)
    document = document if isinstance(document, dict) else {}
    # The two optional blocks are read once.
    jobs = document.get('jobs')
    concurrency = document.get('concurrency')
    return {
        'path': path,
        'name': str(document.get('name') or path),
        'triggers': parse_triggers(document.get('on')),
        'permissions': describe_permissions(document.get('permissions')),
        'concurrency': (str(concurrency.get('group', '')) if isinstance(concurrency, dict)
                        else str(concurrency or '')),
        'jobs': [summarize_job(job_id, job) for job_id, job in (jobs or {}).items()]
        if isinstance(jobs, dict) else [],
    }
