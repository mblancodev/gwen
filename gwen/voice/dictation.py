"""Transcribe cleanup: fillers, local punctuation, optional remote polish."""
from __future__ import annotations

import difflib
import json
import os
import re
import subprocess
import tempfile
import time
import unicodedata

from gwen.voice.audio import RATE, transcribe, wav_bytes
from gwen.voice.backtrack import backtrack
from gwen.voice.tone import apply_tone, resolve as resolve_tone
from gwen.voice.formatting import format_text
from gwen.voice.learn import spell_words
from gwen.voice.paths import LANG_FILE, VOICE_DIR
from gwen.voice.punctuation import language, punctuate, sentences, spoken
from gwen.voice.punctuation_words import WHISPER_PROMPTS, WORDS

FILLER_RE = re.compile(r"(?<![\w'])(u+m+|u+h+|e+h+|e+r+m+|a+h+|hm+|mhm|uh-huh)(?![\w'])[,.]?\s*", re.I)
POLISH_PROMPT = """Clean up this dictated text. Rules:
- Remove filler words (um, uh, eh, like, you know, I mean, o sea) ONLY where they are fillers, plus stutters,
  repeated words and false starts.
- Fix punctuation and spacing for the language the text is in.
- Keep every other word as spoken. Do NOT rephrase, reorder, summarize, translate, or add ideas.
- Output ONLY the cleaned text, nothing else.

Text:
"""


def last_language(path=None):
    try:
        with open(path or LANG_FILE) as f:
            lang = json.load(f).get("lang")
        return lang if isinstance(lang, str) and re.fullmatch(r"[a-z]{2}", lang) else None
    except (OSError, ValueError, AttributeError):
        return None


def remember_language(lang, path=None):
    path = path or LANG_FILE
    if not lang or lang == last_language(path):
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump({"lang": lang}, f)
        os.replace(tmp, path)
    except OSError:
        pass


def whisper_prompt(last, names=()):
    base = WHISPER_PROMPTS.get(last or "en")
    return "%s.\n%s" % (", ".join(names), base) if names and base else base


def transcribe_dictation(pcm, live=lambda: True, stt=transcribe, keep_dir=VOICE_DIR, wait=2.0, lang_file=None, names=()):
    timeout = max(30, len(pcm) / (2.0 * RATE) * 0.5)
    for attempt in (1, 2):
        try:
            got = stt(pcm, prompt=whisper_prompt(last_language(lang_file), names), language="auto",
                      timeout=timeout, verbose=True)
            if isinstance(got, str):
                return got, None, None
            p = got.get("language_p")
            lang = got.get("language") if not isinstance(p, (int, float)) or p >= 0.5 else None
            if lang and got.get("text"):
                remember_language(lang, lang_file)
            return got.get("text") or "", None, lang
        except OSError:
            pass
        if attempt == 1:
            time.sleep(wait)
        if not live():
            return None, None, None
    os.makedirs(keep_dir, exist_ok=True)
    path = os.path.join(keep_dir, "unsent-%d.wav" % time.time())
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
        f.write(wav_bytes(pcm))
    return None, path, None


def tidy_spacing(text):
    out = (text or "").replace("\xa0", " ").replace("…", "...")
    out = re.sub(r"[ \t]+", " ", out)
    out = re.sub(r" ?\n ?", "\n", out)
    out = re.sub(r"(?<=[^\W\d_]) ?[—–] ?(?=[^\W\d_])", " - ", out)
    out = re.sub(r" ([,.;:!?%])", r"\1", out)
    out = re.sub(r"([¿¡]) ", r"\1", out)
    out = re.sub(r"([(\[«“‘]) ", r"\1", out)
    out = re.sub(r" ([)\]»”’])", r"\1", out)
    out = re.sub(r"([;!?]|(?<!\d)[,:]|[,:](?!\d))(?=[^\s\"')\]»”’])", r"\1 ", out)
    out = re.sub(r"\.([A-Za-zÁÉÍÓÚÜáéíóúüÑñ¿¡])", r". \1", out)
    out = re.sub(r"([^\s\"'(\[«“‘])([¿¡])", r"\1 \2", out)
    return _straight_quotes(out).strip(" ,\t\n")


def _straight_quotes(text):
    n = text.count('"')
    if not n or n % 2:
        return text
    out, opening = [], True
    for i, piece in enumerate(text.split('"')):
        if i:
            if opening:
                before = out[-1].rstrip(" ")
                out[-1] = before + (" " if before[-1:] not in "(\n¿¡" or not before and len(out) > 1 else "")
                piece = piece.lstrip(" ")
            else:
                out[-1] = out[-1].rstrip(" ")
                piece = (" " if re.match(r"[\w¿¡(]", piece) else "") + piece
            out.append('"')
            opening = not opening
        out.append(piece)
    return "".join(out)


