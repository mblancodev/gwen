"""Small mark fixes: slash pairs, contractions, a few compounds."""
import re

# "and slash or" -> "and/or". The word between is the command: it goes, like any spoken mark.
PAIRS = {"en": "and or|either or|he she|him her|his her|she he|yes no|true false|on off|input output|read write|"
               "client server|pass fail|before after|mom dad",
         "es": "y o|él ella|sí no|entrada salida"}
SLASH = {lang: re.compile(r"(?<![\w'/])(%s)[ \t]+%s[ \t]+(%s)(?![\w'/])" % (
    "|".join(p.split()[0] for p in pairs.split("|")), word, "|".join(p.split()[1] for p in pairs.split("|"))), re.I)
    for (lang, pairs), word in zip(PAIRS.items(), ("slash", "barra"))}
NUM_SLASH = re.compile(r"(?<![\w/.,])(\d+)[ \t]+(?:slash|barra)[ \t]+(\d+)(?![\w/])", re.I)  # "50 slash 50"
AND_OR = re.compile(r"(?<![\w'/])(and)[ \t]+(or)(?![\w'/])", re.I)  # said without the "slash" too; not "y o (sea)"

# A contraction Whisper wrote without its apostrophe. Not "its", "lets", "were", "well", "wont", "ill", "id", "hell",
# "shell": words of their own.
APOS = {w.replace("'", "").lower(): w for w in (
    "don't doesn't didn't isn't aren't wasn't weren't haven't hasn't hadn't wouldn't couldn't shouldn't can't ain't "
    "I'm I've you're they're you've they've we've you'll they'll that's what's there's here's would've could've "
    "should've").split()}
APOS_RE = re.compile(r"(?<![\w'’-])(%s)(?![\w'’-])" % "|".join(APOS), re.I)

# Compounds that take a hyphen before a noun: after "a/an" and before a word that can be one ("a long-term plan",
BEFORE_NOUN = ("well known|long term|short term|real time|full time|part time|high level|low level|open source|"
               "high quality|last minute|end to end|up to date|state of the art|step by step|one on one|"
               "face to face|day to day")
NOT_NOUN = ("is are was were will can should would has had do does did be been am that of for in about to with and "
            "or on at by from it you i we he she they but so if when than as")
COMPOUND = re.compile(r"(?<![\w'])(an?[ \t]+)(%s)(?=[ \t]+(?!(?:%s)(?![\w']))[^\W\d_])" % (
    BEFORE_NOUN, NOT_NOUN.replace(" ", "|")), re.I)
NOUN = re.compile(r"(?<![\w'])((?:an?|the|my|our|your)[ \t]+)(follow up|trade off|mix up)(?![\w'-])", re.I)  # always one
YEAR_OLD = re.compile(r"(?<![\w'])(an?[ \t]+)(\w+ years? old)(?=[ \t]+[^\W\d_])", re.I)  # "a five-year-old boy"


def _hyphens(m):
    return m.group(1) + re.sub(r"[ \t]+", "-", m.group(2))


def _apostrophe(m):
    said, written = m.group(1), APOS[m.group(1).lower()]
    if said.isupper():  # "DONT" is shouted; "IM" is an instant message
        return written.upper() if len(said) > 2 else said
    return written[0].upper() + written[1:] if said[0].isupper() else written


def small(text, lang):
    """The text with P6's marks; one no rule touches comes back byte for byte. English has all three, Spanish the
    slash ("y barra o"): it has no apostrophe to add, and its compounds are the model's."""
    if not text or lang not in PAIRS:
        return text
    out = NUM_SLASH.sub(r"\1/\2", SLASH[lang].sub(r"\1/\2", text))
    if lang != "en":
        return out
    out = APOS_RE.sub(_apostrophe, AND_OR.sub(r"\1/\2", out))
    for rule in (COMPOUND, NOUN, YEAR_OLD):
        out = rule.sub(_hyphens, out)
    return out
