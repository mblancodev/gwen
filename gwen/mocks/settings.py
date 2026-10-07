"""Gwen Settings: native HUD window, or HTML sketch."""
import subprocess

from gwen import hud as hud_mod
from gwen.mocks import open_design


def main(args):
    if "html" in args:
        return open_design("settings.html")
    if hud_mod.ensure_hud():
        subprocess.Popen([hud_mod.HUD_BIN, "--settings"])
        print("opened Gwen Settings (native)", flush=True)
        return None
    return open_design("settings.html")
