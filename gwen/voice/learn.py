"""Learned words from paste edits → ~/.gwen/voice/words.json."""
from __future__ import annotations

import collections
import difflib
import functools
import json
import os
import re
import time
import unicodedata

from gwen.voice.audio import wav_bytes
from gwen.voice.paths import CORRECTED, VOICE_DIR, WORDS

TOKEN_RE = re.compile(r"@\S*|\w+(?:['.-]\w+)*|\n+|[^\w\s]")
TWICE = 2
KEEP, KEEP_DAYS = 50, 30


def norm(text: str) -> str:
    s = unicodedata.normalize("NFKD", text or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def read_json(path: str) -> dict:
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _write(data: dict) -> None:
    os.makedirs(VOICE_DIR, exist_ok=True)
    with os.fdopen(os.open(WORDS + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(data, f, indent=2)
    os.replace(WORDS + ".tmp", WORDS)


@functools.lru_cache(maxsize=1)
def everyday():
    try:
        with open("/usr/share/dict/words") as f:
            return frozenset(w for w in f.read().split() if w.islower())
    except OSError:
        return frozenset()


def kind(a, b):
    la, lb = [w.lower() for w in a], [w.lower() for w in b]
    ja, jb = "".join(la), "".join(lb)
    if not a or not b:
        return "rewrite"
    if la == lb:
        return "capital"
    digits = [bool(re.fullmatch(r"[\d.,:/%-]+", x)) for x in (ja, jb)]
    if len(a) + len(b) <= 5 and any(digits) and not re.search(r"\d", (ja, jb)[digits[0]]):
        return "number"
    if ("'" in ja) != ("'" in jb) and ja[0] == jb[0] and len(a) <= 2 and len(b) <= 2:
        return "contraction"
    known = everyday()
    if (len(a) > 3 or len(b) > len(a) or len(norm(ja)) < 3 or not (ja + jb).isascii()
            or all(w in known or w.endswith("s") and w[:-1] in known for w in la + lb)
            or difflib.SequenceMatcher(None, norm(ja), norm(jb)).ratio() < 0.5):
        return "rewrite"
    return "spelling"


def tokens(text):
    return ["\n" if t[0] == "\n" else t for t in TOKEN_RE.findall((text or "").replace("\u2019", "'")) if t[0] != "@"]


def learn(heard, sent):
    a, b = tokens(heard), tokens(sent)
    ops = [o for o in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if o[0] != "equal"]
    data, marks, word = read_json(WORDS), collections.Counter(), None
    for _, i, j, k, m in ops:
        aw, bw = ([t for t in side if re.match(r"\w", t)] for side in (a[i:j], b[k:m]))
        am, bm = ([t for t in side if not re.match(r"\w", t)] for side in (a[i:j], b[k:m]))
        run = all(side[side.index(w[0]):len(side) - side[::-1].index(w[-1])] == w
                  for side, w in ((a[i:j], aw), (b[k:m], bw)) if w)
        what = None if aw == bw else kind(aw, bw) if run else "rewrite"
        if what != "rewrite":
            for way, changed in (("added", collections.Counter(bm) - collections.Counter(am)),
                                 ("removed", collections.Counter(am) - collections.Counter(bm))):
                for mark, n in changed.items():
                    counts = data.setdefault("marks", {}).setdefault(mark, {})
                    counts[way] = counts.get(way, 0) + n
                    marks[mark] += n
        if what == "spelling":
            key, to = norm("".join(aw)), " ".join(bw)
            was = data.setdefault("words", {}).get(key) or {}
            n = was.get("n", 0) + 1 if was.get("to") == to else 1
            data["words"][key] = {"heard": " ".join(aw), "to": to, "n": n}
            if n == TWICE:
                word = to
        elif what and what != "rewrite":
            data.setdefault("written", {})[what] = data.get("written", {}).get(what, 0) + 1
    if ops:
        _write(data)
    return {"edits": len(ops), "marks": dict(marks)}, word


def learned():
    return read_json(WORDS)


def forget(key):
    data = read_json(WORDS)
    if (data.get("words") or {}).pop(key, None) is None:
        return False
    _write(data)
    return True


def spell_words(text, rules=None):
    if rules is None:
        rules = {k: w["to"] for k, w in (read_json(WORDS).get("words") or {}).items() if w.get("n", 0) >= TWICE}
    parts = re.split(r"(\s+)", text or "")
    if not rules or not text:
        return text
    out, i = [], 0
    while i < len(parts):
        for j in range(min(len(parts) - 1, i + 4), i - 1, -2):
            if to := rules.get(norm("".join(parts[i:j + 1:2]))):
                out.append(re.match(r"\W*", parts[i]).group() + to + re.search(r"\W*$", parts[j]).group())
                break
        else:
            out.append(parts[i])
            j = i
        out.extend(parts[j + 1:j + 2])
        i = j + 2
    return "".join(out)


def dictated_line(text, cfg):
    return ("dictated " if cfg.get("learn_from_edits", True) else "insert ") + text


def fixed(raw):
    try:
        d = json.loads(raw)
        return (d["heard"], d["text"]) if isinstance(d["heard"], str) and isinstance(d["text"], str) else None
    except (ValueError, KeyError, TypeError):
        return None


def keep(pcm, heard, sent, now=None):
    os.makedirs(CORRECTED, exist_ok=True)
    stem = os.path.join(CORRECTED, "%d" % ((now or time.time()) * 1000))
    for ext, mode, body in ((".wav", "wb", wav_bytes(pcm)),
                            (".json", "w", json.dumps({"heard": heard, "sent": sent}))):
        with os.fdopen(os.open(stem + ext, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), mode) as f:
            f.write(body)
    prune(now)


def prune(now=None):
    names = sorted(os.listdir(CORRECTED), reverse=True) if os.path.isdir(CORRECTED) else []
    stems = sorted({n.split(".")[0] for n in names}, key=lambda n: int(n) if n.isdigit() else 0, reverse=True)
    old = ((now or time.time()) - KEEP_DAYS * 86400) * 1000
    gone = {n for i, n in enumerate(stems) if i >= KEEP or not n.isdigit() or int(n) < old}
    for name in names:
        if name.split(".")[0] in gone:
            os.remove(os.path.join(CORRECTED, name))
