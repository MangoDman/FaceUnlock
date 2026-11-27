"""Composes FaceUnlock's sound effects into Resources/Sounds.

Copyright (c) 2026 MangoDman. All rights reserved. Not covered by the MIT License: see
LICENSE-ASSETS.md.

Everything is synthesised here, so there are no recordings or third-party files. Each effect is
built from a few materials (struck glass and wood, a soft low thump, a breath of filtered air)
placed in a small stereo room. Times inside an effect match the animation it goes with, in
seconds from the moment the animation starts.

Usage: python3 Tools/make_sounds.py"""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 48000
OUT = Path(__file__).resolve().parent.parent / "Resources" / "Sounds"
rng = random.Random(7)  # the same files every time


def note(name):
    """'A4' is 440 Hz."""
    steps = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    return 440 * 2 ** ((steps[name[:-1]] + 12 * (int(name[-1]) - 4)) / 12)


class Mix:
    def __init__(self, seconds):
        self.n = int(seconds * RATE)
        self.dry = [[0.0] * self.n, [0.0] * self.n]
        self.send = [[0.0] * self.n, [0.0] * self.n]  # what feeds the room

    def add(self, at, samples, level=1.0, pan=0.0, wet=0.25, channel=None):
        """pan: -1 left, +1 right."""
        angle = (pan + 1) * math.pi / 4
        gains = (math.cos(angle) * math.sqrt(2), math.sin(angle) * math.sqrt(2))
        start = int(at * RATE)
        for c in ([0, 1] if channel is None else [channel]):
            g = level * gains[c]
            for i, v in enumerate(samples):
                j = start + i
                if j >= self.n:
                    break
                self.dry[c][j] += v * g
                self.send[c][j] += v * g * wet


# ---------- materials ----------

def struck(freq, length, modes, attack=0.0025, bend=0.0, bend_time=0.018):
    """A struck object: partials that each ring for their own time.
    modes: (frequency ratio, loudness, seconds to fall by about two thirds)."""
    out = [0.0] * int(length * RATE)
    for ratio, level, decay in modes:
        phase = 0.0
        step = 2 * math.pi * freq * ratio / RATE
        if freq * ratio > RATE * 0.42:
            continue
        for i in range(len(out)):
            t = i / RATE
            rise = 1.0 if t >= attack else math.sin(t / attack * math.pi / 2) ** 2
            phase += step * (1 + bend * math.exp(-t / bend_time))
            out[i] += level * rise * math.exp(-t / decay) * math.sin(phase)
    return out


def glass(name_or_freq, ring=0.22, bright=1.0, length=None, attack=0.006, **kw):
    f = note(name_or_freq) if isinstance(name_or_freq, str) else name_or_freq
    modes = [(1, 1.0, ring), (2.0, 0.13 * bright, ring * 0.55), (2.76, 0.07 * bright, ring * 0.28),
             (5.40, 0.018 * bright, ring * 0.10), (1.0028, 0.35, ring * 0.9),  # a slow shimmer
             (0.5, 0.22, ring * 0.8)]  # body
    return struck(f, length or ring * 4.2, modes, attack=attack, **kw)


def wood(freq, ring=0.05, length=None, **kw):
    return struck(freq, length or ring * 5, [(1, 1.0, ring), (3.93, 0.16, ring * 0.3), (9.2, 0.05, ring * 0.12)], **kw)


def thump(freq=120, drop=1.2, ring=0.045):
    return struck(freq, ring * 6, [(1, 1.0, ring), (2, 0.12, ring * 0.5)], attack=0.004, bend=drop, bend_time=0.014)


