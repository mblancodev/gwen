"""Self-check for mid-utterance backtrack cues."""
from __future__ import annotations

from gwen.voice.backtrack import CASES, backtrack


def main(args):
    failed = 0
    print("Backtrack (utterance → kept)", flush=True)
    print("", flush=True)
    for raw, expect in CASES:
        got = backtrack(raw)
        ok = got == expect
        if not ok:
            failed += 1
        print("  [%s] %r" % ("ok" if ok else "FAIL", raw), flush=True)
        print("        → %r%s" % (got, "" if ok else "  want %r" % expect), flush=True)
    print("", flush=True)
    if failed:
        return "%d backtrack cases failed" % failed
    print("%d cases passed. Applied in polish/live_text." % len(CASES), flush=True)
    return None
