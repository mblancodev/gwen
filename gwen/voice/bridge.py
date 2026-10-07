"""Line protocol with Gwen.app (stdin/stdout)."""
from __future__ import annotations

import subprocess
import threading
from typing import Callable


class Hud:
    def __init__(self, bin_path: str):
        self.proc = subprocess.Popen(
            [bin_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        self._lock = threading.Lock()
        self.state = "idle"

    def send(self, line: str) -> None:
        with self._lock:
            if not self.proc.stdin:
                return
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()

    def set(self, state: str, text: str = "") -> None:
        self.state = state
        self.send("state " + state if not text else "state " + state)  # text via live/insert
        if text and state in ("dictating", "translating", "cleaning"):
            self.send("live " + text)

    def events(self):
        assert self.proc.stdout
        for line in self.proc.stdout:
            yield line.rstrip("\n")

    def close(self) -> None:
        try:
            self.send("quit")
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()
