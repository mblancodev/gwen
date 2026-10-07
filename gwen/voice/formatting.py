"""Optional dictation formatting: times, named emoji, counted lists. Off unless format_dictation is on."""
import re

LANGS = ("en", "es")

# "3.30pm" -> "3:30 pm", "9am" -> "9 am"; "a las 17.45" -> "a las 17:45". The digits are Whisper's, in its order.
TIMES = {
    "en": [(re.compile(r"(?<![\w.:,$])(1[0-2]|0?[1-9])\.([0-5]\d)[ \t]?([ap]\.?m\b)", re.I), r"\1:\2 \3"),
           (re.compile(r"(?<![\w.:,$])((?:1[0-2]|0?[1-9])(?::[0-5]\d)?)([ap]\.?m\b)", re.I), r"\1 \2")],
    "es": [(re.compile(r"(?<![\w'])((?:a )?las? )([01]?\d|2[0-3])\.([0-5]\d)(?!\d|[.,]\d)", re.I), r"\1\2:\3")],
}

# Only an emoji you named and asked for ("thumbs up emoji", "emoji de corazón"), never one guessed from the tone. A
# name that isn't here stays as words.
EMOJI = {
    "en": {"thumbs up": "👍", "thumbs down": "👎", "heart": "❤️", "red heart": "❤️", "smiley": "🙂", "smiling": "🙂",
           "smile": "🙂", "laughing": "😂", "crying": "😢", "sad": "🙁", "wink": "😉", "winking": "😉", "thinking": "🤔",
           "fire": "🔥", "party": "🎉", "clapping": "👏", "rocket": "🚀", "check mark": "✅", "eyes": "👀",
           "praying": "🙏", "folded hands": "🙏", "waving": "👋", "wave": "👋", "star": "⭐", "shrug": "🤷"},
    "es": {"pulgar arriba": "👍", "pulgar abajo": "👎", "corazón": "❤️", "sonrisa": "🙂", "carita feliz": "🙂",
           "risa": "😂", "llanto": "😢", "triste": "🙁", "carita triste": "🙁", "guiño": "😉", "pensando": "🤔",
           "fuego": "🔥", "fiesta": "🎉", "aplausos": "👏", "cohete": "🚀", "visto": "✅", "ojos": "👀",
           "manos juntas": "🙏", "saludo": "👋", "estrella": "⭐"},
}
_names = {lang: "|".join(sorted(map(re.escape, t), key=len, reverse=True)) for lang, t in EMOJI.items()}
EMOJI_RE = {
    "en": re.compile(r"(,?[ \t]*)(?<![\w'])(%s)(?:[ \t]+face)?[ \t]+emojis?(?![\w'])" % _names["en"], re.I),
    "es": re.compile(r"(,?[ \t]*)(?<![\w'])emojis?[ \t]+(?:del?[ \t]+|de[ \t]+la[ \t]+|con[ \t]+)?(%s)(?![\w'])" % _names["es"],
                     re.I),
}
AFTER_EMOJI = re.compile(r"((?:^|[.?!]\s+|\n)(?:(?:%s)\s*)+)([^\W\d_])" % "|".join(
    sorted({re.escape(e) for t in EMOJI.values() for e in t.values()})))

# A list you counted out: "first …, second …, third …", three or more in order, each after a mark. Not "first place
# went to …, second place …": the ordinal and the word after it are one thing there.
ORDINALS = {"en": "first second third fourth fifth sixth seventh eighth ninth tenth".split(),
            "es": "primero segundo tercero cuarto quinto sexto séptimo octavo noveno décimo".split()}
NOT_ITEM = {"en": frozenset("place time one of thing things step half part point floor prize is was and or".split()),
            "es": frozenset("lugar puesto piso de que es y o premio paso punto".split())}
# or said: "bullet … bullet …", "viñeta … viñeta …", two or more
BULLET = {"en": r"bullet(?:[ \t]+point)?|next[ \t]+item", "es": r"viñeta|siguiente[ \t]+punto"}
DETERMINERS = frozenset("a an the this that each every one my your un una el la los las este esta cada mi tu".split())


def same_values(original, formatted):
    """Every digit that came in went out, in the same order: a time may gain its colon, never another minute. The
    numbers a list's lines start with are the formatter's own and don't count."""
    digits = lambda s: re.sub(r"\D", "", s)  # noqa: E731
    return digits(original) == digits(re.sub(r"(?m)^\d+\. ", "", formatted))


def format_text(text, lang):
    """-> (the text, {"time" | "emoji" | "list": how many}). Each kind on its own, and one that fails same_values is
    undone alone, not the whole dictation. A language with no tables, or nothing to format: the text as it came."""
    counts = {}
    if not text or lang not in LANGS:
        return text, counts
    for kind, rule in (("time", _times), ("emoji", _emoji), ("list", _list)):
        out, n = rule(text, lang)
        if n and same_values(text, out):
            text, counts[kind] = out, n
    return text, counts


def _times(text, lang):
    total = 0
    for rx, to in TIMES[lang]:
        text, n = rx.subn(to, text)
        total += n
    return text, total


def _emoji(text, lang):
    table = EMOJI[lang]
    out, n = EMOJI_RE[lang].subn(lambda m: (" " if m.group(1) and m.start() else "") + table[m.group(2).lower()], text)
    return AFTER_EMOJI.sub(lambda m: m.group(1) + m.group(2).upper(), out) if n else text, n


def _list(text, lang):
    """One item per line. The last item runs to the end of the dictation; nothing says where a list
    stops. A spoken "end of list" if that turns out to bite."""
    lead, items = _counted(text, lang)
    mark = "%d. "
    if len(items) < 3:
        lead, items = _bulleted(text, lang)
        mark = "- "
        if len(items) < 2:
            return text, 0
    lines = []
    for i, item in enumerate(items, 1):
        item = item.strip().rstrip(",;")
        if not re.search(r"\w", item):
            return text, 0
        if not re.search(r"[.?!]\s", item):  # one sentence: a list line has no period
            item = item.rstrip(".")
        lines.append((mark % i if "%" in mark else mark) + item[:1].upper() + item[1:])
    lead = lead.rstrip()
    return (lead + "\n" if lead else "") + "\n".join(lines), 1


def _counted(text, lang):
    spans, pos = [], 0
    for i, word in enumerate(ORDINALS[lang]):
        before = r"(?:^|(?<=[.?!:]\s)|(?<=\n))" if i == 0 else r"[,.;:]?\s*\n\s*|[,.;:]\s+(?:(?:and|y)\s+)?"
        m = re.compile(r"(?:%s)%s\b,?\s+(\w+)" % (before, word), re.I).search(text, pos)
        if not m:
            break
        if m.group(1).lower() in NOT_ITEM[lang]:
            return "", []
        spans.append((m.start(), m.start(1)))
        pos = m.start(1)
    items = [text[b:spans[k + 1][0] if k + 1 < len(spans) else len(text)] for k, (_, b) in enumerate(spans)]
    return (text[:spans[0][0]], items) if spans else ("", [])


def _bulleted(text, lang):
    parts = re.split(r"(?:^|(?<=\s))[,.;:]?(?:%s)\b[,.:]?(?:\s+|$)" % BULLET[lang], text, flags=re.I)
    before = [re.findall(r"[\w']+", p)[-1:] for p in parts[:-1]]
    if any(w and w[0].lower() in DETERMINERS for w in before):  # "the next item on the agenda": words
        return "", []
    return parts[0], parts[1:]
