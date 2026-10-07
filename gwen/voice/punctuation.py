"""Local dictation punctuation: spoken commands, sentence ends, Spanish ¿¡. Marks only; never logs text."""
import re

from gwen.voice.punctuation_words import ABBREV, COMMANDS, DETERMINERS, DOS_PUNTOS, HINTS, WORDS
from gwen.voice.small_marks import small

CMD_RE = re.compile(r"(?<![\w'])(?:%s)(?![\w'])" % "|".join("(?P<c%d>%s)" % (i, p) for i, (p, _) in enumerate(COMMANDS)),
                    re.I)
SPLIT_RE = re.compile(r"([.?!…]+[\"')\]»”]*)([ \t]+)(?=\S)|([ \t]*\n\s*)")
QUOTED_RE = re.compile(r"[\"“”«»()\[\]]")  # a quotation or an aside already there: its sentence keeps its marks
AFTER_RE = re.compile(r"[ \t]*([,.;:?!]*)[ \t]*")  # the mark Whisper wrote right after a command's words
AFTER_Q_RE = re.compile(r"[ \t]*([,.;:?!]*)[\"“”«»]?([,.;:?!]*)[ \t]*")  # and its own quote, after a spoken one


def language(text):
    """"en", "es" or None: a guess from a few words only one of them uses, until Whisper says which (P2). No guess,
    no rules."""
    words = re.findall(r"[\w']+", (text or "").lower())
    en = sum(w in HINTS["en"] for w in words)
    es = sum(w in HINTS["es"] for w in words) + bool(re.search(r"[ñ¿¡áéíóú]", text or "", re.I))
    for lang, a, b in (("en", en, es), ("es", es, en)):
        if a >= 2 and a >= 2 * b or a == 1 and b == 0 and len(words) <= 6:
            return lang
    return None


def punctuate(text, lang, hints=None):
    """The marks the way you spoke: the spoken commands first (final), then per sentence the marks inside it, its
    end, a quotation, and in Spanish the opening ¿ ¡. `lang` "en" or "es" (another, or None: the commands only).
    `hints` (P3, the voice) may say how each sentence ends: {"ends": ["question" | "exclamation" | "trailing" |
    None, …]}, one per sentence. A text no rule touches comes back byte for byte."""
    if not text or not text.strip():
        return text
    out = small(spoken(text, lang), lang)
    if lang not in WORDS:
        return out
    parts, ends = sentences(out), (hints or {}).get("ends") or []
    done = [_sentence(s, lang, ends[i] if i < len(ends) else None, i == len(parts) - 1) + sep
            for i, (s, sep) in enumerate(parts)]
    return "".join(done)


# --- spoken commands ---------------------------------------------------------------------------------------------

def spoken(text, lang=None):
    """The spoken commands with more than one word ("new paragraph", "quote … end quote", "dos puntos"), removed and
    turned into their marks. Final: nothing later undoes them. Both languages' commands, whatever `lang` says."""
    taken = _commands(text or "")
    if not taken:
        return text
    out, pos, cap_next = "", 0, False
    for start, end, kind in taken:
        chunk = text[pos:start]
        if cap_next and re.search(r"\w", chunk):
            chunk, cap_next = _cap(chunk), False
        after = (AFTER_Q_RE if kind[0] == "q" else AFTER_RE).match(text[end:])
        out, glue, cap = _command((out + chunk).rstrip(" \t"), kind, "".join(after.groups()), lang)
        pos, cap_next = end + after.end(), cap_next or cap
        if glue and pos < len(text) and re.match(r"[\w¿¡\"(\[]", text[pos]):
            out += " "
    rest = text[pos:]
    return (out + (_cap(rest) if cap_next else rest)).strip(" \t\n")