def band(samples, centre, q):
    """A band-pass filter whose centre may move: centre is a function of time."""
    out, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for i, x in enumerate(samples):
        w = 2 * math.pi * min(centre(i / RATE), RATE * 0.45) / RATE
        alpha = math.sin(w) / (2 * q)
        y = (alpha * x - alpha * x2 + 2 * math.cos(w) * y1 - (1 - alpha) * y2) / (1 + alpha)
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def air(length, start, end, q=1.4, shape=None):
    """Filtered noise gliding between two pitches: movement."""
    noise = [rng.uniform(-1, 1) for _ in range(int(length * RATE))]
    filtered = band(noise, lambda t: start * (end / start) ** min(t / length, 1), q)
    shape = shape or (lambda p: math.sin(math.pi * p) ** 2)
    return [v * shape(i / len(filtered)) for i, v in enumerate(filtered)]


def click(freq=3200, length=0.012, q=2.0):
    """The contact of one thing on another."""
    noise = [rng.uniform(-1, 1) * math.exp(-i / RATE / (length / 3)) for i in range(int(length * RATE))]
    return band(noise, lambda t: freq, q)


def halo(mix, at, left, right, level, ring=0.5):
    """A faint chord that opens out behind a moment: a different note for each ear."""
    for channel, pitch in enumerate((left, right)):
        mix.add(at, struck(note(pitch), ring * 3.5, [(1, 1.0, ring), (1.004, 0.6, ring)], attack=0.09),
                level, wet=1.6, channel=channel)


# ---------- the room ----------

def reverb(signal, delays, feedback=0.70, damp=0.35):
    out = [0.0] * len(signal)
    for d in delays:  # parallel combs, each losing treble as it repeats
        n = int(d * RATE)
        buffer, low, k = [0.0] * n, 0.0, 0
        for i, x in enumerate(signal):
            y = buffer[k]
            low = y * (1 - damp) + low * damp
            buffer[k] = x + low * feedback
            out[i] += y / len(delays)
            k = (k + 1) % n
    for d in (0.0050, 0.0017):  # two all-passes to smear them together
        n = int(d * RATE)
        buffer, k = [0.0] * n, 0
        for i, x in enumerate(out):
            y = buffer[k]
            out[i] = y - 0.5 * x
            buffer[k] = x + 0.5 * y
            k = (k + 1) % n
    return out


def render(name, mix, peak, room=0.9, space=True):
    """space: a large, wide room (moments). Otherwise a small close one (touches)."""
    if space:
        # Long combs, different in each ear, so the tail surrounds rather than sits in the middle.
        sides = [(0.0531, 0.0617, 0.0719, 0.0797), (0.0571, 0.0653, 0.0743, 0.0829)]
        feedback, damp, gap, amount = 0.80, 0.52, 0.022, room * 1.35
        early = [[(0.011, 0.20), (0.029, 0.12)], [(0.017, 0.20), (0.037, 0.12)]]
        warmth = 0.50
    else:
        sides = [(0.0297, 0.0371, 0.0411, 0.0437), (0.0313, 0.0353, 0.0427, 0.0461)]
        feedback, damp, gap, amount = 0.66, 0.40, 0.006, room
        early = [[], []]
        warmth = 0.70
    channels = []
    for c in (0, 1):
        shift = int(gap * RATE)
        send = [0.0] * shift + mix.send[c][:mix.n - shift]
        wet = reverb(send, sides[c], feedback, damp)
        signal = [d + amount * w for d, w in zip(mix.dry[c], wet)]
        # Early reflections arrive from the opposite side first.
        for delay, level in early[c]:
            k = int(delay * RATE)
            for i in range(k, mix.n):
                signal[i] += level * mix.send[1 - c][i - k]
        # Remove rumble and take the edge off the top.
        out, hp, last, lp = [], 0.0, 0.0, 0.0
        for x in signal:
            hp = 0.994 * (hp + x - last)
            last = x
            lp += warmth * (hp - lp)
            out.append(lp)
        channels.append(out)
    top = max(abs(v) for ch in channels for v in ch)
    # Stop once the tail is inaudible.
    end = len(channels[0])
    while end > 1 and max(abs(channels[0][end - 1]), abs(channels[1][end - 1])) < top * 0.003:
        end -= 1
    fade = min(int((0.25 if space else 0.03) * RATE), end)
    data = bytearray()
    for i in range(end):
        g = peak / top * (1 if i < end - fade else (end - i) / fade)
        for ch in channels:
            dither = (rng.random() - rng.random()) / 32768
            data += struct.pack("<h", max(-32767, min(32767, int((ch[i] * g + (dither if g else 0)) * 32767))))
    with wave.open(str(OUT / f"{name}.wav"), "wb") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(bytes(data))
    print(f"{name:10} {end / RATE:.2f} s")


