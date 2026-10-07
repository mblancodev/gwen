"""Hey Gwen wake spotting."""
from __future__ import annotations

import json
import os
import re

from gwen.voice.paths import VOICE_DIR

WAKE = os.path.join(VOICE_DIR, "wake.json")  # what the recognizer writes when you say it (macapp/Wake.swift)
BUILTIN = r"(?:hey|hi|ok|okay)\W+(?:gwen|gwenn|gwyn|gwynn|guen)"
_cache: dict = {}


def learned(path=None):
    try:
        with open(path or WAKE) as f:
            phrases = json.load(f).get("phrases")
    except (OSError, ValueError, AttributeError):
        return []
    out = [re.findall(r"[\w']+", p.lower()) for p in phrases or [] if isinstance(p, str)]
    return [w for w in out if 2 <= len(w) <= 4]


def pattern(path=None):
    """Built-in spellings plus the trained ones; re-read when the file changes."""
    path = path or WAKE
    try:
        stamp = os.stat(path).st_mtime_ns
    except OSError:
        stamp = 0
    if _cache.get("key") != (path, stamp):
        alts = [BUILTIN] + [r"\W+".join(map(re.escape, w)) for w in learned(path)]
        _cache.update(key=(path, stamp), re=re.compile(r"\b(?:%s)\b\W*" % "|".join(alts), re.I))
    return _cache["re"]


def gwen_heard(prev: str, text: str, path=None) -> bool:
    """True when a new Hey Gwen appears versus the previous partial transcript."""
    n = len(pattern(path).findall(text or ""))
    return n > len(pattern(path).findall(prev or "")) or (n > 0 and not (text or "").startswith(prev or ""))


def strip_gwen(text: str, path=None) -> str:
    """Drop a leading Hey Gwen so it is not pasted."""
    m = pattern(path).match((text or "").lstrip())
    return (text or "").lstrip()[m.end():].lstrip() if m else (text or "")


if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "wake.json")
        assert gwen_heard("", "hey Gwen take a note", p) and not gwen_heard("", "hey when is lunch", p)
        with open(p, "w") as f:
            json.dump({"phrases": ["Hey when", "when", "a b c d e"]}, f)
        assert gwen_heard("", "hey when is lunch", p) and not gwen_heard("hey when", "hey when is", p)
        assert not gwen_heard("", "when is lunch", p)  # one word is never a wake phrase
        assert strip_gwen("Hey when, buy milk", p) == "buy milk" and strip_gwen("buy milk", p) == "buy milk"
    print("wake: ok")