def _commands(text):
    """-> [(start, end, kind)] of the commands taken: none right after "a/the/un/la" ("a new line"), "dos puntos"
    only where it can't be "two points", and the one-word halves of a pair only with their other half."""
    found = []
    for m in CMD_RE.finditer(text):
        kind = COMMANDS[int(m.lastgroup[1:])][1]
        before, after = text[:m.start()].split(), text[m.end():].split()
        prev = _norm(before[-1]) if before and not re.search(r"[.,;:?!]$", before[-1]) else ""
        nxt = _norm(after[0]) if after else ""
        if prev in DETERMINERS and not kind.endswith("_open?"):  # a pair's opener has its other half as proof
            continue
        if kind == ":" and (not before or not nxt or prev in DOS_PUNTOS["before"] or nxt in DOS_PUNTOS["after"]):
            continue
        found.append((m.start(), m.end(), kind))
    keep = [f for f in found if not f[2].endswith("?")]
    for family, closers in (("q", ("q_close", "q_close?")), ("p", ("p_close",))):
        fam = [f for f in found if f[2][0] == family]
        for a, b in zip(fam, fam[1:]):
            said_between = re.search(r"\w", text[a[1]:b[0]])  # "quote unquote" is an idiom: words
            if a[2].endswith("_open?") and b[2] in closers and said_between:
                keep += [a, b]
            elif a[2] == "q_open" and b[2] == "q_close?" and said_between:
                keep.append(b)
    return sorted(set(keep))


def _command(left, kind, after, lang):
    """The text up to a command, with the command's mark -> (that text, a space before the next word?, capitalize
    the next word?). `after` is the mark Whisper wrote right after the command's words: its guess, mostly dropped."""
    if kind[0] == "q" and len(QUOTED_RE.findall(left)) % 2:  # Whisper opened a quote of its own right here: one mark
        left = re.sub(r"[ \t]*[\"“«]$", "", left)
    tail = re.search(r"[,.;:?!]*$", left).group()
    t, last = WORDS.get(lang), _norm(left.split()[-1]) if left.split() else ""
    reported = bool(t) and last in t["say"] | t["ask"]
    if kind in ("q_open", "q_open?") and reported and not tail:
        left += "," if lang == "en" else ":"  # he said quote … -> He said, "…"
    if kind in ("q_open", "q_open?", "p_open", "p_open?", "b_open"):  # a capital where a quotation starts, not "a "so-called" one"
        cap = kind[0] == "q" and (not left or left[-1] in ".?!:\n" or reported)
        return left + (" " if left and left[-1] != "\n" else "") + {"q": '"', "p": "(", "b": "["}[kind[0]], False, cap
    if kind in ("q_close", "q_close?", "p_close", "b_close"):
        base, marks = left[:len(left) - len(tail)], tail + after
        mk = next((c for c in "?!.," if c in marks), "")
        if kind[0] in "pb":  # the aside's own mark goes; the sentence's, said after it, stays outside
            return base + (")" if kind[0] == "p" else "]") + (after[:1] if after else ""), True, after[:1] == "."
        if mk in ("?", "!") or lang != "es":  # English puts the period inside, Spanish outside
            return base + mk + '"', True, mk in (".", "?", "!")
        return base + '"' + mk, True, mk == "."
    if kind == "para":
        if left and not re.search(r"[.?!…][\"')\]]*$", left):
            left = left.rstrip(",;:") + "."
        return left + ("\n\n" if left else ""), False, True
    if kind == "stop_para":  # "punto y aparte": a period and a new paragraph
        left = left.rstrip(",.;:")
        return (left + ("" if left.endswith(("?", "!")) else ".") + "\n\n") if left else "", False, True
    if kind == "line":
        left = left.rstrip(",")
        return left + ("\n" if left else ""), False, bool(re.search(r"[.?!][\"')]*$", left))
    return left.rstrip(",.;:") + kind, True, False  # ":" ";" "..."


# --- sentences ---------------------------------------------------------------------------------------------------

