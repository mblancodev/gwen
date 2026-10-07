"""Learn-from-edits storyboard: `gwen mock fixes`.

Text only: the real paste-back needs the Gwen HUD and Accessibility.
"""


def main(args):
    print(
        """Gwen learn-words storyboard (text only)

1. You dictate (⌃): "the post gress migration passed so I will run pie test next"
2. Bar shows live words (fillers stripped), then cleaning (cherry sine).
3. Pasted into the frontmost field:
     The post gress migration passed, so I will run pie test next.
4. You fix "pie test" → "pytest" in that field and leave the field.
5. With learn_from_edits on, Gwen counts the fix. Same spelling twice → rule.
6. Next dictation writes "pytest" as you say "pie test".
7. Settings → Dictation lists Learned words with Forget.
""",
        flush=True,
    )
    return None
