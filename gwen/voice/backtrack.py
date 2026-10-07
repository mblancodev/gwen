"""Mid-utterance backtrack cues: drop the false start, keep what follows.

Local rules only (no model). Phrases like "scratch that" / "actually" / "wait"
restart the take from the words after the cue.
"""
from __future__ import annotations

import re

# Longer / clearer cues first. Last match in the utterance wins (latest restart).
_CUES = [
    ("scratch that", True),
    ("never\\s*mind", True),
    ("forget that", True),
    ("ignore that", True),
    ("start over", True),
    ("no,?\\s+wait", True),
    # Bare "wait" as a restart — not "wait for / until / a / the / to / on / up"
    ("wait(?!\\s+(?:for|until|a|an|the|to|on|up)\\b)", False),
    ("actually", False),
]

_CUE_RE = re.compile(
    r"(?:^|[\s,;:—–-]+)(" + "|".join("(?:%s)" % c for c, _ in _CUES) + r")\b[,.]?\s*",
    re.IGNORECASE,
)

# Map matched text → whether it may restart at utterance start (no false start before it).
_STRONG_START = re.compile(
    r"^(?:scratch that|never\s*mind|forget that|ignore that|start over|no,?\s+wait)$",
    re.I,
)


def backtrack(text: str) -> str:
    """If a restart cue appears, return only the text after the last cue; else unchanged."""
    if not text or not text.strip():
        return text
    last = None
    for m in _CUE_RE.finditer(text):
        last = m
    if last is None:
        return text
    before = text[: last.start(1)].strip(" \t,;:—–-")
    after = text[last.end() :].strip(" \t")
    cue = last.group(1)
    if not after:
        return text
    # Mid-utterance: always take the restart.
    if before:
        return _cap(after)
    # Utterance-leading cue: only strong phrases drop (not discourse "Actually…").
    if _STRONG_START.match(cue.strip()):
        return _cap(after)
    return text


def _cap(s: str) -> str:
    i = 0
    while i < len(s) and s[i] in "¿¡\"'«“(":
        i += 1
    if i >= len(s):
        return s
    return s[:i] + s[i].upper() + s[i + 1 :]


CASES = [
    ("go left scratch that go right", "Go right"),
    ("send it to Jane never mind send it to Alex", "Send it to Alex"),
    ("meet at noon actually meet at three", "Meet at three"),
    ("delete the file wait keep the file", "Keep the file"),
    ("no wait ship tomorrow", "Ship tomorrow"),
    ("forget that the tests passed", "The tests passed"),
    ("ignore that call her back", "Call her back"),
    ("start over hello world", "Hello world"),
    ("please wait for me", "please wait for me"),  # not a restart
    ("Actually I agree", "Actually I agree"),  # discourse — keep
    ("just hello", "just hello"),
    ("one scratch that two scratch that three", "Three"),
]
