"""Short history of dictation takes → ~/.gwen/voice/takes.json."""
from __future__ import annotations

import json
import os
import time

from gwen.voice.paths import TAKES, VOICE_DIR

MAX_TAKES = 25


def _read() -> list[dict]:
    try:
        with open(TAKES) as f:
            data = json.load(f)
        if isinstance(data, list):
            return [t for t in data if isinstance(t, dict) and isinstance(t.get("text"), str) and t["text"].strip()]
        if isinstance(data, dict) and isinstance(data.get("takes"), list):
            return [t for t in data["takes"] if isinstance(t, dict) and isinstance(t.get("text"), str) and t["text"].strip()]
    except (OSError, ValueError):
        pass
    return []


def _write(takes: list[dict]) -> None:
    os.makedirs(VOICE_DIR, exist_ok=True)
    payload = {"takes": takes}
    with os.fdopen(os.open(TAKES + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(payload, f, indent=2)
    os.replace(TAKES + ".tmp", TAKES)


def list_takes() -> list[dict]:
    """Newest first."""
    return _read()


def last() -> dict | None:
    takes = _read()
    return takes[0] if takes else None


def get(index: int) -> dict | None:
    """1-based index into newest-first list."""
    takes = _read()
    if index < 1 or index > len(takes):
        return None
    return takes[index - 1]


def record(text: str, lang: str = "") -> list[dict]:
    """Prepend a take (or bump if same as newest). Returns the list."""
    t = (text or "").strip()
    if not t:
        return _read()
    takes = _read()
    now = time.time()
    if takes and takes[0].get("text") == t:
        takes[0] = {"text": t, "at": now, "lang": lang or takes[0].get("lang") or ""}
    else:
        takes.insert(0, {"text": t, "at": now, "lang": lang or ""})
        takes = takes[:MAX_TAKES]
    _write(takes)
    return takes


def clear() -> None:
    _write([])


# Self-check cases (temp file overridden in mock via monkeypatch or env)
CASES_DOC = "record → last; bump same text; cap at MAX; clear"
