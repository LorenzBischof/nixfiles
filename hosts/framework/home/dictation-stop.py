"""Stop a voxtype dictation on a hiss, and keep numen out of it.

Follows voxtype's status stream. While voxtype is capturing, numen is paused
(so dictated words don't fire commands) and the microphone is fed to a hiss
detector; a sustained "sssss" stops the recording. When voxtype goes idle
again, numen is resumed -- unless it was paused by hand, which the numen-nix
module marks with a state file.

The detector follows the idea of Tristan Hume's "tss" detector in Hammerspoon's
hs.noises (https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/noises):
a hiss is loud between 3.4 and 9 kHz and quiet in the voice band below.

Usage: dictation-stop VOXTYPE NUMENC HOLD_SECONDS RATIO PHRASE...
"""

import json
import os
import selectors
import subprocess
import sys
from pathlib import Path

import numpy as np

voxtype, numenc, hold, ratio, *phrases = sys.argv[1:]

state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
paused_marker = state_home / "numen/paused"

RATE = 44100
SIZE = 1024  # FFT size; 43 Hz bins
HOP = 441  # 10 ms per frame
WINDOW = np.hanning(SIZE)
VOICE = slice(round(250 * SIZE / RATE), round(3400 * SIZE / RATE))
HISS = slice(round(3400 * SIZE / RATE), round(9000 * SIZE / RATE))


class Hiss:
    """Whether the hiss band has outweighed the voice band for `hold` seconds.

    An "s" in speech has the same shape, but lasts 100-200 ms; a room, or the
    microphone's own noise, sits well below a ratio of 1. Upstream's absolute
    speech threshold and its 15-22 kHz band are left out: the first depends
    on the microphone's gain, the second on it recording that high at all.
    """

    def __init__(self, hold, ratio):
        self.hold = round(hold * RATE / HOP)
        self.ratio = ratio
        self.reset()

    def reset(self):
        self.samples = np.zeros(0, dtype=np.float32)
        self.smoothed = None
        self.run = 0
        self.misses = 0

    def feed(self, samples):
        """Take float samples; return whether the hiss has now held long enough."""
        self.samples = np.concatenate([self.samples, samples])
        while len(self.samples) >= SIZE:
            frame = self.samples[:SIZE]
            self.samples = self.samples[HOP:]
            if self.frame(frame):
                return True
        return False

    def frame(self, x):
        power = np.abs(np.fft.rfft(x * WINDOW)) ** 2
        if self.smoothed is None:
            self.smoothed = power
        self.smoothed = self.smoothed * 0.5 + power * 0.5
        voice = self.smoothed[VOICE].mean()
        hiss = self.smoothed[HISS].mean()

        # Once started, half the ratio keeps it going, and a few frames below
        # even that (a breath, a wavering hiss) don't break it.
        needed = self.ratio / 2 if self.run else self.ratio
        # Digital silence (a muted mic) fades both bands alike, which would
        # freeze the ratio of whatever came last -- such as the "s" of a word.
        audible = power[HISS].mean() > 1e-6
        if audible and voice > 0 and hiss / voice >= needed:
            self.run += 1
            self.misses = 0
        elif self.run and self.misses < 3:
            self.misses += 1
        else:
            self.run = 0
        return self.run >= self.hold


hiss = Hiss(float(hold), float(ratio))


def numen(command):
    subprocess.run([numenc], input=command + "\n", text=True, check=False)


class Session:
    """One capture: the microphone stream, and whether we paused numen."""

    def __init__(self, sel):
        self.sel = sel
        self.paused_numen = not paused_marker.exists()
        if self.paused_numen:
            numen("load")
        hiss.reset()
        self.pending = b""
        self.rec = subprocess.Popen(
            [
                "pw-record",
                "--raw",
                "--rate",
                str(RATE),
                "--channels",
                "1",
                "--format",
                "f32",
                "-",
            ],
            stdout=subprocess.PIPE,
        )
        sel.register(self.rec.stdout, selectors.EVENT_READ, self.on_audio)

    def on_audio(self, fd):
        # A status line ending the session can share a select() batch with
        # audio that is now closed.
        if self.rec is None:
            return
        chunk = self.pending + os.read(fd.fileno(), 4096)
        if len(chunk) == len(self.pending):
            self.stop_listening()
            return
        # Reads needn't end on a sample boundary.
        whole = len(chunk) - len(chunk) % 4
        self.pending = chunk[whole:]
        if hiss.feed(np.frombuffer(chunk[:whole], dtype=np.float32)):
            self.stop_listening()
            subprocess.run([voxtype, "record", "stop"], check=False)

    def stop_listening(self):
        if self.rec is None:
            return
        self.sel.unregister(self.rec.stdout)
        self.rec.terminate()
        self.rec.wait()
        self.rec.stdout.close()
        self.rec = None

    def end(self):
        self.stop_listening()
        # Leave numen alone if it was paused by hand in the meantime.
        if self.paused_numen and not paused_marker.exists():
            numen("load " + " ".join(phrases))


sel = selectors.DefaultSelector()
session = None
buffer = b""


def on_status(fd):
    global session, buffer
    data = os.read(fd.fileno(), 4096)
    if not data:
        # The daemon went away; let systemd restart us against a new one.
        if session:
            session.end()
        sys.exit(1)
    buffer += data
    *lines, buffer = buffer.split(b"\n")
    for line in lines:
        try:
            state = json.loads(line).get("class")
        except ValueError:
            continue
        capturing = state in ("recording", "streaming")
        if capturing and session is None:
            session = Session(sel)
        elif not capturing and session is not None:
            session.end()
            session = None


status = subprocess.Popen(
    [voxtype, "status", "--follow", "--format", "json"],
    stdout=subprocess.PIPE,
)
sel.register(status.stdout, selectors.EVENT_READ, on_status)

while True:
    for key, _ in sel.select():
        key.data(key.fileobj)
