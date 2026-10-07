"""Thin Gwen listener: mic → whisper → punctuate → paste. No jobs."""
from __future__ import annotations

import os
import signal
import sys
import threading
import time

from gwen import hud as hud_mod
from gwen.voice import config as cfg_mod
from gwen.voice.audio import (
    DICTATION_END, EndOfSpeech, FifoMic, FfmpegMic, Segmenter, bar_level, read_frame, rms, stalled, stt_up,
)
from gwen.voice.bridge import Hud
from gwen.voice.dictation import last_language, live_text, polish, transcribe_dictation
from gwen.voice.learn import dictated_line, fixed, keep, learn, prune
from gwen.voice.paths import FIFO, HOME
from gwen.voice.wake import gwen_heard, strip_gwen


def run(source: str | None = None, ensure_stt: bool = True, wake: bool = True) -> int:
    cfg = cfg_mod.load()
    if not hud_mod.ensure_hud():
        print("gwen listen: could not build Gwen.app", flush=True)
        return 1
    if not source and ensure_stt:
        from gwen.setup.voice import ensure_voice, stop_whisper
        if not ensure_voice(start=True):
            print("gwen listen: Whisper did not start. Try: gwen setup", flush=True)
            return 1
    elif not source and not stt_up():
        print("gwen listen: whisper server not reachable at 127.0.0.1:2022", flush=True)
        print("Run: gwen setup   (or omit --no-whisper)", flush=True)
        return 1

    os.makedirs(HOME, exist_ok=True)
    prune()
    hud = Hud(hud_mod.HUD_BIN)
    st = {
        "paused": False, "dictating": False, "buf": [], "free": None, "mic": None,
        "mic_failed": threading.Event(), "fifo_off": False, "dictation_gen": 0,
        "cancel_gen": 0, "last_pcm": None, "wake_prev": "", "wake_on": False,
        "target_bundle": "", "spoken": last_language(),
    }
    seg = Segmenter()
    stop = threading.Event()

    def send(line: str):
        hud.send(line)

    def stop_mic():
        if st["mic"]:
            try:
                st["mic"].terminate()
            except Exception:
                pass
            st["mic"] = None

    def open_mic():
        stop_mic()
        if source:
            from gwen.voice.audio import wave
            # reuse WavMic pattern via ffmpeg file? use FfmpegMic only for live
            print("gwen listen: --source not wired yet; use live mic", flush=True)
            return None
        st["mic_failed"].clear()
        try:
            return FifoMic(send, path=FIFO, failed=st["mic_failed"],
                           plain=None if cfg.get("mic") == "default" and not st["fifo_off"] else cfg.get("mic", "default"))
        except OSError as e:
            print("gwen listen: HUD mic failed (%s); trying ffmpeg" % e, flush=True)
            st["fifo_off"] = True
            try:
                return FfmpegMic(":0")
            except OSError as e2:
                print("gwen listen: ffmpeg mic failed: %s" % e2, flush=True)
                time.sleep(2)
                return None

    def start_dictation(free: bool, voice: bool = False):
        st["dictation_gen"] = st.get("dictation_gen", 0) + 1
        st.update(dictating=True, buf=seg.handoff(), free=EndOfSpeech(seg, DICTATION_END) if free else None,
                  voice_gen=st["dictation_gen"] if voice else None)
        hud.set("dictating")

    def cancel_dictation():
        if not st["dictating"]:
            return
        st.update(dictating=False, free=None, buf=[])
        hud.set("idle")

    def end_dictation():
        free, pcm = st["free"], b"".join(st["buf"])
        gen = st.setdefault("dictation_gen", 0)
        st.update(dictating=False, free=None)
        if free and not free.spoke:
            return hud.set("idle")
        st["last_pcm"] = pcm
        threading.Thread(target=finish_dictation, args=(pcm, gen), daemon=True).start()

    def finish_dictation(pcm, gen):
        if not pcm:
            return hud.set("idle")
        hud.set("cleaning")
        cfg.update(cfg_mod.load())  # Settings changed since we started: this take already follows it
        live = lambda: st.get("dictation_gen") == gen and st.get("cancel_gen", 0) == st.get("cancel_at_start", 0)
        st["cancel_at_start"] = st.get("cancel_gen", 0)
        text, path, lang = transcribe_dictation(pcm, live=live)
        if lang:
            st["spoken"] = lang
        if st.get("dictation_gen") != gen or st.get("cancel_gen", 0) != st.get("cancel_at_start", 0):
            return
        if text is None:
            hud.set("idle")
            if path:
                send("guide Couldn't reach speech to text. Recording kept.")
            return
        if st.get("voice_gen") == gen:
            text = strip_gwen(text)
        text, _how = polish(text, cfg, heard=lang, bundle=st.get("target_bundle") or None)
        if not text.strip():
            return hud.set("idle")
        send(dictated_line(text, cfg))
        # The HUD pastes and goes idle by itself and never says so: our side is done cleaning now, or it stays
        # "cleaning" forever and every later hold is ignored.
        hud.state = "idle"

    def on_events():
        for ev in hud.events():
            if stop.is_set():
                break
            idle = (not st["paused"] and not st["dictating"] and hud.state != "cleaning")
            if ev in ("dictate hold", "dictate free") and idle:
                start_dictation(ev == "dictate free")
            elif ev in ("dictate release", "dictate end") and st["dictating"] and (ev == "dictate end" or not st["free"]):
                end_dictation()
            elif ev.startswith("target "):
                st["target_bundle"] = ev[7:].strip()
            elif ev in ("cancel", "dictate cancel"):
                st["cancel_gen"] = st.get("cancel_gen", 0) + 1
                cancel_dictation()
            elif ev == "pause":
                st["paused"] = True
                stop_mic()
                hud.set("paused")
            elif ev == "resume":
                st["paused"] = False
                hud.set("idle")
            elif ev.startswith("compose fixed "):
                pair = fixed(ev[len("compose fixed "):])
                if pair:
                    _, word = learn(pair[0], pair[1])
                    if cfg.get("keep_corrected") and st.get("last_pcm"):
                        keep(st["last_pcm"], pair[0], pair[1])
                    if word:
                        send("learned " + word)
            elif ev.startswith("said "):
                text = ev[5:]
                # Live words come from a recognizer set to one language; when the last take was in another they
                # are garble, so the bar shows only the wave until the final text.
                if st["dictating"] and st["spoken"] in (None, "en"):
                    send("live " + live_text(text, dictating=True, bundle=st.get("target_bundle") or None))
            elif ev.startswith("heard "):  # heard <task> <text>: everything the recognizer writes, idle too
                text = ev.split(" ", 2)[2] if ev.count(" ") >= 2 else ""
                if idle and wake and st.get("wake_on") and gwen_heard(st.get("wake_prev", ""), text):
                    send("woke")  # a small sound: it landed, start talking
                    start_dictation(True, voice=True)
                st["wake_prev"] = text
            elif ev.startswith("input "):  # the menu's Microphone: saved by Gwen.app; reopen with it
                cfg["mic"] = ev[6:].strip() or "default"
                stop_mic()
            elif ev == "wake on":
                st["wake_on"] = True
            elif ev == "wake off":
                st["wake_on"] = False
            elif ev == "ready":
                send("visible on" if cfg.get("hud_visible") else "visible off")
            elif ev == "quit":
                stop.set()
                break
            elif ev.startswith("mic error"):
                st["mic_failed"].set()
                st["fifo_off"] = True
                stop_mic()

    def on_term(*_):
        stop.set()
        stop_mic()
        hud.close()
        os._exit(0)

    signal.signal(signal.SIGTERM, on_term)
    threading.Thread(target=on_events, daemon=True).start()
    time.sleep(0.4)
    send("ready")  # HUD also emits ready; harmless

    print("gwen listen: hold ⌃ to dictate, ⌃⌃ or Hey Gwen for hands-free. Ctrl-C to quit.", flush=True)
    try:
        while not stop.is_set():
            if st["paused"]:
                time.sleep(0.2)
                continue
            if not st["mic"]:
                st["mic"] = open_mic()
                if not st["mic"]:
                    continue
            stream = st["mic"].stdout
            if stalled(stream, idle=lambda: st["paused"] or st["dictating"]):
                stop_mic()
                continue
            frame = read_frame(stream)
            if not frame:
                stop_mic()
                continue
            level = rms(frame)
            if st["dictating"]:
                st["buf"].append(frame)
                send("level %.2f" % bar_level(level))
                if st["free"] and st["free"].feed(frame):
                    end_dictation()
            else:
                seg.feed(frame)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        stop_mic()
        hud.close()
        # Whisper stays up on :2022 for the next session (stop with: gwen setup --stop).
    return 0


def main(argv=None, wake: bool = True, ensure_stt: bool = True):
    """CLI entry. wake/ensure_stt from gwen listen flags."""
    argv = list(sys.argv[1:] if argv is None else argv)
    source = None
    if "--source" in argv:
        i = argv.index("--source")
        source = argv[i + 1] if i + 1 < len(argv) else None
    return run(source, ensure_stt=ensure_stt, wake=wake)
