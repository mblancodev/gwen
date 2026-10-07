"""Load ~/.gwen/config.json with Gwen voice defaults."""
from __future__ import annotations

import json
import os

from gwen.voice.paths import CONFIG, HOME

DEFAULTS = {
    "learn_from_edits": True,
    "format_dictation": False,
    "keep_corrected": False,
    "apple_speech": False,
    "polish": False,
    "hud_visible": False,
    "mic": "default",
    "transcribe": {"polish": False, "agent": None, "model": None},
}


def load() -> dict:
    cfg = dict(DEFAULTS)
    cfg["transcribe"] = dict(DEFAULTS["transcribe"])
    try:
        with open(CONFIG) as f:
            raw = json.load(f)
        if isinstance(raw, dict):
            for k, v in raw.items():
                if k == "transcribe" and isinstance(v, dict):
                    cfg["transcribe"].update(v)
                else:
                    cfg[k] = v
    except (OSError, ValueError):
        pass
    if cfg.get("polish") and not cfg["transcribe"].get("polish"):
        cfg["transcribe"]["polish"] = True
    if cfg["transcribe"].get("polish") and not cfg["transcribe"].get("agent"):
        cfg["transcribe"]["agent"] = "claude"  # the Settings switch is the whole opt-in; the only agent wired
    return cfg
