"""Microphone frames, VAD segmentation, local whisper.cpp STT."""
from __future__ import annotations

import json
import math
import os
import re
import select
import stat
import subprocess
import tempfile
import threading
import time
import urllib.request
import wave
from array import array

from gwen.voice.paths import FIFO, HOME, STT_URL

RATE, FRAME = 16000, 480
FRAME_BYTES = FRAME * 2
PRE_ROLL, END_SILENCE, MAX_SEG = 10, 27, 667
DICTATION_END, FREE_WAIT = 67, 267
MIN_SPEECH = 8
STALL = 2.0


def wav_bytes(pcm: bytes) -> bytes:
    with tempfile.SpooledTemporaryFile() as f:
        w = wave.open(f, "wb")
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
        w.close()
        f.seek(0)
        return f.read()


def stt_up(url: str | None = None) -> bool:
    try:
        urllib.request.urlopen((url or STT_URL).rsplit("/v1", 1)[0] + "/health", timeout=3)
        return True
    except OSError:
        return False


def transcribe(pcm, prompt="Hey Gwen,", language="en", timeout=30, verbose=False, vad=None, url=None):
    boundary = "gwenform"
    fields = [("language", language), ("response_format", "verbose_json" if verbose else "json")]
    if verbose:
        fields += [("timestamp_granularities[]", "word"), ("timestamp_granularities[]", "segment")]
    if prompt:
        fields += [("prompt", prompt)]
    if vad is not None:
        fields += [("vad", "true" if vad else "false")]
    body = b"".join(
        ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode()
        for k, v in fields
    )
    body += (
        ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"s.wav\"\r\n"
         "Content-Type: audio/wav\r\n\r\n" % boundary).encode()
        + wav_bytes(pcm)
        + ("\r\n--%s--\r\n" % boundary).encode()
    )
    req = urllib.request.Request(
        url or STT_URL, data=body, headers={"Content-Type": "multipart/form-data; boundary=" + boundary}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        reply = json.loads(r.read())
    if verbose:
        return verbose_reply(reply)
    return _text(reply)


def apple_transcribe(pcm, language, timeout, verbose, app=None):
    from gwen import hud as hud_mod
    bin_path = app or hud_mod.HUD_BIN
    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        f.write(wav_bytes(pcm))
        f.flush()
        try:
            p = subprocess.run(
                [bin_path, "--transcribe", f.name] + ([] if language == "auto" else ["--locale", language]),
                capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL,
            )
        except subprocess.TimeoutExpired as e:
            raise OSError("speech to text took over %d s" % timeout) from e
    try:
        reply = json.loads((p.stdout.strip().splitlines() or ["{}"])[-1])
    except ValueError:
        reply = {}
    if p.returncode or not isinstance(reply, dict) or "error" in reply:
        raise OSError((reply.get("error") if isinstance(reply, dict) else None) or "speech to text failed")
    return verbose_reply(reply) if verbose else _text(reply)


def _text(reply):
    text = " ".join((reply.get("text") or "").split())
    return "" if re.fullmatch(r"[\[\(].*[\]\)]", text) else text


LANGS = {
    "english": "en", "spanish": "es", "french": "fr", "german": "de", "italian": "it",
    "portuguese": "pt", "catalan": "ca", "dutch": "nl", "russian": "ru", "japanese": "ja",
    "chinese": "zh", "korean": "ko",
}


def _lang(name):
    name = str(name or "").strip().lower()
    return LANGS.get(name, name if re.fullmatch(r"[a-z]{2}", name) else None)


def verbose_reply(reply):
    text = _text(reply)
    language = _lang(reply.get("language"))
    language_p = reply.get("language_probability") or reply.get("language_p")
    words = []
    for seg in reply.get("segments") or []:
        for w in seg.get("words") or []:
            word = (w.get("word") or w.get("text") or "").strip()
            if not word:
                continue
            words.append({"word": word, "start": w.get("start"), "end": w.get("end")})
    if not words:
        for w in reply.get("words") or []:
            word = (w.get("word") or w.get("text") or "").strip()
            if word:
                words.append({"word": word, "start": w.get("start"), "end": w.get("end")})
    return {"text": text, "language": language, "language_p": language_p, "words": words, "segments": reply.get("segments")}


def rms(frame):
    a = array("h", frame)
    return int(math.sqrt(sum(x * x for x in a) / len(a))) if a else 0


def bar_level(level, speech_rms=None):
    return min(1.0, math.sqrt(level / (2.0 * (speech_rms or 1500))))


class FifoMic:
    """HUD writes 16 kHz s16le frames into a FIFO; the listener reads them."""

    def __init__(self, send, path=FIFO, timeout=5.0, failed=None, plain=None):
        if os.path.lexists(path) and not stat.S_ISFIFO(os.lstat(path).st_mode):
            os.remove(path)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            os.mkfifo(path, 0o600)
        self.send, self.stdout, opened = send, None, {}
        t = threading.Thread(target=lambda: opened.setdefault("f", open(path, "rb")), daemon=True)
        t.start()
        send("mic plain %s\t%s" % (path, plain) if plain else "mic on " + path)
        deadline = time.time() + timeout
        while t.is_alive() and time.time() < deadline and not (failed and failed.is_set()):
            t.join(0.05)
        if t.is_alive() or (failed and failed.is_set()):
            try:
                os.close(os.open(path, os.O_WRONLY | os.O_NONBLOCK))
            except OSError:
                pass
            t.join(1)
            if opened.get("f"):
                opened["f"].close()
            send("mic off")
            raise OSError("Gwen.app did not open the microphone")
        self.stdout = opened["f"]

    def terminate(self):
        self.send("mic off")
        threading.Thread(target=self.stdout.close, daemon=True).start()


class FfmpegMic:
    """Fallback capture via ffmpeg avfoundation when HUD mic is unavailable."""

    def __init__(self, device=":0"):
        self.proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", device,
             "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.stdout = self.proc.stdout

    def terminate(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def stalled(stream, timeout=STALL, idle=lambda: False):
    try:
        ready = select.select([stream], [], [], timeout)[0]
    except (OSError, ValueError):
        return False
    return not ready and not idle()


def read_frame(stream):
    try:
        return stream.read(FRAME_BYTES)
    except ValueError:
        return b""


class Segmenter:
    def __init__(self, min_rms=300, ratio=3.0):
        self.floor, self.min_rms, self.ratio = 200.0, min_rms, ratio
        self.reset()

    def reset(self):
        self.pre, self.buf, self.voiced, self.silent = [], [], 0, 0

    def handoff(self):
        frames = self.buf or self.pre
        self.reset()
        return frames

    def feed(self, frame):
        level = rms(frame)
        speech = level > max(self.floor * self.ratio, self.min_rms)
        if not self.buf:
            if not speech:
                self.floor = 0.95 * self.floor + 0.05 * level
            self.pre = (self.pre + [frame])[-PRE_ROLL:]
            if speech:
                self.buf, self.voiced, self.silent = list(self.pre), 1, 0
            return None
        self.buf.append(frame)
        self.voiced += speech
        self.silent = 0 if speech else self.silent + 1
        if self.silent >= END_SILENCE or len(self.buf) >= MAX_SEG:
            seg, enough = b"".join(self.buf), self.voiced >= MIN_SPEECH
            self.buf, self.pre = [], []
            return seg if enough else None
        return None


class EndOfSpeech:
    def __init__(self, seg, quiet, wait=FREE_WAIT):
        self.seg, self.quiet, self.wait = seg, quiet, wait
        self.n = self.voiced = self.silent = 0

    @property
    def spoke(self):
        return self.voiced >= MIN_SPEECH

    def feed(self, frame):
        speech = rms(frame) > max(self.seg.floor * self.seg.ratio, self.seg.min_rms)
        self.n += 1
        self.voiced += speech
        self.silent = 0 if speech else self.silent + 1
        return self.silent >= self.quiet if self.spoke else self.n >= self.wait
