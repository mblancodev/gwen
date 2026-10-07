"""Self-check for short take history (record / bump / cap / clear)."""
from __future__ import annotations

import os
import tempfile

from gwen.voice import takes as takes_mod


def main(args):
    failed = 0
    print("Takes history (record → list / last / bump / cap)", flush=True)
    print("", flush=True)

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "takes.json")
        old_takes, old_voice = takes_mod.TAKES, takes_mod.VOICE_DIR
        takes_mod.TAKES = path
        takes_mod.VOICE_DIR = tmp
        try:
            takes_mod.clear()
            cases = []

            def check(name, cond, detail=""):
                nonlocal failed
                ok = bool(cond)
                if not ok:
                    failed += 1
                print("  [%s] %s%s" % ("ok" if ok else "FAIL", name, (" — " + detail) if detail else ""), flush=True)

            takes_mod.record("hello world")
            check("last after record", takes_mod.last() and takes_mod.last()["text"] == "hello world")

            takes_mod.record("hello world")  # bump, no duplicate
            check("bump same text", len(takes_mod.list_takes()) == 1)

            takes_mod.record("second take", lang="es")
            lst = takes_mod.list_takes()
            check("newest first", lst[0]["text"] == "second take" and lst[1]["text"] == "hello world")
            check("lang stored", lst[0].get("lang") == "es")
            check("get 1-based", takes_mod.get(2) and takes_mod.get(2)["text"] == "hello world")
            check("get out of range", takes_mod.get(99) is None)

            for i in range(takes_mod.MAX_TAKES + 5):
                takes_mod.record("take %d" % i)
            check("capped at MAX", len(takes_mod.list_takes()) == takes_mod.MAX_TAKES,
                  "got %d" % len(takes_mod.list_takes()))
            check("newest is last written", takes_mod.last()["text"] == "take %d" % (takes_mod.MAX_TAKES + 4))

            takes_mod.clear()
            check("clear", takes_mod.list_takes() == [] and takes_mod.last() is None)

            takes_mod.record("  ")
            check("blank ignored", takes_mod.list_takes() == [])
        finally:
            takes_mod.TAKES = old_takes
            takes_mod.VOICE_DIR = old_voice

    print("", flush=True)
    if failed:
        return "%d takes cases failed" % failed
    print("takes history cases passed. File: ~/.gwen/voice/takes.json; HUD ⌃⌘V / menu." , flush=True)
    return None
