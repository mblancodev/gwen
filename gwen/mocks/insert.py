"""Self-check for intelligent insert (caret context rules)."""
from __future__ import annotations

from gwen.voice.insert import CASES, smart_insert


def main(args):
    failed = 0
    print("Intelligent insert (before | text | after → result)", flush=True)
    print("", flush=True)
    for before, text, after, expect in CASES:
        got = smart_insert(text, before, after)
        ok = got == expect
        if not ok:
            failed += 1
        mark = "ok" if ok else "FAIL"
        print("  [%s] %r + %r + %r" % (mark, before, text, after), flush=True)
        print("        → %r%s" % (got, "" if ok else "  want %r" % expect), flush=True)
    print("", flush=True)
    if failed:
        return "%d insert cases failed" % failed
    print("%d cases passed. Swift: macapp/Insert.swift → deliver()." % len(CASES), flush=True)
    return None