# ---------- the effects ----------

# The notch opens (spring, 0.45 s): a breath rising, and a drop of glass as the content lands.
m = Mix(1.4)
m.add(0.00, air(0.20, 700, 3600, q=1.1), 0.55, wet=0.4)
m.add(0.085, glass("A5", ring=0.055, bright=0.6, bend=-0.05), 0.55, wet=0.5)
render("open", m, 0.17)

# Success. Arcs spin and join 0-0.60, tick draws 0.62-1.05, lock opens at 0.60.
m = Mix(3.2)
m.add(0.00, air(0.64, 700, 5200, q=2.2, shape=lambda p: p ** 2 * (1 - p) * 6.75), 0.30, wet=0.6)
m.add(0.00, glass("E5", ring=0.09, bright=0.5), 0.32, pan=-0.55)
m.add(0.30, glass("G#5", ring=0.07, bright=0.4), 0.20, pan=0.35, wet=0.5)  # halfway round
m.add(0.585, click(2600), 0.55, wet=0.2)                       # ring meets itself
m.add(0.585, glass("B5", ring=0.12), 0.60, pan=-0.2, wet=0.35)
m.add(0.62, thump(150, 0.9, 0.030), 0.35, wet=0.1)             # the lock gives
m.add(0.835, glass("E6", ring=0.28), 0.85, pan=0.4, wet=0.6)   # fastest part of the tick
m.add(0.835, glass("G#5", ring=0.32, bright=0.4), 0.45, pan=-0.55, wet=0.6)
m.add(1.00, glass("B6", ring=0.12, bright=0.3), 0.16, pan=0.65, wet=1.2)   # glint as it finishes
halo(m, 0.78, "B4", "G#4", 0.16)
render("unlock", m, 0.42)

# The notch goes back up.
m = Mix(1.0)
m.add(0.00, air(0.26, 3200, 600, q=1.2), 0.6, wet=0.35)
m.add(0.17, wood(520, ring=0.018), 0.20, wet=0.3)
render("retract", m, 0.11)

# The Mac locks: a bolt going home.
m = Mix(0.7)
m.add(0.000, click(2100, 0.010), 0.7)
m.add(0.000, wood(note("G4"), ring=0.030, bend=0.25), 0.7, pan=-0.15)
m.add(0.062, click(1500, 0.014), 0.9)
m.add(0.062, wood(note("C4"), ring=0.048, bend=0.15), 1.0, pan=0.1)
m.add(0.062, thump(96, 0.8, 0.040), 0.8, wet=0.1)
render("lock", m, 0.36, room=0.6, space=False)

# Not recognised. The notch shakes three times in 0.5 s: right at 0.042, 0.208, 0.375.
m = Mix(0.9)
for at, level, pan in [(0.042, 1.0, 0.45), (0.125, 0.55, -0.45), (0.208, 0.80, 0.4), (0.292, 0.35, -0.35)]:
    m.add(at, wood(note("D#4"), ring=0.036, bend=0.06), level, pan=pan)
    m.add(at, thump(105, 0.5, 0.024), level * 0.6, pan=pan * 0.5, wet=0.05)
    m.add(at, click(1300, 0.008), level * 0.25, pan=pan)
render("failure", m, 0.36, room=0.55, space=False)

