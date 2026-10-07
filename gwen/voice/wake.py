"""Hey Gwen wake spotting."""
from __future__ import annotations

import re

GWEN_RE = re.compile(r"\b(?:hey|hi|ok|okay)\W+(?:gwen|gwenn|gwyn|gwynn|guen)\b\W*", re.I)


def gwen_heard(prev: str, text: str) -> bool:
    """True when a new Hey Gwen appears versus the previous partial transcript."""
    n = len(GWEN_RE.findall(text or ""))
    return n > len(GWEN_RE.findall(prev or "")) or (n > 0 and not (text or "").startswith(prev or ""))


def strip_gwen(text: str) -> str:
    """Drop a leading Hey Gwen so it is not pasted."""
    m = GWEN_RE.match((text or "").lstrip())
    return (text or "").lstrip()[m.end():].lstrip() if m else (text or "")
