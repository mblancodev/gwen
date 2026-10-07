"""Illustrative punctuation before/after: `gwen mock punctuation`.

Samples only; the real rules are in gwen/voice/punctuation.py.
"""

SAMPLES = [
    ("What time is it.", "What time is it?"),
    ("So I was thinking we could ship tomorrow.", "So, I was thinking we could ship tomorrow."),
    ("Well the thing is we're late.", "Well, the thing is we're late."),
    ("I wanted to go but.", "I wanted to go but..."),
    ("dont touch the dogs bowl", "don't touch the dog's bowl"),
    ("new paragraph the next idea", "the next idea"),  # spoken command → paragraph break (shown as blank line below)
]

FORMAT = [
    ("Meet me at 3.30pm thumbs up emoji", "Meet me at 3:30 pm 👍"),
    ("first milk second eggs third bread", "1. milk\n2. eggs\n3. bread"),
]


def main(args):
    print("Gwen punctuation samples (illustrative — not the live engine)\n", flush=True)
    print("Punctuation / spoken cleanup", flush=True)
    print("-" * 56, flush=True)
    for raw, out in SAMPLES:
        if raw.startswith("new paragraph"):
            print("heard:  %s" % raw, flush=True)
            print("pasted: <paragraph>\n%s\n" % out, flush=True)
        else:
            print("heard:  %s" % raw, flush=True)
            print("pasted: %s\n" % out, flush=True)
    print("format_dictation (off by default in Settings)", flush=True)
    print("-" * 56, flush=True)
    for raw, out in FORMAT:
        print("heard:  %s" % raw, flush=True)
        print("pasted: %s\n" % out, flush=True)
    return None
