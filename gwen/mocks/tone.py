"""Self-check for per-app tone resolve + apply."""
from __future__ import annotations

import os
import tempfile

from gwen.voice import tone as tone_mod
from gwen.voice.dictation import polish
from gwen.voice import config as cfg_mod


def main(args):
    failed = 0
    print("Per-app tone (resolve / apply / polish)", flush=True)
    print("", flush=True)

    def check(name, cond, detail=""):
        nonlocal failed
        ok = bool(cond)
        if not ok:
            failed += 1
        print("  [%s] %s%s" % ("ok" if ok else "FAIL", name, (" — " + detail) if detail else ""), flush=True)

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "tone.json")
        old_tone, old_voice = tone_mod.TONE, tone_mod.VOICE_DIR
        tone_mod.TONE = path
        tone_mod.VOICE_DIR = tmp
        try:
            check("slack → casual", tone_mod.resolve("com.tinyspeck.slackdesktop") == "casual")
            check("mail → formal", tone_mod.resolve("com.apple.mail") == "formal")
            check("terminal → verbatim", tone_mod.resolve("com.apple.Terminal") == "verbatim")
            check("unknown → default", tone_mod.resolve("com.example.Unknown") == "default")

            tone_mod.set_tone("com.tinyspeck.slackdesktop", "formal")
            check("override slack formal", tone_mod.resolve("com.tinyspeck.slackdesktop") == "formal")
            tone_mod.clear_tone("com.tinyspeck.slackdesktop")
            check("clear restores default", tone_mod.resolve("com.tinyspeck.slackdesktop") == "casual")

            # Setting back to built-in drops override file entry
            tone_mod.set_tone("com.apple.mail", "casual")
            tone_mod.set_tone("com.apple.mail", "formal")
            check("redundant override dropped", "com.apple.mail" not in tone_mod.overrides())

            tone_mod.set_tone("com.example.CustomApp", "default")
            check("custom default persists", "com.example.CustomApp" in tone_mod.overrides()
                  and tone_mod.resolve("com.example.CustomApp") == "default")
            tone_mod.clear_tone("com.example.CustomApp")
            check("custom removed", "com.example.CustomApp" not in tone_mod.overrides())

            for text, tone, expect, mode in tone_mod.CASES:
                got = tone_mod.apply_tone(text, tone)
                if mode == "eq":
                    check("%s/%s" % (tone, text[:20]), got == expect, repr(got))
                elif mode == "has":
                    check("%s has %r" % (tone, expect), expect in got, repr(got))
                elif mode == "lacks":
                    check("%s lacks %r" % (tone, expect), expect not in got.lower() if expect.islower() else expect not in got, repr(got))

            cfg = {**cfg_mod.DEFAULTS, "transcribe": dict(cfg_mod.DEFAULTS["transcribe"])}
            # verbatim polish skips filler strip path — um kept if in text
            out, how = polish("um git status", cfg, bundle="com.apple.Terminal")
            check("verbatim how", how == "verbatim", how)
            check("verbatim keeps um", "um" in out.lower(), repr(out))

            out, how = polish("I don't think we should ship it", cfg, bundle="com.apple.mail")
            check("formal expands", "do not" in out, repr(out))
            check("formal how tag", "formal" in how, how)

            out, how = polish("hey ship it tomorrow.", cfg, bundle="com.tinyspeck.slackdesktop")
            # after punctuate may capitalize; casual drops trailing period on short lines
            check("casual drops period", not out.endswith("."), repr(out))
        finally:
            tone_mod.TONE = old_tone
            tone_mod.VOICE_DIR = old_voice

    print("", flush=True)
    if failed:
        return "%d tone cases failed" % failed
    print("tone cases passed. Settings → Tone; ~/.gwen/voice/tone.json.", flush=True)
    return None
