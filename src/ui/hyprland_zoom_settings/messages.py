"""Turn raw ``zoomctl`` output into sentences a user can act on.

zoomctl speaks to people on a terminal: its messages carry a ``zoomctl:`` prefix, key names
and file paths. A toast must be short and plain, so known messages are mapped to fixed
sentences, unknown ones are cleaned up, and the raw text is kept as optional details.
"""

# dataclasses carry the result, re finds the known patterns, typing documents the table.
import re
from dataclasses import dataclass
from typing import Tuple

# The program prefix every zoomctl message starts with.
_PREFIX = "zoomctl: "
# Longest message shown as it is; longer ones are replaced by a generic sentence.
MAX_PLAIN_LENGTH = 90
# Any absolute path in a message makes it too technical for a toast.
_PATH = re.compile(r"(?:^|\s)/\S+/\S+")

# (pattern, plain sentence); the first matching pattern wins, an empty sentence means the
# message is only logged (it is bookkeeping, not news).
_KNOWN_MESSAGES: Tuple[Tuple["re.Pattern[str]", str], ...] = (
    (re.compile(r"backup of .+ saved as"), ""),
    (re.compile(r"engine not reachable|saved only", re.I),
     "Saved. Hyprland is not reachable, so the change applies once it is running."),
    (re.compile(r"saved, but the engine rejected the reload"),
     "Saved, but Hyprland could not apply the change."),
    (re.compile(r"rejected the live preview"), "The preview could not be started."),
    (re.compile(r"ZOOM_MIN .*ZOOM_RESET .*ZOOM_MAX|must hold"),
     "Minimum zoom can't be above Reset zoom, and Reset zoom can't be above Maximum zoom."),
    (re.compile(r"unknown (key|command)"),
     "This version of zoomctl does not know that setting."),
    (re.compile(r"timed out"), "zoomctl took too long to answer."),
    (re.compile(r"could not run", re.I),
     "zoomctl could not be started. Is hyprland-zoom installed?"),
    (re.compile(r"engine (is )?not (loaded|set up|running)|no engine", re.I),
     "The zoom engine is not loaded in Hyprland."),
)


@dataclass(frozen=True)
class Notice:
    """A message for the user.

    Attributes:
        summary: Plain sentence for a toast; empty when the message is only to be logged.
        details: The original zoomctl text, shown on request; empty when it adds nothing.
    """

    summary: str
    details: str = ""


def strip_prefix(raw: str) -> str:
    """Remove the ``zoomctl:`` prefix and surrounding blanks.

    Args:
        raw: One line of zoomctl output.

    Returns:
        The message text without the program prefix.
    """
    # Only a leading prefix is removed; the same words inside a sentence stay.
    text = raw.strip()
    return text[len(_PREFIX):].strip() if text.startswith(_PREFIX) else text


def friendly_notice(raw: str) -> Notice:
    """Map a raw zoomctl message to a plain-language notice.

    Args:
        raw: The first line of zoomctl's output or a client failure text.

    Returns:
        The notice; ``details`` holds the raw text whenever the summary differs from it.
    """
    text = strip_prefix(raw)
    for pattern, sentence in _KNOWN_MESSAGES:
        # The first known pattern decides; its sentence replaces the technical wording.
        if pattern.search(text):
            return Notice(sentence, text)
    # Unknown but short and path-free messages are already readable, with a capital letter.
    if len(text) <= MAX_PLAIN_LENGTH and not _PATH.search(text):
        return Notice(text[:1].upper() + text[1:])
    # Anything long or path-heavy is hidden behind a generic sentence plus the details.
    return Notice("zoomctl reported a problem.", text)
