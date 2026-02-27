"""
Voice command post-processing for transcribed text.

Replaces spoken formatting commands (e.g. "new line", "period", "comma")
with their corresponding characters. Applied after transcription, before
paste or save. Each command can be individually enabled or disabled.
"""

from __future__ import annotations

import logging
import re
from typing import Dict

logger = logging.getLogger(__name__)

# All available voice commands: (spoken phrase, replacement character).
# Ordered longest-first to avoid partial matches
# (e.g. "new paragraph" must be matched before "new").
ALL_COMMANDS: list[tuple[str, str]] = [
    ("new paragraph", "\n\n"),
    ("new line", "\n"),
    ("exclamation point", "!"),
    ("exclamation mark", "!"),
    ("question mark", "?"),
    ("open parenthesis", "("),
    ("close parenthesis", ")"),
    ("open quote", '"'),
    ("close quote", '"'),
    ("semicolon", ";"),
    ("period", "."),
    ("comma", ","),
    ("colon", ":"),
]

# Display-friendly names for the replacement characters.
REPLACEMENT_DISPLAY: dict[str, str] = {
    "\n\n": "\\n\\n",
    "\n": "\\n",
    "!": "!",
    "?": "?",
    "(": "(",
    ")": ")",
    '"': '"',
    ";": ";",
    ".": ".",
    ",": ",",
    ":": ":",
}

# Punctuation characters that should not have a leading space.
_PUNCT_NO_LEADING_SPACE = re.compile(r"\s+([.,!?;:\)\"])")
# Opening brackets/quotes should not have a trailing space.
_PUNCT_NO_TRAILING_SPACE = re.compile(r"([\(\"])\s+")


def default_enabled() -> Dict[str, bool]:
    """Return the default enabled state for all commands (all True)."""
    return {cmd: True for cmd, _ in ALL_COMMANDS}


def apply_voice_commands(text: str, enabled: Dict[str, bool] | None = None) -> str:
    """Replace spoken voice commands with formatting characters.

    Parameters
    ----------
    text:
        Raw transcribed text that may contain spoken commands like
        "new line", "period", "comma", etc.
    enabled:
        Dict mapping command phrase to bool. Commands not in the dict
        or set to False are skipped. If None, all commands are applied.

    Returns
    -------
    str
        Text with voice commands replaced by their characters and
        whitespace cleaned up around punctuation.
    """
    if not text:
        return text

    count = 0
    result = text

    for cmd, replacement in ALL_COMMANDS:
        if enabled is not None and not enabled.get(cmd, False):
            continue
        # Also consume trailing punctuation the model adds after the command
        # (e.g. "New line." → the trailing "." is an auto-punctuation artifact).
        pattern = re.compile(
            r"\b" + re.escape(cmd) + r"\b[.,;:!?]*", re.IGNORECASE
        )
        result, n = pattern.subn(replacement, result)
        count += n

    if count > 0:
        # Clean up spaces around newlines (e.g. "Hello \n world" → "Hello\nworld").
        result = re.sub(r" *\n *", "\n", result)
        # Remove orphaned punctuation at start of lines (model artifacts).
        result = re.sub(r"\n[.,;:!?]+\s*", "\n", result)
        # Clean up whitespace around punctuation.
        result = _PUNCT_NO_LEADING_SPACE.sub(r"\1", result)
        result = _PUNCT_NO_TRAILING_SPACE.sub(r"\1", result)
        # Collapse multiple spaces into one.
        result = re.sub(r" {2,}", " ", result)
        logger.info("Voice commands: %d replacement(s) applied", count)

    return result
