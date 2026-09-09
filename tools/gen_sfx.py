"""Synthesizes every sound effect as a 44.1 kHz 16-bit mono WAV.

Run:  python tools/gen_sfx.py
Output: queens/assets/audio/<cue>.wav  (loaded lazily by scripts/audio_manager.gd)

Everything is procedural (numpy only): short envelopes on sines, triangles,
squares and filtered noise. Tweak a recipe, rerun, reimport in Godot.
"""
import os
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "queens", "assets", "audio")


# --- building blocks ----------------------------------------------------------

def t(seconds):
    return np.arange(int(SR * seconds)) / SR


def env(n, attack=0.002, decay=None, hold=0.0, curve=6.0):
    """Exponential decay envelope with a short linear attack."""
    x = np.linspace(0.0, 1.0, n, endpoint=False)
    a = int(SR * attack)
    e = np.exp(-curve * np.clip((x * n - a - hold * SR) / max(n - a, 1), 0, None))
    if a > 0:
        e[:a] *= np.linspace(0.0, 1.0, a)
    return e


def sine(freq, seconds, phase=0.0):
    return np.sin(2 * np.pi * freq * t(seconds) + phase)


def sweep(f0, f1, seconds):
    tt = t(seconds)
    f = f0 + (f1 - f0) * (tt / seconds)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph)


def triangle(freq, seconds):
    tt = t(seconds)
    return 2.0 * np.abs(2.0 * ((tt * freq) % 1.0) - 1.0) - 1.0


def square(freq, seconds):
    return np.sign(np.sin(2 * np.pi * freq * t(seconds)))


def saw(freq, seconds):
    return 2.0 * ((t(seconds) * freq) % 1.0) - 1.0


def noise(seconds, seed=1):
    rng = np.random.default_rng(seed)
    return rng.uniform(-1.0, 1.0, int(SR * seconds))


def lowpass(x, cutoff):
    """One-pole low-pass."""
    rc = 1.0 / (2 * np.pi * cutoff)
    alpha = (1.0 / SR) / (rc + 1.0 / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


def bandpass(x, lo, hi):
    return lowpass(highpass(x, lo), hi)


def click(seconds=0.006, seed=3):
    return noise(seconds, seed) * env(int(SR * seconds), attack=0.0005, curve=8.0)


def mix(*parts):
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def delay(x, seconds):
    return np.concatenate([np.zeros(int(SR * seconds)), x])


def gain_db(x, db):
    return x * (10.0 ** (db / 20.0))


def normalize(x, peak=0.9):
    m = np.max(np.abs(x)) or 1.0
    return x / m * peak


def note(freq, seconds, wave_fn=sine, harmonic=0.0, curve=6.0, attack=0.003):
    x = wave_fn(freq, seconds)
    if harmonic > 0.0:
        x = x + harmonic * sine(freq * 2, seconds)
    return x * env(len(x), attack=attack, curve=curve)


def write(name, data, peak=0.9):
    data = normalize(data, peak)
    pcm = (np.clip(data, -1.0, 1.0) * 32767).astype("<i2")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return path


# --- cues ---------------------------------------------------------------------

def build():
    cues = {}
    cues["tap_mark"] = mix(click(), note(1800, 0.05, curve=9.0) * 0.6)
    cues["tap_unmark"] = mix(click(0.005, 4), note(1200, 0.05, curve=9.0) * 0.6)
    cues["drag_tick"] = note(2400, 0.02, curve=10.0)
    cues["queen_place"] = mix(
        click(0.005, 5) * 0.8,
        sweep(380, 220, 0.09) * env(int(SR * 0.09), curve=5.0),
        note(880, 0.06, triangle, curve=7.0) * 0.4,
    )
    cues["queen_remove"] = gain_db(sweep(220, 380, 0.08) * env(int(SR * 0.08), curve=6.0), -6)
    cues["long_press"] = mix(note(660, 0.07, curve=6.0), delay(note(990, 0.07, curve=6.0), 0.03))
    beat = (square(196, 0.18) + square(208, 0.18)) * 0.5
    cues["conflict"] = gain_db(lowpass(beat, 2000) * env(int(SR * 0.18), attack=0.005, curve=4.0), -8)
    cues["mistake"] = mix(note(523, 0.07, curve=5.0), delay(note(440, 0.09, curve=5.0), 0.07))
    n = noise(0.12, 7)
    cues["undo"] = bandpass(n, 400, 1500) * env(len(n), curve=5.0)
    n = noise(0.25, 8)
    cues["clear"] = lowpass(n, 3000) * env(len(n), curve=4.0) * np.linspace(1.0, 0.2, len(n))
    cues["hint"] = mix(
        note(1046, 0.16, harmonic=0.3, curve=4.0),
        delay(note(1318, 0.16, harmonic=0.3, curve=4.0), 0.04),
        delay(note(1568, 0.26, harmonic=0.3, curve=3.5), 0.08),
    )
    chord = []
    for i, f in enumerate([523.25, 659.25, 783.99, 1046.5]):
        tone = (saw(f, 0.9) * 0.35 + sine(f, 0.9)) * env(int(SR * 0.9), attack=0.01, curve=3.0)
        chord.append(delay(tone, 0.12 * i))
    shimmer = highpass(noise(1.5, 9), 4000) * env(int(SR * 1.5), attack=0.05, curve=3.0) * 0.12
    cues["win"] = mix(lowpass(mix(*chord), 3000), delay(shimmer, 0.2))
    n = noise(0.03, 10)
    cues["confetti_pop"] = bandpass(n, 700, 1400) * env(len(n), curve=8.0)
    cues["button"] = mix(click(0.004, 11) * 0.7, note(1500, 0.025, curve=10.0))
    cues["energy_drain"] = sweep(900, 600, 0.12) * env(int(SR * 0.12), curve=5.0)
    cues["energy_gain"] = mix(sweep(600, 900, 0.12) * env(int(SR * 0.12), curve=5.0), delay(cues["hint"] * 0.5, 0.08))
    cues["pause_open"] = mix(note(784, 0.09, curve=5.0), delay(note(659, 0.12, curve=5.0), 0.06))
    cues["pause_close"] = mix(note(659, 0.09, curve=5.0), delay(note(784, 0.12, curve=5.0), 0.06))
    cues["toast"] = note(1320, 0.08, harmonic=0.2, curve=7.0)
    return cues


def main():
    cues = build()
    for name, data in cues.items():
        print("wrote", write(name, data))


if __name__ == "__main__":
    main()
