"""Translate-selection demo on Gwen HUD (or HTML)."""
from gwen.mocks.bar import main as bar_main


def main(args):
    if "html" in args:
        return bar_main(["selection", "html"])
    return bar_main(["selection"])