# Password needed: two calm notes stepping down.
m = Mix(2.4)
m.add(0.08, glass("D5", ring=0.16, bright=0.7), 0.9, pan=-0.2, wet=0.4)
m.add(0.23, glass("A4", ring=0.30, bright=0.6), 1.0, pan=0.15, wet=0.45)
m.add(0.23, thump(110, 0.4, 0.05), 0.18, wet=0.1)
render("password", m, 0.32)

# Something to read; the symbol bounces as it arrives.
m = Mix(2.2)
m.add(0.08, glass("G5", ring=0.09), 0.75, pan=-0.3, wet=0.4)
m.add(0.17, glass("D6", ring=0.22), 1.0, pan=0.25, wet=0.5)
m.add(0.17, glass("B5", ring=0.20, bright=0.4), 0.40, wet=0.5)
render("notice", m, 0.30)

# Pointer over the notch, and a button pressed.
m = Mix(0.25)
m.add(0.0, wood(1850, ring=0.008), 0.8, wet=0.25)
m.add(0.0, click(4200, 0.006), 0.35)
render("hover", m, 0.10, room=0.5, space=False)

m = Mix(0.35)
m.add(0.0, click(3000, 0.008), 0.8)
m.add(0.0, wood(980, ring=0.014, bend=0.1), 0.9, wet=0.25)
render("tap", m, 0.20, room=0.5, space=False)

# Setup: each side captured climbs one step; the arc pulses out at 0 and settles by 0.14.
for index, pitch in enumerate(["C6", "D6", "E6", "G6"], start=1):
    m = Mix(1.3)
    m.add(0.000, click(3600, 0.007), 0.4)
    m.add(0.000, glass(pitch, ring=0.085, bright=0.7, bend=-0.025), 0.9, pan=(index - 2.5) * 0.22, wet=0.4)
    m.add(0.085, glass(note(pitch) * 1.5, ring=0.05, bright=0.2), 0.14, pan=(2.5 - index) * 0.2, wet=0.7)
    render(f"capture{index}", m, 0.25, room=0.6)

# Setup done. Arcs join 0-0.30, ring shrinks 0.30-0.65, tick draws 0.65-1.00.
m = Mix(3.8)
m.add(0.00, air(0.34, 600, 4800, q=1.8, shape=lambda p: p ** 2 * (1 - p) * 6.75), 0.35, wet=0.6)
for at, pitch, pan in [(0.00, "C5", -0.4), (0.10, "E5", -0.15), (0.20, "G5", 0.15)]:
    m.add(at, glass(pitch, ring=0.14, bright=0.6), 0.45, pan=pan, wet=0.45)
m.add(0.30, thump(130, 0.9, 0.05), 0.45, wet=0.1)
m.add(0.31, click(2200), 0.35)
for pitch, level, pan in [("C5", 0.45, -0.35), ("G5", 0.55, 0.3), ("C6", 0.85, -0.1), ("E6", 0.55, 0.2)]:
    m.add(0.80, glass(pitch, ring=0.45, bright=0.6), level, pan=pan, wet=0.5)
m.add(0.98, glass("G6", ring=0.20, bright=0.3), 0.20, pan=0.65, wet=1.3)
halo(m, 0.72, "E4", "G4", 0.18, ring=0.7)
render("complete", m, 0.42)

# Face Unlock turned on or resumed, and paused.
m = Mix(1.6)
m.add(0.0, glass("G5", ring=0.07), 0.7, pan=-0.2, wet=0.4)
m.add(0.07, glass("C6", ring=0.15), 1.0, pan=0.2, wet=0.45)
render("on", m, 0.26)

m = Mix(1.6)
m.add(0.0, glass("C6", ring=0.07, bright=0.6), 0.7, pan=0.2, wet=0.4)
m.add(0.07, glass("G5", ring=0.14, bright=0.5), 1.0, pan=-0.2, wet=0.45)
render("off", m, 0.22)
