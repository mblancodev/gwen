"""gwen CLI — HUD, demos, settings, listen, setup."""
from __future__ import annotations

import argparse
import sys

from gwen import __version__
from gwen import hud as hud_mod
from gwen import mocks as mock_mod


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="gwen", description="Gwen: dictate and translate in any app.")
    p.add_argument("--version", action="version", version="gwen %s" % __version__)
    sub = p.add_subparsers(dest="cmd")

    mo = sub.add_parser("mock", help="play a Gwen demo (HUD or HTML/text)")
    mo.add_argument("name", nargs="?", help="mock name; omit to list")
    mo.add_argument("args", nargs=argparse.REMAINDER)

    hu = sub.add_parser("hud", help="build and/or launch the Gwen HUD")
    hu.add_argument("--build", action="store_true", help="compile only")
    hu.add_argument("--force", action="store_true", help="rebuild even if up to date")
    hu.add_argument("--settings", action="store_true", help="open native Settings")
    hu.add_argument("--tone", action="store_true", help="with --settings, open on the Tone pane")
    hu.add_argument("--no-whisper", action="store_true", help="skip starting Whisper")

    se = sub.add_parser("settings", help="open Gwen Settings (native HUD window, or HTML sketch if HUD missing)")
    se.add_argument("--tone", action="store_true", help="open on the Tone pane")
    sub.add_parser("build", help="compile Gwen.app into dist/Gwen.app (~/.gwen/Gwen.app → symlink)")
    sub.add_parser("install", help="build Gwen, wire CLI + login listener (Gwen-only)")
    sub.add_parser("uninstall", help="remove Gwen login agent and CLI symlink (keeps ~/.gwen)")
    bu = sub.add_parser("bundle", help="build self-contained Gwen.app + Gwen.dmg into dist/")
    bu.add_argument("--out", default=None, help="output directory (default: dist/)")
    tk = sub.add_parser("takes", help="list or clear recent dictation takes (~/.gwen/voice/takes.json)")
    tk.add_argument("action", nargs="?", default="list", help="list | clear | N (1-based show)")
    tn = sub.add_parser("tone", help="list or set per-app dictation tone")
    tn.add_argument("action", nargs="?", default="list", help="list | set BUNDLE TONE | clear BUNDLE")
    tn.add_argument("bundle", nargs="?", help="app bundle id")
    tn.add_argument("tone", nargs="?", help="default|casual|formal|verbatim")

    su = sub.add_parser("setup", help="install/start local Whisper on 127.0.0.1:2022")
    su.add_argument("--check", action="store_true", help="only report whether Whisper is up")
    su.add_argument("--stop", action="store_true", help="stop Whisper if Gwen started it in this process")

    li = sub.add_parser("listen", help="run the Gwen whisper listener (Mic FIFO + wake + dictation)")
    li.add_argument("--no-wake", action="store_true", help="skip Hey Gwen wake gate")
    li.add_argument("--no-whisper", action="store_true", help="do not auto-install/start Whisper")
    return p