def sentences(text):
    """-> [(sentence, the spacing after it)]: the text cut after each end mark and at line breaks, nothing lost
    ("".join gives the text back). Not after "e.g.", "Mr." or a single letter."""
    out, start = [], 0
    for m in SPLIT_RE.finditer(text):
        if m.group(1):
            before = text[start:m.start()].split()
            word = before[-1].lower().strip("(\"'¿¡") if before else ""
            if m.group(1) == "." and (word in ABBREV or re.fullmatch(r"[^\W\d_]", word)):
                continue
            out.append((text[start:m.end(1)], m.group(2)))
        else:
            out.append((text[start:m.start()], m.group(3)))
        start = m.end()
    out.append((text[start:], ""))
    return out


def _sentence(s, lang, hint, last):
    if not re.search(r"\w", s):
        return s
    if QUOTED_RE.search(s):
        return _inverted(s, lang)
    m = re.search(r"[.?!…]*$", s)
    body, mark = s[:m.start()], m.group()
    if not re.search(r"\w", body):
        return s
    body = inside(body, lang)
    q = _quote_at(body, lang)
    end = _end(sentence_kind(body if q is None else q[2], lang), mark, hint, last)
    if end == "." and mark == "?":  # an embedded question: Whisper's ¿ goes with its ?
        body = body.replace("¿", "")
    out = body + end
    return _inverted(quotes(out, lang) if q else out, lang)


def _end(kind, mark, hint, last):
    """The sentence's final mark. Wording decides ? (and takes Whisper's ? off an embedded question); the rare ones
    need a second signal: ... where Whisper ended the sentence (or the dictation ended) on a word that can't end one,
    ! where the voice (hint) agrees. "Can't tell" keeps Whisper's mark. One !, never !! or ?!."""
    if len(mark) > 1 and mark not in ("...", "…"):
        mark = "?" if "?" in mark else "!" if "!" in mark else "..." if len(mark) > 3 else "."
    if kind == "question":
        return "?" if mark in ("", ".") else mark
    if kind == "statement":
        return "." if mark == "?" else mark
    if kind == "trailing" and (mark == "." or mark == "" and last or hint == "trailing" and mark == ""):
        return "..."
    if kind == "exclamation" and hint == "exclamation" and mark in ("", "."):
        return "!"
    if kind is None and hint == "question" and mark in ("", "."):  # P3: the voice is the only signal for "¿Vienes?"
        return "?"
    return mark


def sentence_kind(sentence, lang):
    """-> "question", "exclamation", "trailing", "statement" or None: what the wording alone says about how the
    sentence ends. "statement" only when the wording says so (an embedded question: "I wonder what…", "dime cómo…");
    None is "can't tell", and Whisper's mark stays."""
    t = WORDS.get(lang)
    r, w = _tokens(sentence)
    if not t or not w:
        return None
    s = _skip(w, t)
    if tuple(w) in t["interj"] or _exclaims(w, t, lang) or _exclaims(w[s:], t, lang):
        return "exclamation"
    k = _phrase(w, r, s, t["embed"])
    if k and s + k < len(w) and w[s + k] in t["embed_wh"] and _free(r, s + k - 1):
        return "statement"
    c = next((i + 1 for i in range(len(r) - 2, -1, -1) if r[i].endswith(",")), None)  # the clause after the last comma
    if c is not None and tuple(w[c:]) in t["tags"]:
        return "question"
    for start in dict.fromkeys(x for x in (0, s, c) if x is not None):
        if _asks(w[start:], t, lang, c is not None):
            return "question"
    if c is not None and _exclaims(w[c:], t, lang):
        return "exclamation"
    if len(w) >= 2 and (tuple(w[-2:]) in t["trail"] or (w[-1],) in t["trail"]
                        and w[-2] not in t["trail_guard"].get(w[-1], ())):
        return "trailing"
    return None


