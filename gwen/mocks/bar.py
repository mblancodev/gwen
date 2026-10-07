"""Bottom-bar demo on Gwen.app (or HTML with `html`)."""
from __future__ import annotations

import math
import subprocess
import sys
import time

from gwen import hud as hud_mod
from gwen.mocks import open_design


def _speak(send, text):
    words = text.split()
    for i in range(1, len(words) + 1):
        send("live " + " ".join(words[:i]))
        for k in range(5):
            send("level %.2f" % (0.3 + 0.5 * abs(math.sin(i * 1.7 + k))))
            time.sleep(0.05)


def run_hud_scene(scene: str) -> str | None:
    if not hud_mod.ensure_hud():
        return "Couldn't build Gwen.app — see errors above, or try: gwen mock bar html"
    bar = subprocess.Popen([hud_mod.HUD_BIN], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)

    def send(line):
        bar.stdin.write(line + chr(10))
        bar.stdin.flush()

    try:
        time.sleep(0.8)
        send("visible on")
        if scene == "translate":
            send("state translating")
            send("chip EN")
            time.sleep(0.4)
            send("live listening…")
            time.sleep(0.8)
            _speak(send, "hola como estas hoy")
            time.sleep(0.5)
            send("state cleaning")
            time.sleep(0.8)
            send("transcript hello how are you today")
            time.sleep(3.5)
        elif scene == "selection":
            send("state translating")
            send("chip ES")
            send("live Select text to translate")
            time.sleep(2.0)
            send("transcript Texto traducido")
            time.sleep(3.0)
        elif scene == "clean":
            send("state cleaning")
            time.sleep(2.0)
            send("state idle")
            time.sleep(1.0)
        else:
            send("state dictating")
            time.sleep(0.5)
            _speak(send, "the login fix is ready for review and I will pick up the flaky test after lunch")
            time.sleep(0.6)
            send("state cleaning")
            time.sleep(1.2)
            # Prefer transcript in demos so Accessibility is not required to see the bar finish.
            send("transcript the login fix is ready for review and I will pick up the flaky test after lunch")
            time.sleep(3.5)
            send("state idle")
            time.sleep(1.0)
    finally:
        bar.terminate()
        try:
            bar.wait(timeout=2)
        except subprocess.TimeoutExpired:
            bar.kill()
    return None


def main(args):
    scene = "dictate"
    use_html = False
    for a in args:
        if a == "html":
            use_html = True
        elif a in ("dictate", "translate", "selection", "clean"):
            scene = a
    if use_html:
        return open_design("bar-demo.html", "scene=" + scene)
    err = run_hud_scene(scene)
    if err:
        print(err, file=sys.stderr)
        print("Falling back to HTML…", flush=True)
        return open_design("bar-demo.html", "scene=" + scene)
    return None
