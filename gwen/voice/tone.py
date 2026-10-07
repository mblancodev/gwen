"""Per-app dictation tone: casual / formal / verbatim / default → ~/.gwen/voice/tone.json."""
from __future__ import annotations

import json
import os
import re

from gwen.voice.paths import TONE, VOICE_DIR

TONES = ("default", "casual", "formal", "verbatim")

# Built-in profiles (user overrides in tone.json win).
DEFAULTS: dict[str, str] = {
    # Casual chat
    "com.tinyspeck.slackdesktop": "casual",
    "com.apple.MobileSMS": "casual",
    "com.apple.iChat": "casual",
    "com.hnc.Discord": "casual",
    "net.whatsapp.WhatsApp": "casual",
    "com.apple.FaceTime": "casual",
    "com.facebook.archon": "casual",  # Messenger
    # Formal mail
    "com.apple.mail": "formal",
    "com.microsoft.Outlook": "formal",
    "com.readdle.smartemail-Mac": "formal",
    "com.apple.mobilemail": "formal",
    # Verbatim terminals / shells
    "com.apple.Terminal": "verbatim",
    "com.googlecode.iterm2": "verbatim",
    "dev.warp.Warp-Stable": "verbatim",
    "dev.warp.Warp": "verbatim",
    "com.mitchellh.ghostty": "verbatim",
    "net.kovidgoyal.kitty": "verbatim",
    "org.alacritty": "verbatim",
    "io.alacritty": "verbatim",
    "com.github.wez.wezterm": "verbatim",
    "co.zeit.hyper": "verbatim",
    "org.tabby": "verbatim",
    "com.termius-dmg.mac": "verbatim",
}

# Formal: expand common English contractions (case-preserving).
_EXPAND = [
    (r"\bwon't\b", "will not"),
    (r"\bcan't\b", "cannot"),
    (r"\bshan't\b", "shall not"),
    (r"\bdon't\b", "do not"),
    (r"\bdoesn't\b", "does not"),
    (r"\bdidn't\b", "did not"),
    (r"\bwouldn't\b", "would not"),
    (r"\bcouldn't\b", "could not"),
    (r"\bshouldn't\b", "should not"),
    (r"\bisn't\b", "is not"),
    (r"\baren't\b", "are not"),
    (r"\bwasn't\b", "was not"),
    (r"\bweren't\b", "were not"),
    (r"\bhaven't\b", "have not"),
    (r"\bhasn't\b", "has not"),
    (r"\bhadn't\b", "had not"),
    (r"\bi'm\b", "I am"),
    (r"\bi've\b", "I have"),
    (r"\bi'd\b", "I would"),
    (r"\bi'll\b", "I will"),
    (r"\byou're\b", "you are"),
    (r"\byou've\b", "you have"),
    (r"\byou'd\b", "you would"),
    (r"\byou'll\b", "you will"),
    (r"\bwe're\b", "we are"),
    (r"\bwe've\b", "we have"),
    (r"\bwe'd\b", "we would"),
    (r"\bwe'll\b", "we will"),
    (r"\bthey're\b", "they are"),
    (r"\bthey've\b", "they have"),
    (r"\bthey'd\b", "they would"),
    (r"\bthey'll\b", "they will"),
    (r"\bit's\b", "it is"),
    (r"\bthat's\b", "that is"),
    (r"\bthere's\b", "there is"),
    (r"\bhere's\b", "here is"),
    (r"\bwho's\b", "who is"),
    (r"\bwhat's\b", "what is"),
    (r"\blet's\b", "let us"),
]


def _read() -> dict:
    try:
        with open(TONE) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write(data: dict) -> None:
    os.makedirs(VOICE_DIR, exist_ok=True)
    with os.fdopen(os.open(TONE + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(TONE + ".tmp", TONE)


def overrides() -> dict[str, str]:
    apps = _read().get("apps") or {}
    out = {}
    for k, v in apps.items():
        if isinstance(k, str) and isinstance(v, str) and v in TONES:
            out[k] = v
    return out


def set_tone(bundle: str, tone: str) -> None:
    """Persist a tone. Built-in+matching default drops override; custom apps always stay listed."""
    bundle = (bundle or "").strip()
    tone = (tone or "").strip().lower()
    if not bundle or tone not in TONES:
        return
    data = _read()
    apps = dict(data.get("apps") or {})
    if bundle in DEFAULTS and tone == DEFAULTS[bundle]:
        apps.pop(bundle, None)
    else:
        apps[bundle] = tone
    data["apps"] = apps
    _write(data)


def clear_tone(bundle: str) -> None:
    data = _read()
    apps = dict(data.get("apps") or {})
    if bundle in apps:
        apps.pop(bundle, None)
        data["apps"] = apps
        _write(data)


def resolve(bundle: str | None) -> str:
    """Effective tone for a bundle id."""
    b = (bundle or "").strip()
    if not b:
        return "default"
    o = overrides()
    if b in o:
        return o[b]
    return DEFAULTS.get(b, "default")


def profiles() -> list[tuple[str, str, bool]]:
    """(bundle, tone, is_override) — defaults plus overrides, sorted."""
    o = overrides()
    keys = sorted(set(DEFAULTS) | set(o), key=lambda k: (resolve(k), k))
    return [(k, resolve(k), k in o) for k in keys]


def is_custom(bundle: str) -> bool:
    return bundle not in DEFAULTS


def apply_tone(text: str, tone: str) -> str:
    """Post-process polished text for the tone. Verbatim is handled earlier in polish()."""
    if not text or not text.strip():
        return text
    tone = tone if tone in TONES else "default"
    if tone == "formal":
        return _formal(text)
    if tone == "casual":
        return _casual(text)
    return text


def _match_case(src: str, repl: str) -> str:
    if src.isupper():
        return repl.upper()
    if src[0].isupper():
        return repl[0].upper() + repl[1:]
    return repl


def _formal(text: str) -> str:
    out = text
    for pat, repl in _EXPAND:
        out = re.sub(pat, lambda m, r=repl: _match_case(m.group(0), r), out, flags=re.I)
    out = out.strip()
    # Ensure a terminal period on a single plain sentence.
    if out and out[-1] not in ".!?…:;" and "\n" not in out and len(out.split()) >= 3:
        out += "."
    return out


def _casual(text: str) -> str:
    out = text.strip()
    # Chatty: drop a lone trailing period on short one-liners.
    if (
        out.endswith(".")
        and not out.endswith("...")
        and out.count(".") == 1
        and "\n" not in out
        and len(out.split()) <= 10
    ):
        out = out[:-1]
    return out


# Self-check fixtures
CASES = [
    # (text, tone, expect_contains_or_equals, mode)
    # mode: "eq" exact, "has" substring, "lacks" substring
    ("I don't think so.", "formal", "do not", "has"),
    ("I don't think so.", "formal", "don't", "lacks"),
    ("hey ship it tomorrow.", "casual", "hey ship it tomorrow", "eq"),
    ("please wait for me", "verbatim", "please wait for me", "eq"),
    ("Ship it.", "default", "Ship it.", "eq"),
]