def _asks(w, t, lang, comma):
    """The words open a question: a question word ("qué", "¿a qué hora…"), or in English an inverted verb ("do you",
    "can we") or a question word, an auxiliary and its subject ("what time is it", not "when I was young")."""
    if not w:
        return False
    if any(tuple(w[:n]) in t.get("wh_phrase", ()) for n in (2, 3)):
        return True
    if lang == "es":
        i = 1 if w[0] in t["preps"] and len(w) > 1 else 0
        return w[i] in t["wh"] and not (w[i] == "qué" and _que_exclaims(w[i:], t))
    a = w[0]
    if a in t["wh_short"]:
        return len(w) == 1 or w[1] not in t["wh_short_not"]
    if a in t["aux"]:
        return len(w) > 1 and not (a in t["aux_nocomma"] and comma) and w[1] in t["aux_pron"].get(a, t["subjects"])
    if a in t["wh"]:
        if a == "how" and len(w) > 2 and w[1] in t["how_many"]:  # "how many people are coming"
            return any(x in t["aux"] for x in w[2:5])
        for k in range(1, min(4, len(w) - 1)):
            if w[k] in t["pronouns"]:
                return False  # "what I mean is…", "when it is ready": a clause, not a question
            if w[k] in t["aux"]:
                return w[k + 1] in t["subjects"]
    return False


def _que_exclaims(w, t):
    return len(w) >= 2 and (w[1] in t["excl_words"] or any(x in t["excl_more"] for x in w[2:4]))


def _exclaims(w, t, lang):
    """"What a day", "how nice", "qué bueno", "qué día tan bonito"."""
    if not w:
        return False
    if lang == "es":
        return w[0] == "qué" and _que_exclaims(w, t)
    if w[0] == "what" and len(w) > 2 and w[1] in ("a", "an"):
        return True
    return w[0] == "how" and len(w) > 1 and w[1] in t["how_excl"] and not any(x in t["aux"] for x in w[2:4])


# --- inside a sentence -------------------------------------------------------------------------------------------

def inside(sentence, lang):
    """The sentence with the marks its wording asks for, only where it has none: a comma after an opener ("bueno,",
    "however,"), around a name after a greeting ("Hola, Marta,"), before "but"/"pero" joining two clauses; a colon
    after an announcement ("the following:"), with the commas of a list it counted ("these three: milk, eggs and
    bread"); a semicolon before a linking word between two clauses ("; however,")."""
    t = WORDS.get(lang)
    if not t or not sentence or QUOTED_RE.search(sentence):
        return sentence
    lead, parts, trail = _parts(sentence)
    r = parts[0::2]
    w = [_norm(x) for x in r]
    if len(w) < 2:
        return sentence
    for rule in (_openers, _greeting, _but, _announce, _link):
        rule(w, r, t)
    parts[0::2] = r
    return lead + "".join(parts) + trail


def _openers(w, r, t):
    for key, need in (("openers", None), ("openers_subj", t["subjects"]), ("openers_pron", t["pronouns"])):
        k = _phrase(w, r, 0, t[key])
        if k:
            break
    else:
        return
    name = " ".join(w[:k])
    if len(w) < k + 2 or not _free(r, k - 1) or need is not None and w[k] not in need:
        return
    if w[k] in t["opener_guard"].get(name, ()) or w[k + 1] in t["opener_guard2"].get(name, ()):
        return  # "however much", "however you like", "o sea que"
    r[k - 1] += ","


def _greeting(w, r, t):
    """"Hola Marta cómo estás" -> "Hola, Marta, cómo estás"; "Thanks Marta" -> "Thanks, Marta". A name is only
    taken after a greeting: at the start of a sentence every word has a capital, so "Marta come here" waits for the
    voice (the pause after a name)."""
    k = _phrase(w, r, 0, t["greet"])
    if not k or k >= len(w) or not _name(r[k]) or not _free(r, k - 1):
        return
    n = k + 1
    while n < len(w) and n < k + 3 and _name(r[n]) and _free(r, n - 1):
        n += 1
    r[k - 1] += ","
    if n < len(w) and _free(r, n - 1):
        r[n - 1] += ","


