# tools/qa

`comment-runs.py` finds runs of more than three uncommented statements in Python and
JavaScript files (the Python/JS half of rule R4; `techdoc.py check` covers shell).

Origin: the coding-standards skill (`scripts/comment-runs.py`), also used by the sibling
repository hyprland-tts. Local change: three intent comments so that the checker passes its
own rule. Run it through `make qa`; it only knows `*.py` and `*.js`, so `make qa` copies
extensionless python scripts to a temporary `.py` first.
