"""Build and launch Gwen.app (macapp/*.swift → dist/Gwen.app; ~/.gwen/Gwen.app → symlink)."""
from __future__ import annotations

import glob
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MACAPP = os.path.join(ROOT, "macapp")
DIST_APP = os.path.join(ROOT, "dist", "Gwen.app")
HOME_APP = os.path.expanduser("~/.gwen/Gwen.app")
# A Gwen.app from the DMG carries these sources in Contents/Resources/gwen (`gwen bundle`): run from there, that
# app is the build and there is nothing to compile. From a checkout, runtime launches the project dist build.
BUNDLED = ROOT.endswith(".app/Contents/Resources/gwen")
APP = ROOT[:-len("/Contents/Resources/gwen")] if BUNDLED else DIST_APP
MIN_OS = "13.0"  # the oldest macOS Gwen runs on; newer APIs are behind #available
HUD_BIN = os.path.join(APP, "Contents", "MacOS", "Gwen")
PLIST_SRC = os.path.join(MACAPP, "Info.plist")
ICON_SRC = os.path.join(MACAPP, "art", "AppIcon.icns")
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
              "/Support/lsregister")

APP_PLIST = {
    "CFBundleName": "Gwen",
    "CFBundleDisplayName": "Gwen",
    "CFBundleIdentifier": "app.gwen.hud",
    "CFBundleVersion": "0.1",
    "CFBundleShortVersionString": "0.1",
    "CFBundleExecutable": "Gwen",
    "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": MIN_OS,
    "CFBundleURLTypes": [{"CFBundleURLName": "app.gwen.hud", "CFBundleURLSchemes": ["gwen"]}],
    "LSUIElement": True,
    "NSMicrophoneUsageDescription": "Gwen listens when you hold Control to dictate.",
    "NSSpeechRecognitionUsageDescription": "Gwen shows your words as you dictate.",
}


SIGN_ID = "Gwen Local Signing"
SIGN_CONF = """[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = %s
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
""" % SIGN_ID


def signing_identity() -> str:
    """A self-signed code-signing certificate in the login keychain, made once. An ad-hoc signature
    pins macOS's Microphone/Accessibility grants to one exact build, so every rebuild silently loses them; signed
    with this, Gwen.app keeps one identity. Falls back to ad-hoc ("-")."""
    if subprocess.run(["security", "find-certificate", "-c", SIGN_ID], capture_output=True).returncode == 0:
        return SIGN_ID
    with tempfile.TemporaryDirectory() as d:
        conf, key, crt, p12 = (os.path.join(d, n) for n in ("c.cnf", "k.pem", "c.pem", "i.p12"))
        with open(conf, "w") as f:
            f.write(SIGN_CONF)
        steps = [["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", conf,
                  "-keyout", key, "-out", crt],
                 ["/usr/bin/openssl", "pkcs12", "-export", "-inkey", key, "-in", crt, "-out", p12, "-passout", "pass:gwen"],
                 ["security", "import", p12, "-P", "gwen", "-T", "/usr/bin/codesign"]]  # codesign may use it, no prompt
        for cmd in steps:
            p = subprocess.run(cmd, capture_output=True, text=True)
            if p.returncode:
                print("gwen hud: signing identity: %s" % p.stderr[-300:], flush=True)
                return "-"
    return SIGN_ID


def sign(app: str, deep: bool = False) -> subprocess.CompletedProcess:
    cmd = ["codesign", "--force"] + (["--deep"] if deep else []) + ["--sign", signing_identity(), app]
    return subprocess.run(cmd, capture_output=True, text=True)


def _link_home_app() -> None:
    """Point ~/.gwen/Gwen.app at the build so older paths still resolve."""
    home = os.path.expanduser("~/.gwen")
    os.makedirs(home, exist_ok=True)
    target = APP
    link = HOME_APP
    try:
        if os.path.islink(link):
            if os.path.realpath(link) == os.path.realpath(target):
                return
            os.remove(link)
        elif os.path.isdir(link):
            # Replace a previous real build with a symlink.
            import shutil
            shutil.rmtree(link)
        elif os.path.exists(link):
            os.remove(link)
        os.symlink(target, link)
    except OSError as e:
        print("gwen hud: could not link %s → %s (%s)" % (link, target, e), flush=True)


def ensure_hud(force: bool = False, universal: bool = False) -> bool:
    """Compile macapp/*.swift into dist/Gwen.app when sources are newer; symlink ~/.gwen/Gwen.app.
    `universal` builds for Apple silicon and Intel (the DMG); otherwise only for this Mac."""
    if BUNDLED:
        _link_home_app()
        return True
    sources = sorted(glob.glob(os.path.join(MACAPP, "*.swift")))
    if not sources:
        print("gwen hud: no macapp/*.swift sources", flush=True)
        return False
    try:
        newest = max(os.path.getmtime(f) for f in sources)
        if force or not os.path.exists(HUD_BIN) or newest > os.path.getmtime(HUD_BIN):
            os.makedirs(os.path.dirname(HUD_BIN), exist_ok=True)
            with tempfile.TemporaryDirectory() as tmp:
                thin = []
                for arch in ("arm64", "x86_64") if universal else (platform.machine(),):
                    thin.append(os.path.join(tmp, arch))
                    p = subprocess.run(["swiftc", "-O", "-target", "%s-apple-macos%s" % (arch, MIN_OS)] + sources
                                       + ["-o", thin[-1]], capture_output=True, text=True)
                    if p.returncode:
                        print("gwen hud: build failed:\n" + (p.stderr or p.stdout)[-2000:], flush=True)
                        return False
                subprocess.run(["lipo", "-create", "-output", HUD_BIN] + thin, check=True)
            with open(os.path.join(APP, "Contents", "Info.plist"), "wb") as f:
                if os.path.isfile(PLIST_SRC):
                    with open(PLIST_SRC, "rb") as src:
                        plistlib.dump(plistlib.load(src), f)
                else:
                    plistlib.dump(APP_PLIST, f)
            if os.path.isfile(ICON_SRC):  # Gwen's character, before signing: the signature seals Resources
                res = os.path.join(APP, "Contents", "Resources")
                os.makedirs(res, exist_ok=True)
                shutil.copy(ICON_SRC, os.path.join(res, "AppIcon.icns"))
            p = sign(APP)
            if p.returncode:
                print("gwen hud: signing failed: %s" % p.stderr[-300:], flush=True)
            subprocess.run([LSREGISTER, "-f", APP], capture_output=True)  # so gwen:// resolves to this build
            print("gwen hud: built %s" % HUD_BIN, flush=True)
        _link_home_app()
        return True
    except OSError as e:
        print("gwen hud: unavailable: %s" % e, flush=True)
        return False


def run_hud(extra_args: list[str] | None = None) -> int:
    """Launch dist/Gwen.app (stdin stays open until caller closes)."""
    if not ensure_hud():
        return 1
    args = [HUD_BIN] + (extra_args or [])
    return subprocess.call(args)


def open_settings(tone: bool = False) -> int:
    if not ensure_hud():
        return 1
    args = [HUD_BIN, "--settings"]
    if tone:
        args.append("--tone")
    return subprocess.call(args)