def _ensure_whisper(required: bool = True) -> bool:
    from gwen.setup.voice import ensure_voice
    return ensure_voice(start=True) if required else True


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    p = build_parser()
    args = p.parse_args(argv)
    if not args.cmd:
        p.print_help()
        return 0
    if args.cmd == "install":
        from gwen.setup import install as install_mod
        return install_mod.install()
    if args.cmd == "uninstall":
        from gwen.setup import install as install_mod
        return install_mod.uninstall()
    if args.cmd == "bundle":
        from gwen.setup.bundle import bundle
        return bundle(args.out)

    if args.cmd == "build":
        return 0 if hud_mod.ensure_hud(force=True) else 1
    if args.cmd == "setup":
        from gwen.setup.voice import ensure_voice, speech_up, stop_whisper
        if args.check:
            print("Whisper is %s on 127.0.0.1:2022" % ("up" if speech_up() else "down"), flush=True)
            return 0 if speech_up() else 1
        if args.stop:
            # Best-effort: kill whatever is bound to :2022 from Gwen's start script / common whisper-server
            stop_whisper()
            _kill_port_2022()
            print("Whisper stop requested.", flush=True)
            return 0
        return 0 if ensure_voice(start=True) else 1
    if args.cmd == "hud":
        if args.settings:
            return hud_mod.open_settings(tone=getattr(args, "tone", False))
        if args.build:
            return 0 if hud_mod.ensure_hud(force=args.force) else 1
        if not getattr(args, "no_whisper", False):
            _ensure_whisper(required=True)
        if not hud_mod.ensure_hud(force=args.force):
            return 1
        print("Launching Gwen HUD (⌃ dictate, ⌃⇧ translate). Quit from the menu.", flush=True)
        print("For live mic → paste, also run: gwen listen", flush=True)
        return hud_mod.run_hud()
    if args.cmd == "settings":
        if hud_mod.ensure_hud():
            return hud_mod.open_settings(tone=getattr(args, "tone", False))
        return mock_mod.run("settings", [])
    if args.cmd == "listen":
        from gwen.voice import listen as listen_mod
        return listen_mod.main(
            wake=not args.no_wake,
            ensure_stt=not args.no_whisper,
        )
    if args.cmd == "tone":
        from gwen.voice import tone as tone_mod
        action = (args.action or "list").strip().lower()
        if action == "list" or action == "":
            for bundle, tone, overridden in tone_mod.profiles():
                mark = " *" if overridden else ""
                print("%-10s  %s%s" % (tone, bundle, mark), flush=True)
            print("", flush=True)
            print("* custom override in ~/.gwen/voice/tone.json", flush=True)
            print("Set: gwen tone set BUNDLE casual|formal|verbatim|default", flush=True)
            return 0
        if action == "set":
            bundle, tone = args.bundle, args.tone
            if not bundle or not tone or tone not in tone_mod.TONES:
                print("usage: gwen tone set BUNDLE default|casual|formal|verbatim", flush=True)
                return 2
            tone_mod.set_tone(bundle, tone)
            print("%s → %s" % (bundle, tone_mod.resolve(bundle)), flush=True)
            return 0
        if action == "clear":
            bundle = args.bundle or args.tone  # allow: tone clear BUNDLE
            # when action is clear, bundle is in args.bundle; if user did `tone clear BUNDLE`, action=clear, bundle=BUNDLE
            b = args.bundle
            if not b:
                print("usage: gwen tone clear BUNDLE", flush=True)
                return 2
            tone_mod.clear_tone(b)
            print("%s → %s (built-in)" % (b, tone_mod.resolve(b)), flush=True)
            return 0
        # allow: gwen tone set … where action parsed wrong — also `gwen tone BUNDLE` show one
        if action in tone_mod.TONES and args.bundle:
            # unlikely
            pass
        print("usage: gwen tone [list] | set BUNDLE TONE | clear BUNDLE", flush=True)
        return 2

    if args.cmd == "takes":
        from gwen.voice import takes as takes_mod
        action = (args.action or "list").strip().lower()
        if action == "clear":
            takes_mod.clear()
            print("cleared ~/.gwen/voice/takes.json", flush=True)
            return 0
        if action.isdigit():
            t = takes_mod.get(int(action))
            if not t:
                print("no take #%s" % action, flush=True)
                return 1
            print(t["text"], flush=True)
            return 0
        lst = takes_mod.list_takes()
        if not lst:
            print("No takes yet. Dictate something, then: gwen takes", flush=True)
            return 0
        for i, t in enumerate(lst, 1):
            preview = " ".join(t["text"].split())
            if len(preview) > 72:
                preview = preview[:69] + "…"
            lang = (" [%s]" % t["lang"]) if t.get("lang") else ""
            print("%2d.%s %s" % (i, lang, preview), flush=True)
        print("", flush=True)
        print("Paste again in the HUD: ⌃⌘V or Menu → Recent takes. Show one: gwen takes N", flush=True)
        return 0

    if args.cmd == "mock":
        if not args.name:
            print("Gwen mocks:", flush=True)
            print("", flush=True)
            for name in mock_mod.list_mocks():
                summary, status = mock_mod.MOCKS[name]
                print("  %-12s [%s] %s" % (name, status, summary), flush=True)
            print("", flush=True)
            print("Run: gwen mock … | takes | tone", flush=True)
            print("HUD:  gwen hud | gwen build | gwen settings | gwen install | gwen bundle", flush=True)
            print("Mic:  gwen setup && gwen listen", flush=True)
            print("Docs: docs/inventory.md, docs/extraction-plan.md, docs/blockers.md", flush=True)
            return 0
        rest = [a for a in (args.args or []) if a != "--"]
        return mock_mod.run(args.name, rest)
    p.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
