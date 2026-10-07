# Gwen

Dictation and translation in any app on macOS: hold a key, speak, the text is pasted at the cursor. Local by
default (whisper.cpp on this Mac, Apple's on-device Translation).

## Commands

| Do | Run |
| --- | --- |
| Install and start Whisper on 127.0.0.1:2022 | `./bin/gwen setup` |
| Compile the app into `~/.gwen/Gwen.app` | `./bin/gwen build` |
| Menu bar + bottom bar | `./bin/gwen hud` |
| The listener (mic, Whisper, paste) | `./bin/gwen listen` (`--no-wake` to skip "Hey Gwen") |
| Native Settings | `./bin/gwen settings` |
| Play a scene with no mic | `./bin/gwen mock <name>` (`./bin/gwen mock` lists them) |

There is no test suite. Check a change with the matching mock, then by hand.

## Map

| To change… | Go to | Grep |
| --- | --- | --- |
| A CLI command | `gwen/cli.py` | `add_parser` |
| The listen loop | `gwen/voice/listen.py` | |
| Mic capture, speech-to-text health, segmenting | `gwen/voice/audio.py` | |
| How spoken text is cleaned and punctuated | `gwen/voice/dictation.py`, `gwen/voice/punctuation.py`, `gwen/voice/small_marks.py` | |
| The words the punctuation rules look for, per language | `gwen/voice/punctuation_words.py` | |
| "Hey Gwen", and teaching it your voice | `gwen/voice/wake.py`, `macapp/Wake.swift` | `WakeTrainer` |
| Learned words | `gwen/voice/learn.py`, `macapp/HUD+Learn.swift` | |
| Paths under `~/.gwen`, prefs | `gwen/voice/paths.py`, `gwen/voice/config.py`, `macapp/Config.swift` | |
| What Python tells the HUD | `gwen/voice/bridge.py` | |
| App entry and the bar's state machine | `macapp/main.swift`, `macapp/HUD.swift`, `macapp/HUD+Bar.swift` | |
| The bottom bar and its language chip | `macapp/PillView.swift` | |
| The keys | `macapp/Keys.swift` | |
| The menu's Microphone picker | `macapp/HUD+Mic.swift` | `pickMic` |
| `gwen://` (what other apps call), starting the listener when opened bare | `macapp/HUD+URL.swift` | `openURL` |
| Pasting, and what happens when it can't | `macapp/HUD+Paste.swift` | |
| Translate (selection and speech), replace in place | `macapp/HUD+Translate.swift`, `macapp/Translate.swift` | |
| Native Settings pages | `macapp/Settings+Sections.swift` | |
| Whisper install and start | `gwen/setup/voice.py` | |
| A demo scene | `gwen/mocks/bar.py` and its siblings | |
| The marketing site | `site/index.html` | |

## Invariants

- **Nothing leaves the Mac by default.** Polish through a local agent CLI (`claude`) is opt-in and off.
- **Translation needs macOS 15 or later**; dictation does not.
- **User data lives in `~/.gwen`**; the built app is `~/.gwen/Gwen.app`.
- **`design/` is superseded** by the HUD and native Settings. Don't build on it.