def _but(w, r, t):
    """", but" / ", pero" between two clauses: two words before it, two after, and in English a subject after it
    ("I wanted to go but I was sick"; not "nothing but the truth", "not red but blue")."""
    for i in range(1, len(w) - 2):
        if w[i] != t["but"] or not _free(r, i - 1) or _since(r, i) < 2 or w[i - 1] in t["but_guard"]:
            continue
        if t["but"] == "but" and w[i + 1] not in t["subjects"] | t["contractions"]:
            continue
        r[i - 1] += ","


def _announce(w, r, t):
    """A colon after what announces: "the following", "here's the plan", "lo siguiente", and ", for example" /
    ", por ejemplo" before a list. "These three", "tres cosas": only when that many words follow as a list, which
    then gets its commas too ("tres cosas: leche, huevos y pan"). One per sentence."""
    for i in range(len(w)):
        head, count, kind = _head(w, r, i, t)
        e = i + head
        if not head or len(w) - e < 2 or not _free(r, e - 1):
            continue
        rest = w[e:]
        if (count and len(rest) == count + 1 and rest[-2] in t["conj"] and not any(x in t["conj"] for x in rest[:-2])
                and all(_free(r, x) for x in range(e, len(w) - 1))):
            r[e - 1] += ":"
            for x in range(e, e + count - 2):
                r[x] += ","
            return
        listed = any(x in t["conj"] for x in rest) or any(x.endswith(",") for x in r[e:-1])
        if kind == "count" or rest[0] in t["verbish"] or rest[0] in t["time"]:
            continue  # "the following steps are", "the following day"
        if (kind == "list" and listed or kind == "clause" and len(rest) >= 3
                or kind == "example" and i and r[i - 1].endswith(",") and listed and len(rest) <= 8):
            r[e - 1] += ":"
            return


def _head(w, r, i, t):
    """-> (how many words announce at word i, the count they say or None, "list" | "count" | "clause" | "example"),
    or (0, None, None)."""
    for key, kind in (("announce_list", "list"), ("announce_clause", "clause"), ("announce_example", "example")):
        k = _phrase(w, r, i, t[key])
        if k:
            break
    else:
        k, kind = (1, "count") if w[i] in t["announce_demo"] else (0, "count")
    if kind in ("clause", "example"):
        return k, None, kind
    j, count = i + k, None
    if j < len(w) and _number(w[j], t) and (k == 0 or _free(r, j - 1)):
        count, j = _number(w[j], t), j + 1
    if count is None and kind == "count":
        return 0, None, None  # "these" alone announces nothing
    if j < len(w) and _free(r, j - 1) and (w[j] in t["announce_nouns"] or tuple(w[i:i + k]) in t["announce_any_noun"]
                                           and (t is WORDS["es"] or len(w[j]) > 3 and w[j].endswith("s")
                                                and w[j] not in t["verbish"])):
        j += 1
    elif k == 0:
        return 0, None, None  # a bare number only with its noun: "tres cosas"
    return j - i, count, kind


def _number(word, t):
    n = t["numbers"].get(word) or (int(word) if word.isdigit() and len(word) == 1 else None)
    return n if n and 2 <= n <= 6 else None


def _link(w, r, t):
    """"; however," / "; sin embargo," between two full clauses: two words since the last mark, not after "and",
    "the", "is"…, and a subject (or in Spanish a pronoun, "no", "ya") after it ("I think; therefore, I am"). "We
    therefore decided" and "do it however you like" stay as they are."""
    for i in range(1, len(w)):
        k = _phrase(w, r, i, t["link"])
        e = i + k
        if not k or len(w) - e < 2 or not _free(r, i - 1) or _since(r, i) < 2 or w[i - 1] in t["link_guard"]:
            continue
        if r[i][:1].isupper():  # Whisper started a sentence there and left its stop out: not ours to tie
            continue
        if w[e] not in t["subjects"] | t.get("contractions", frozenset()):
            continue
        name = " ".join(w[i:e])
        if w[e] in t["opener_guard"].get(name, ()) or w[e + 1] in t["opener_guard2"].get(name, ()):
            continue
        r[i - 1] += ";"
        if _free(r, e - 1):
            r[e - 1] += ","
        return