def cap(text):
    i = 0
    while i < len(text) and text[i] in "¿¡\"'«“(":
        i += 1
    return text[:i] + text[i].upper() + text[i + 1:] if i < len(text) else text


def strip_fillers(text):
    out = tidy_spacing(FILLER_RE.sub("", text))
    return cap(out) if out else out


def live_text(text, dictating=False, bundle=None):
    if resolve_tone(bundle) == "verbatim":
        out = backtrack(tidy_spacing(text or ""))
    else:
        out = backtrack(strip_fillers(text))
    if dictating and out and resolve_tone(bundle) != "verbatim":
        out = re.sub(r"\s*\n\s*", " ", punctuate(out, language(out)))
    return spell_words(out)


def words(text):
    return re.findall(r"[\w']+", text.lower())


def letters(text):
    s = unicodedata.normalize("NFKD", text or "").lower()
    return re.sub(r"[^a-z0-9]+", "", s)


def edges_kept(a, b):
    blocks = difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()[:-1]
    if not blocks:
        return False
    first, last = blocks[0], blocks[-1]
    ends = ((a[:first.a], b[:first.b], a[first.a:]),
            (a[last.a + last.size:], b[last.b + last.size:], a[:last.a + last.size][::-1]))
    filler = re.compile(r"(?:(?:u+m+|u+h+|e+h+|like|you know|i mean|o sea|so|well|okay|ok|pues|bueno"
                        r"|este)(?: |$))+")
    for gone, new, kept in ends:
        if new:
            if difflib.SequenceMatcher(None, letters("".join(gone)), letters("".join(new))).ratio() < 0.8:
                return False
        elif gone and not filler.fullmatch(" ".join(gone)) and gone != kept[:len(gone)] and gone[::-1] != kept[:len(gone)]:
            return False
    return True


def faithful(original, polished):
    a, b = words(original), words(polished)
    if not a or not b or len(b) > len(a) * 1.05 + 2 or len(b) < len(a) * 0.55 or not edges_kept(a, b):
        return False
    if difflib.SequenceMatcher(None, a, b).ratio() >= 0.85:
        return True
    la, lb = letters(original), letters(polished)
    return bool(la and lb) and difflib.SequenceMatcher(None, la, lb).ratio() >= 0.92


def polish(text, cfg, heard=None, stats=None, bundle=None):
    """Clean a take. bundle = frontmost app id → per-app tone (casual/formal/verbatim)."""
    tone = resolve_tone(bundle)
    if tone == "verbatim":
        # Terminals / shells: keep wording; only tidy, backtrack, learned spellings.
        out = spell_words(backtrack(tidy_spacing(text or "")))
        return out, "verbatim"
    out, how = _polish(text, cfg, heard, stats)
    if cfg.get("format_dictation"):
        out, kinds = format_text(out, heard if heard in WORDS else language(out))
        if stats is not None and kinds:
            stats["formatted"] = kinds
    out = apply_tone(out, tone)
    if tone != "default":
        how = ("%s+%s" % (how, tone)) if how else tone
    return out, how


def _polish(text, cfg, heard=None, stats=None):
    clean = strip_fillers(text)
    clean = backtrack(clean)
    lang = heard if heard in WORDS else None if heard else language(clean)
    base = punctuate(clean, lang)
    base = spell_words(base)
    t = cfg.get("transcribe") or {}
    agent, model = t.get("agent"), t.get("model")
    w = words(clean)
    if not t.get("polish") or not agent or len(w) < 4:
        return base, "rules"
    if clean == text.strip() and not any(x == y for x, y in zip(w, w[1:])) and len(sentences(base)) < 2:
        return base, "rules"
    prompt = POLISH_PROMPT + base
    # Minimal remote polish: Claude CLI only when polish is on. Falls back to rules.
    if agent != "claude":
        return base, "rules"
    cmd = ["claude", "-p", prompt, "--output-format", "json", "--max-budget-usd", "0.05",
           "--settings", '{"alwaysThinkingEnabled": false}',
           "--disallowedTools", "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task"]
    if model:
        cmd += ["--model", model]
    try:
        with tempfile.TemporaryDirectory() as empty:
            p = subprocess.run(cmd, cwd=empty, capture_output=True, text=True, timeout=45, stdin=subprocess.DEVNULL)
        try:
            res = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
        except ValueError:
            res = {}
        out = cap(tidy_spacing((res.get("result") or res.get("text") or "").strip().strip('"')))
        if p.returncode == 0 and out and faithful(base, out):
            return out, "claude"
    except (OSError, subprocess.TimeoutExpired):
        pass
    return base, "rules"
