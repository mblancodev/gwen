"""`gwen install` / `gwen uninstall`: Gwen-only login setup.

Idempotent. Installs:
  dist/Gwen.app (build) + ~/.gwen/Gwen.app symlink
  ~/Library/LaunchAgents/app.gwen.listen   gwen listen at login
  ~/.local/bin/gwen                        CLI symlink
  Whisper via gwen setup voice (best-effort)
"""
from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys

from gwen import hud as hud_mod
from gwen.voice.paths import HOME

AGENTS_DIR = os.path.expanduser("~/Library/LaunchAgents")
LOGS = os.path.join(HOME, "logs")
LABEL = "app.gwen.listen"
LINK = os.path.expanduser("~/.local/bin/gwen")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
BIN = os.path.join(ROOT, "bin", "gwen")
PYTHON = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable


def say(ok, msg, hint=None):
    marks = ({True: "\033[32m✓\033[0m", False: "\033[31m✗\033[0m", None: "\033[33m!\033[0m"} if sys.stdout.isatty()
             else {True: "✓", False: "✗", None: "!"})
    print("  %s %s" % (marks[ok], msg), flush=True)
    if hint:
        print("      " + hint, flush=True)
    return ok


def sh(*cmd, **kw):
    return subprocess.run(list(cmd), capture_output=True, text=True, **kw)


def agent_path_env():
    dirs = [os.path.expanduser("~/.local/bin"), os.path.dirname(BIN)]
    for tool in ("python3", "swiftc", "ffmpeg", "git"):
        found = shutil.which(tool)
        if found:
            dirs.append(os.path.dirname(found))
    dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    return ":".join(dict.fromkeys(dirs))


def uid_domain():
    return "gui/%d" % os.getuid()


def bootout(label):
    target = "%s/%s" % (uid_domain(), label)
    p = sh("launchctl", "bootout", target)
    import time
    for _ in range(40):
        if sh("launchctl", "print", target).returncode:
            break
        time.sleep(0.15)
    return p


def load_agent(label, plist):
    path = os.path.join(AGENTS_DIR, label + ".plist")
    bootout(label)
    os.makedirs(AGENTS_DIR, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump(plist, f)
    sh("launchctl", "enable", "%s/%s" % (uid_domain(), label))
    p = sh("launchctl", "bootstrap", uid_domain(), path)
    return p.returncode == 0, p.stderr.strip()


def install():
    print("Installing Gwen", flush=True)
    ok = say(sys.version_info >= (3, 9), "Python %s" % sys.version.split()[0])
    swift = sh("xcode-select", "-p").returncode == 0 and bool(shutil.which("swiftc"))
    ok &= say(swift, "Swift compiler", None if swift else "run: xcode-select --install")
    if not ok:
        print("\nFix the ✗ items above, then run `gwen install` again.", flush=True)
        return 1

    if not say(hud_mod.ensure_hud(force=False), "Gwen.app built (%s)" % hud_mod.APP):
        return 1

    os.makedirs(os.path.dirname(LINK), exist_ok=True)
    if os.path.islink(LINK) or os.path.exists(LINK):
        if os.path.realpath(LINK) != os.path.realpath(BIN):
            os.remove(LINK)
    if not os.path.exists(LINK):
        os.symlink(BIN, LINK)
    say(os.path.realpath(LINK) == os.path.realpath(BIN), "CLI: %s" % LINK,
        None if os.path.dirname(LINK) in os.environ.get("PATH", "").split(":") else "add ~/.local/bin to your PATH")

    try:
        from gwen.setup.voice import ensure_voice
        whisper = ensure_voice(start=True)
        say(whisper or None, "Whisper ready" if whisper else "Whisper not started (gwen setup later)")
    except Exception as e:
        say(None, "Whisper skipped: %s" % e)

    plist = {
        "Label": LABEL,
        "ProgramArguments": [hud_mod.HUD_BIN, "--run", PYTHON, BIN, "listen"],  # Gwen.app first: macOS names the item by it
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Interactive",
        "LimitLoadToSessionType": "Aqua",
        "WorkingDirectory": ROOT,
        "EnvironmentVariables": {
            "PATH": agent_path_env(),
            "PYTHONUNBUFFERED": "1",
            "LANG": "en_US.UTF-8",
        },
        "StandardOutPath": os.path.join(LOGS, "listen.log"),
        "StandardErrorPath": os.path.join(LOGS, "listen.log"),
    }
    loaded, err = load_agent(LABEL, plist)
    say(loaded, "Login: gwen listen (%s)" % LABEL, err or None)

    print("\nDone. Menu bar Gwen should appear; hold ⌃ to dictate once Accessibility is allowed.", flush=True)
    print("Settings: gwen settings   Uninstall login: gwen uninstall", flush=True)
    return 0 if loaded else 1


def uninstall():
    print("Uninstalling Gwen login services (keeps ~/.gwen data)", flush=True)
    bootout(LABEL)
    path = os.path.join(AGENTS_DIR, LABEL + ".plist")
    if os.path.exists(path):
        os.remove(path)
        say(True, "removed %s" % path)
    else:
        say(None, "no LaunchAgent to remove")
    if os.path.islink(LINK) and os.path.realpath(LINK) == os.path.realpath(BIN):
        os.remove(LINK)
        say(True, "removed CLI symlink %s" % LINK)
    print("Gwen.app / dist/ left in place. Delete manually if you want.", flush=True)
    return 0