# --- quotations and Spanish ¿ ¡ ----------------------------------------------------------------------------------

def quotes(sentence, lang):
    """A reporting verb, then words that could stand alone, in double quotes: She said, "Let's go." / Juan dijo:
    "Voy a llegar tarde". Not after "that / que / if / si" (he said that he'd be late). One sentence, with its end
    mark: the quotation's ? and ! stay inside it; the period goes inside in English and outside in Spanish."""
    m = re.search(r"[.?!…]*$", sentence or "")
    body, mark = sentence[:m.start()], m.group()
    q = _quote_at(body, lang)
    if q is None:
        return sentence
    lead, parts, trail = _parts(body)
    r = parts[0::2]
    v, j = q[0], q[1]
    r[v] = r[v].rstrip(",") + ("," if lang == "en" else ":")
    r[j] = '"' + _cap(r[j])
    parts[0::2] = r
    end = '"' + mark if lang == "es" and mark in (".", "") else mark + '"'
    return lead + "".join(parts) + trail + end


def _quote_at(body, lang):
    """-> (the reporting word's index, the quotation's first word's index, the quotation's text) or None. English:
    "he/she/Marta said" and a first word that only direct speech starts with ("let's", "please", "okay"), or
    "asked" and an inverted question ("she asked are you coming"). Spanish: "dijo/preguntó" without "que/si" after
    it, since indirect speech in Spanish always has one ("me dijo voy tarde", not "dijo eso")."""
    t = WORDS.get(lang)
    if not t or not body or QUOTED_RE.search(body):
        return None
    r = _parts(body)[1][0::2]
    w = [_norm(x) for x in r]
    for i, x in enumerate(w):
        ask = x in t["ask"]
        if not ask and x not in t["say"]:
            continue
        j = i + 1
        if lang == "en":
            if ask and j < len(w) and w[j] in t["objects"] and _free(r, i):
                j += 1
            if not ask and not _reporter(w, r, i, t) or any(w[p] in t["sub_guard"] for p in (i - 1, i - 2) if p >= 0):
                continue
        else:
            p = i - 1 if i and w[i - 1] in t["clitics"] else i
            if p and w[p - 1] in t["sub_guard"]:
                continue
        if len(w) - j < 2 or not re.search(r"[\w',]$", r[j - 1]) or not re.match(r"\w", r[j]):
            continue
        if lang == "en":
            cue = w[j] not in t["indirect"] and (_asks(w[j:], t, lang, False) if ask else
                                                 w[j] in t["direct"] and w[j + 1] not in t["direct_not"])
        else:
            cue = w[j] not in t["not_direct"] and not {"que", "si"} & set(w[j:j + 3])
        if cue:
            return j - 1, j, " ".join(r[j:])
    return None


def _reporter(w, r, i, t):
    """Someone else said it (he, she, Marta, my mom), not you."""
    if i == 0:
        return False
    return (w[i - 1] in t["reporters"] or i >= 2 and w[i - 2] in t["reporter_det"]
            or _name(r[i - 1]) and w[i - 1] not in t["cap_stop"])


