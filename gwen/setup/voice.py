"""Local speech-to-text: Whisper on 127.0.0.1:2022 via VoiceMode's whisper.cpp install.

Gwen installs the service if missing, binds loopback only, and can keep the server as a
child of `gwen listen` so quitting the listener stops Whisper when Gwen started it.
"""
from __future__ import annotations

import os
import shlex
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request

from gwen.voice import config as cfg_mod
from gwen.voice.paths import HOME, STT_URL

STT_HEALTH = STT_URL.rsplit("/v1", 1)[0] + "/health"
WHISPER_MODEL = "small"  # multilingual
VAD_MODEL = "silero-v6.2.0"
WHISPER_DIR = os.path.expanduser("~/.voicemode/services/whisper")
VM_DIR = os.path.expanduser("~/.voicemode")
SHADOW_HOME = os.path.join(HOME, "voicemode-home")
LOG = os.path.join(HOME, "logs", "whisper.log")

_proc: subprocess.Popen | None = None
_owned = False  # True if this process started Whisper and should stop it


def speech_up() -> bool:
    try:
        urllib.request.urlopen(STT_HEALTH, timeout=3)
        return True
    except urllib.error.HTTPError:
        return True
    except OSError:
        return False


def find_uvx() -> str | None:
    return shutil.which("uvx") or next(
        (p for p in (os.path.expanduser("~/.local/bin/uvx"), "/opt/homebrew/bin/uvx") if os.path.exists(p)),
        None,
    )


def voicemode_cmd() -> list[str] | None:
    if shutil.which("voicemode"):
        return [shutil.which("voicemode")]
    if not find_uvx():
        print("    installing uv (runs VoiceMode)…", flush=True)
        brew = shutil.which("brew")
        if brew:
            subprocess.run([brew, "install", "uv"], stdin=subprocess.DEVNULL)
        else:
            subprocess.run(
                ["sh", "-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
                stdin=subprocess.DEVNULL,
            )
    uvx = find_uvx()
    return [uvx, "--from", "voice-mode", "voicemode"] if uvx else None


def shadow_home(real: str | None = None, shadow: str = SHADOW_HOME) -> str:
    """Install VoiceMode with HOME=shadow so it does not register LaunchAgents as login items."""
    real = real or os.path.expanduser("~")
    for d in (".voicemode", ".local", ".cache"):
        os.makedirs(os.path.join(real, d), exist_ok=True)
    for rel, skip in (("", "Library"), ("Library", "LaunchAgents")):
        os.makedirs(os.path.join(shadow, rel, skip), exist_ok=True)
        for name in os.listdir(os.path.join(real, rel)):
            link = os.path.join(shadow, rel, name)
            if name != skip and not os.path.lexists(link) and os.path.join(real, rel, name) != HOME:
                os.symlink(os.path.join(real, rel, name), link)
    return shadow


def vad_model() -> str:
    return os.path.join(WHISPER_DIR, "models", "ggml-%s.bin" % VAD_MODEL)


def fetch_vad() -> None:
    models = os.path.dirname(vad_model())
    if os.path.isdir(models) and not os.path.exists(vad_model()):
        script = os.path.join(models, "download-vad-model.sh")
        if os.path.exists(script):
            subprocess.run(["sh", script, VAD_MODEL, models], stdin=subprocess.DEVNULL)


def start_script() -> str | None:
    """Rewrite VoiceMode's start script for loopback + VAD; return path to Gwen's copy."""
    script = os.path.join(WHISPER_DIR, "bin", "start-whisper-server.sh")
    if not os.path.exists(script):
        return None
    vad = vad_model()
    flags = "--host 127.0.0.1"
    if os.path.exists(vad):
        flags += " --vad -vsd 1000 -vp 400 --vad-model " + shlex.quote(vad)
    with open(script) as f:
        text = f.read().replace("--host 0.0.0.0", flags)
    out = os.path.join(os.path.dirname(script), "gwen-start-whisper-server.sh")
    with open(out, "w") as f:
        f.write(text)
    os.chmod(out, 0o755)
    return out


def wait_up(seconds: float = 240) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if speech_up():
            return True
        time.sleep(2)
    return False


def install_whisper() -> bool:
    """Install VoiceMode's whisper service + small model. Return True if the start script exists."""
    if os.path.exists(os.path.join(WHISPER_DIR, "bin", "start-whisper-server.sh")):
        fetch_vad()
        return True
    vm = voicemode_cmd()
    if not vm:
        print("gwen setup: install uv (https://docs.astral.sh/uv/), then retry", flush=True)
        return False
    print("    setting up Whisper: first time downloads a model (a few minutes)…", flush=True)
    env = dict(os.environ, HOME=shadow_home(), VOICEMODE_SERVICE_AUTO_ENABLE="false")
    for step in (["service", "install", "whisper"], ["whisper", "model", WHISPER_MODEL]):
        subprocess.run(vm + step, stdin=subprocess.DEVNULL, env=env)
    fetch_vad()
    return os.path.exists(os.path.join(WHISPER_DIR, "bin", "start-whisper-server.sh"))


def start_whisper() -> bool:
    """Start Whisper if down. Sets _owned when this process spawned it."""
    global _proc, _owned
    if speech_up():
        fetch_vad()
        return True
    if not install_whisper():
        return False
    script = start_script()
    if not script:
        return False
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    env = dict(os.environ, VOICEMODE_WHISPER_MODEL=WHISPER_MODEL, VOICEMODE_WHISPER_PORT="2022")
    with open(LOG, "a") as log:
        _proc = subprocess.Popen(
            [script],
            cwd=WHISPER_DIR,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    _owned = True
    return wait_up(240)


def stop_whisper() -> None:
    """Stop Whisper only if this process started it."""
    global _proc, _owned
    if not _owned or _proc is None:
        return
    if _proc.poll() is None:
        try:
            os.killpg(_proc.pid, signal.SIGTERM)
        except OSError:
            pass
    _proc = None
    _owned = False


def ensure_voice(say=None, start: bool = True) -> bool:
    """Install Whisper if needed; optionally start it. Return True when STT is ready.

    With apple_speech in config, skip Whisper (Apple path is separate).
    """
    def _say(ok: bool, msg: str, detail: str | None = None) -> bool:
        if say:
            return say(ok, msg, detail)
        line = ("✓ " if ok else "✗ ") + msg
        if detail:
            line += " — " + detail
        print(line, flush=True)
        return ok

    cfg = cfg_mod.load()
    if cfg.get("apple_speech"):
        return _say(True, "speech to text (Apple Speech; Whisper skipped)")

    label = "Whisper (speech to text)"
    if speech_up():
        fetch_vad()
        return _say(True, label)

    if not start:
        return _say(False, label + " is not running", "run: gwen setup")

    print("    starting Whisper on 127.0.0.1:2022…", flush=True)
    if start_whisper():
        return _say(True, label)
    return _say(False, label + " did not start", "see ~/.gwen/logs/whisper.log and ~/.voicemode/logs/whisper")
