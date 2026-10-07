"""Scripted Gwen demos. Prefer real Gwen.app HUD when built; HTML/text remain."""
from __future__ import annotations

import importlib
import webbrowser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESIGN = ROOT / "design"

MOCKS = {
    "bar": (
        "Bottom bar dictate → clean → idle. Default: Gwen.app HUD. Pass html for design/bar-demo.html.",
        "hud",
    ),
    "translate": (
        "Speech-translate scene on Gwen.app HUD (or html).",
        "hud",
    ),
    "selection": (
        "Translate-selection scene on Gwen.app HUD (or html).",
        "hud",
    ),
    "settings": (
        "Gwen Settings: native window when HUD builds; else HTML sketch.",
        "hud",
    ),
    "punctuation": (
        "Before/after punctuation samples in the terminal.",
        "text",
    ),
    "fixes": (
        "Learn-words storyboard (text). Real paste+AX needs a live listener.",
        "text",
    ),
    "insert": (
        "Intelligent insert rules: caps/spaces/punct from caret neighbors (self-check).",
        "text",
    ),
    "backtrack": (
        "Mid-utterance restart cues (scratch that / actually / wait) — self-check.",
        "text",
    ),
    "takes": (
        "Short take history: record / bump / cap / clear — self-check.",
        "text",
    ),
    "tone": (
        "Per-app tone (casual / formal / verbatim) — self-check.",
        "text",
    ),
}


def list_mocks() -> list[str]:
    return sorted(MOCKS)


def open_design(name: str, query: str = "") -> str | None:
    path = DESIGN / name
    if not path.is_file():
        return "Missing %s" % path
    url = path.as_uri() + (("?" + query) if query else "")
    webbrowser.open(url)
    print("opened %s" % url, flush=True)
    return None


def run(name: str, args: list[str]) -> int:
    if name not in MOCKS:
        have = ", ".join(list_mocks())
        print("gwen mock: no mock called %s; there are %s" % (name, have), flush=True)
        return 2
    mod = importlib.import_module("gwen.mocks.%s" % name.replace("-", "_"))
    err = mod.main(args)
    if err:
        print(err, flush=True)
        return 1
    return 0