def _inverted(s, lang):
    """Spanish opens what it closes: ¿ before the question and ¡ before the exclamation, where it starts: after a
    vocative, an opener or a clause before it ("Marta, ¿vienes?", "Si llueve, ¿vamos?"), before a tag ("Vienes,
    ¿no?"), inside a quotation."""
    m = re.search(r"([?!])[\"')\]]*\.?$", s) if lang == "es" else None
    if not m:
        return s
    op = "¿" if m.group(1) == "?" else "¡"
    if op in s:
        return s
    o = s.rfind('"', 0, m.start())
    if s[m.end(1):m.end(1) + 1] == '"' and o >= 0:
        return s[:o + 1] + op + s[o + 1:]
    if QUOTED_RE.search(s[:m.start()]):
        return s  # a quotation or an aside before it: where the question starts isn't clear
    i = _ask_start(s[:m.start()])
    return s[:i] + op + s[i:]


def _ask_start(body):
    t = WORDS["es"]
    toks = [(x.start(), x.group()) for x in re.finditer(r"\S+", body)]
    w = [_norm(x) for _, x in toks]
    commas = [i + 1 for i, (_, x) in enumerate(toks[:-1]) if x.endswith(",")]
    if not toks or not commas or _opens(w, t):
        return toks[0][0] if toks else 0
    tail = w[commas[-1]:]
    if tuple(tail) in t["tags"] or _opens(tail, t):
        return toks[commas[-1]][0]
    head, f = w[:commas[0]], commas[0]
    greet = {x for p in t["greet"] for x in p}
    if (tuple(head) in t["openers"] or head[0] in t["subordinators"]
            or head[0] in t["opener_skip"] | greet and all(x in t["opener_skip"] | greet or _name(toks[n][1])
                                                            for n, x in enumerate(head[1:], 1))
            or len(head) == 1 and toks[f][1][:1].islower()):
        return toks[f][0]
    return toks[0][0]


def _opens(w, t):
    """The words open a question or an exclamation: "qué…", "a qué hora…"."""
    i = 1 if w and w[0] in t["preps"] and len(w) > 1 else 0
    return bool(w) and w[i] in t["wh"]


# --- helpers -----------------------------------------------------------------------------------------------------

def _norm(tok):
    return re.sub(r"^[^\w']+|[^\w']+$", "", tok.replace("\u2019", "'")).lower()


def _cap(s):
    m = re.search(r"[^\W\d_]", s)
    return s[:m.start()] + s[m.start()].upper() + s[m.end():] if m and not s[:m.start()].strip("¿¡\"'(«“ \t\n") else s


def _name(tok):
    """A name, as Whisper writes one: a capital and then lowercase letters."""
    return bool(re.fullmatch(r"[A-ZÁÉÍÓÚÑ][a-záéíóúñü]+", re.sub(r"[^\w]+$", "", tok)))


def _parts(text):
    """-> (leading space, [word, space, word, …], trailing space)."""
    stripped = text.strip()
    if not stripped:
        return text, [""], ""
    a = text.index(stripped[0])
    return text[:a], re.split(r"(\s+)", stripped), text[a + len(stripped):]


def _tokens(sentence):
    pairs = [(x, _norm(x)) for x in (sentence or "").split()]
    pairs = [(x, n) for x, n in pairs if n]
    return [x for x, _ in pairs], [n for _, n in pairs]


def _free(r, k):
    """No mark between word k and the next."""
    return 0 <= k < len(r) - 1 and bool(re.search(r"[\w']$", r[k])) and bool(re.match(r"[\w']", r[k + 1]))


def _since(r, i):
    """Words before word i since the last mark."""
    n = 0
    for x in reversed(r[:i]):
        if re.search(r"[^\w']$", x):
            break
        n += 1
    return n


def _skip(w, t):
    """Past "and", "so", "bueno"… at the start."""
    s = 0
    while s < len(w) - 1 and w[s] in t["opener_skip"]:
        s += 1
    return s


def _phrase(w, r, i, phrases):
    """How many words of one of `phrases` start at word i, the longest, with no mark between them; 0 for none."""
    for n in (5, 4, 3, 2, 1):
        if i + n <= len(w) and tuple(w[i:i + n]) in phrases and all(_free(r, x) for x in range(i, i + n - 1)):
            return n
    return 0
