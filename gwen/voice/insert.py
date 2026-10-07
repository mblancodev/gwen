"""Intelligent insert rules (mirrors macapp/Insert.swift). Used by `gwen mock insert`."""
from __future__ import annotations

import re

_SENT_END = set(".?!…")
_CLOSERS = set("\"'”»)]}›")
_OPENERS = set("\"'“«([{‹¿¡")
_LEAD_PUNCT = set(",.;:!?…)]}”»\"'")
_CLASH = set(".…,;:")


def smart_insert(text: str, before: str = "", after: str = "") -> str:
    if not text:
        return text
    body = _trim_edge_spaces(text)
    if not body:
        return ""
    body = _strip_clash(body, before)
    if _sentence_start(before):
        body = _cap_first(body)
    elif _mid_sentence(before):
        body = _lower_first_word(body)
    out = ""
    if _need_lead(before, body):
        out += " "
    out += body
    if _need_trail(body, after):
        out += " "
    return out


def _sentence_start(before: str) -> bool:
    t = before.rstrip(" \t")
    if not t.strip():
        return True
    if before.endswith("\n") or before.endswith("\r"):
        return True
    if all(ch in _OPENERS or ch in " \t" for ch in t):
        return True
    i = len(t)
    while i > 0:
        ch = t[i - 1]
        if ch in " \t" or ch in _CLOSERS:
            i -= 1
            continue
        return ch in _SENT_END
    return True


def _mid_sentence(before: str) -> bool:
    return (not _sentence_start(before)) and any(c.isalnum() for c in before)


def _need_lead(before: str, body: str) -> bool:
    if not before or not body:
        return False
    last, first = before[-1], body[0]
    if last in " \t\n\r":
        return False
    if first in _LEAD_PUNCT or first in _OPENERS:
        return False
    if last in _OPENERS:
        return False
    return last.isalnum() or last in _CLOSERS


def _need_trail(body: str, after: str) -> bool:
    if not after or not body:
        return False
    first, last = after[0], body[-1]
    if first in " \t\n\r" or first in _LEAD_PUNCT:
        return False
    if last in _OPENERS:
        return False
    return first.isalnum()


def _strip_clash(body: str, before: str) -> str:
    tip = before.rstrip()
    if not tip or not body:
        return body
    if tip[-1] in _CLASH and body[0] in _CLASH:
        return body[1:].lstrip(" \t")
    return body


def _cap_first(s: str) -> str:
    for i, ch in enumerate(s):
        if ch.isalpha():
            return s[:i] + ch.upper() + s[i + 1 :]
    return s


def _lower_first_word(s: str) -> str:
    m = re.search(r"[A-Za-zÀ-ÿ]", s)
    if not m:
        return s
    i = m.start()
    j = i
    while j < len(s) and s[j].isalpha():
        j += 1
    word = s[i:j]
    if word == "I" or (len(word) >= 2 and word.isupper()):
        return s
    return s[:i] + s[i].lower() + s[i + 1 :]


def _trim_edge_spaces(s: str) -> str:
    return s.strip(" \t")


CASES = [
    # (before, text, after, expect)
    ("", "hello there", "", "Hello there"),
    ("Hi. ", "hello there", "", "Hello there"),
    ("Hi.", "hello", "", "Hello"),
    ("Hello ", "World", "", "world"),
    ("Hello", "world", "", " world"),
    ("Hello ", "world", "there", "world "),
    ("Hello ", "world", " there", "world"),
    ("Hello ", ", she said", "", ", she said"),
    ("done.", ". And then", "", "And then"),
    ("(", "hello", ")", "Hello"),
    ("AI ", "MODELS", "", "MODELS"),
    ("Say ", "I am here", "", "I am here"),
]
