"""`gwen bundle`: self-contained Gwen.app + Gwen.dmg.

Swift HUD binary plus Gwen's Python sources in Contents/Resources/gwen.
Uses the Mac's /usr/bin/python3. DMG shows Gwen.app beside Applications.
"""
from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
MACAPP = os.path.join(ROOT, "macapp")
ART = os.path.join(MACAPP, "art")

from gwen.hud import APP_PLIST, ensure_hud, sign as hud_sign  # noqa: E402

LAYOUT = """
tell application "Finder"
  repeat 40 times
    if exists disk "%s" then exit repeat
    delay 0.25
  end repeat
  tell disk "%s"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 548}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 10
    try
      set background picture of opts to file ".background:background.tiff"
    end try
    set position of item "Gwen.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    close
    open
    delay 1
    set bounds of container window to {200, 120, 850, 538}
    delay 1
    set bounds of container window to {200, 120, 860, 548}
    delay 2
    close
    delay 3
  end tell
end tell
"""


def say(ok, msg, hint=None):
    import sys
    marks = ({True: "\033[32m✓\033[0m", False: "\033[31m✗\033[0m", None: "\033[33m!\033[0m"} if sys.stdout.isatty()
             else {True: "✓", False: "✗", None: "!"})
    print("  %s %s" % (marks[ok], msg), flush=True)
    if hint:
        print("      " + hint, flush=True)
    return ok


def sign(app):
    return hud_sign(app, deep=True)


def bundle(out=None):
    out = os.path.abspath(out or os.path.join(ROOT, "dist"))
    print("Bundling Gwen", flush=True)
    os.makedirs(out, exist_ok=True)
    app = os.path.join(out, "Gwen.app")
    try:
        if os.path.exists(app) and not os.path.islink(app):
            # Rebuild into place via ensure_hud then enrich Resources
            pass
        elif os.path.islink(app):
            os.remove(app)
    except PermissionError:
        print("Can't replace %s: check ownership (sudo chown -R \"$(id -un)\" %s)" % (app, out), flush=True)
        return 1

    if not ensure_hud(force=True):
        return 1
    # ensure_hud writes ROOT/dist/Gwen.app — same as app when out==dist
    if os.path.realpath(app) != os.path.realpath(os.path.join(ROOT, "dist", "Gwen.app")):
        if os.path.exists(app):
            shutil.rmtree(app)
        shutil.copytree(os.path.join(ROOT, "dist", "Gwen.app"), app, symlinks=True)

    # Icon + plist
    plist = dict(APP_PLIST, CFBundleIconFile="AppIcon")
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(plist, f)
    res = os.path.join(app, "Contents", "Resources")
    os.makedirs(res, exist_ok=True)
    icns = os.path.join(ART, "AppIcon.icns")
    if os.path.isfile(icns):
        shutil.copy(icns, os.path.join(res, "AppIcon.icns"))
        say(True, "AppIcon.icns")
    else:
        say(None, "no macapp/art/AppIcon.icns (DMG/app icon skipped)")

    # Embed Gwen sources so a dragged-to-Applications copy can still run `gwen` from Resources
    dest = os.path.join(res, "gwen")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    for rel in ("gwen", "bin"):
        src = os.path.join(ROOT, rel)
        shutil.copytree(src, os.path.join(dest, rel), ignore=shutil.ignore_patterns(
            "__pycache__", "*.pyc", ".DS_Store", "*.swift"))
    # BUILD stamp
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    with open(os.path.join(dest, "BUILD"), "w") as f:
        f.write((commit.stdout or "").strip() or "unknown")
    say(True, "copied Gwen sources into the app")

    p = sign(app)
    if not say(p.returncode == 0, "signed Gwen.app"):
        print(p.stderr, flush=True)
        return 1

    dmg = make_dmg(app, out)
    say(True, "built %s" % dmg)
    print("\nDone: %s and %s." % (app, dmg), flush=True)
    print("Drag Gwen.app to Applications, then from a checkout: gwen install", flush=True)
    return 0


def make_dmg(app, out):
    dmg, rw = os.path.join(out, "Gwen.dmg"), os.path.join(out, "Gwen-rw.dmg")
    with tempfile.TemporaryDirectory() as stage:
        shutil.copytree(app, os.path.join(stage, "Gwen.app"), symlinks=True)
        os.symlink("/Applications", os.path.join(stage, "Applications"))
        bg = os.path.join(ART, "dmg-background.tiff")
        if os.path.isfile(bg):
            os.makedirs(os.path.join(stage, ".background"))
            shutil.copy(bg, os.path.join(stage, ".background", "background.tiff"))
        subprocess.run(["hdiutil", "create", "-volname", "Gwen", "-srcfolder", stage, "-fs", "HFS+",
                        "-format", "UDRW", "-ov", rw], check=True, capture_output=True)
    attach = subprocess.run(["hdiutil", "attach", "-readwrite", "-noverify", "-noautoopen", rw],
                            check=True, capture_output=True, text=True).stdout
    mount = re.search(r"(/Volumes/.+)$", attach, re.M).group(1).strip()
    try:
        name = os.path.basename(mount)
        p = subprocess.run(["osascript", "-e", LAYOUT % (name, name)], capture_output=True, text=True, timeout=60)
        styled = p.returncode == 0
        hint = None
        if not styled:
            err = (p.stderr or "").strip()
            hint = ("allow Terminal to control Finder to style it: " + err) if "-1743" in err else (err or None)
        say(styled or None, "DMG window styled" if styled else "DMG layout skipped", hint)
        icns = os.path.join(ART, "AppIcon.icns")
        if os.path.isfile(icns):
            shutil.copy(icns, os.path.join(mount, ".VolumeIcon.icns"))
            subprocess.run(["SetFile", "-a", "C", mount], capture_output=True)
        subprocess.run(["sync"])
    finally:
        subprocess.run(["hdiutil", "detach", mount, "-quiet"])
    subprocess.run(["hdiutil", "convert", rw, "-format", "UDZO", "-imagekey", "zlib-level=9", "-ov", "-o", dmg],
                   check=True, capture_output=True)
    os.remove(rw)
    return dmg
