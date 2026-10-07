"""~/.gwen paths for voice data."""
import os

HOME = os.path.expanduser("~/.gwen")
VOICE_DIR = os.path.join(HOME, "voice")
WORDS = os.path.join(VOICE_DIR, "words.json")
LANG_FILE = os.path.join(VOICE_DIR, "dictation.json")
CORRECTED = os.path.join(VOICE_DIR, "corrected")
TAKES = os.path.join(VOICE_DIR, "takes.json")
TONE = os.path.join(VOICE_DIR, "tone.json")
FIFO = os.path.join(HOME, "mic.fifo")
CONFIG = os.path.join(HOME, "config.json")
STT_URL = "http://127.0.0.1:2022/v1/audio/transcriptions"
