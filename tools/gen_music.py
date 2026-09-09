"""Generates the ambient music loop (queens/assets/audio/music_loop.wav).

Run:  python tools/gen_music.py

A 64-second pad at 84 BPM over I-vi-IV-V in C major with a slow low-pass
sweep, plus a quiet plucked pentatonic arpeggio (Karplus-Strong) from a
seeded random walk. The loop tail is cross-faded so it repeats cleanly.
It is deliberately calm: background texture, not a hook. A licensed track
can replace the file without touching any code.
"""
import os
import wave

import numpy as np

SR = 22050
BPM = 84
BARS = 28            # 4 bars per chord cycle x 7 cycles = 64 s
BEAT = 60.0 / BPM
BAR = 4 * BEAT
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "queens", "assets", "audio", "music_loop.wav")

C4 = 261.63


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


# Chord voicings (MIDI): C major, A minor, F major, G major.
CHORDS = [
    [48, 55, 60, 64, 67],
    [45, 52, 57, 60, 64],
    [41, 48, 53, 57, 60],
    [43, 50, 55, 59, 62],
]
PENTA = [72, 74, 76, 79, 81, 84, 86, 88]


def lowpass(x, cutoff):
    """One-pole low-pass with a time-varying cutoff array or scalar."""
    y = np.empty_like(x)
    acc = 0.0
    if np.isscalar(cutoff):
        alpha = np.full(len(x), (1.0 / SR) / (1.0 / (2 * np.pi * cutoff) + 1.0 / SR))
    else:
        alpha = (1.0 / SR) / (1.0 / (2 * np.pi * np.maximum(cutoff, 20.0)) + 1.0 / SR)
    for i in range(len(x)):
        acc += alpha[i] * (x[i] - acc)
        y[i] = acc
    return y


def pad_voice(freq, seconds, detune=0.004):
    t = np.arange(int(SR * seconds)) / SR
    out = np.zeros_like(t)
    for d in (-detune, 0.0, detune):
        f = freq * (1.0 + d)
        out += 0.4 * (2.0 * ((t * f) % 1.0) - 1.0)      # saw
        out += 0.6 * np.sin(2 * np.pi * f * t)          # sine
    # Soft attack and release so chords blend.
    n = len(t)
    a = int(SR * 1.2)
    r = int(SR * 1.5)
    env = np.ones(n)
    env[:a] = np.linspace(0.0, 1.0, a)
    env[-r:] *= np.linspace(1.0, 0.0, r)
    return out * env


def karplus_strong(freq, seconds, seed, damping=0.996):
    n = int(SR * seconds)
    period = max(2, int(SR / freq))
    rng = np.random.default_rng(seed)
    buf = rng.uniform(-1.0, 1.0, period)
    out = np.empty(n)
    for i in range(n):
        out[i] = buf[i % period]
        buf[i % period] = damping * 0.5 * (buf[i % period] + buf[(i + 1) % period])
    env = np.exp(-3.0 * np.arange(n) / n)
    return out * env


def main():
    total = int(SR * BARS * BAR)
    pad = np.zeros(total)
    for bar in range(BARS):
        chord = CHORDS[(bar // 1) % 4] if False else CHORDS[bar % 4]
        start = int(bar * BAR * SR)
        seconds = BAR + 1.5
        for note in chord:
            v = pad_voice(midi(note), seconds)
            end = min(start + len(v), total)
            pad[start:end] += v[: end - start]
    pad /= 15.0
    # Slow cutoff sweep: 400..1800 Hz at 0.05 Hz.
    t = np.arange(total) / SR
    cutoff = 1100 + 700 * np.sin(2 * np.pi * 0.05 * t)
    pad = lowpass(pad, cutoff)

    # Arpeggio: one pluck per beat on 60 % of beats, a random walk over the scale.
    rng = np.random.default_rng(7)
    arp = np.zeros(total)
    idx = 3
    for beat in range(int(BARS * 4)):
        if rng.random() > 0.6:
            continue
        idx = int(np.clip(idx + rng.integers(-2, 3), 0, len(PENTA) - 1))
        start = int(beat * BEAT * SR)
        pluck = karplus_strong(midi(PENTA[idx]), 1.6, seed=beat + 1)
        end = min(start + len(pluck), total)
        arp[start:end] += pluck[: end - start] * 0.35
    arp = lowpass(arp, 2500)

    mixdown = pad + arp
    # Cross-fade the last 2 s into the first 2 s so the loop is seamless.
    xf = int(SR * 2.0)
    fade = np.linspace(0.0, 1.0, xf)
    head = mixdown[:xf].copy()
    mixdown[-xf:] = mixdown[-xf:] * (1.0 - fade) + head * fade
    mixdown = mixdown[: total - xf]  # the faded tail already contains the head
    peak = np.max(np.abs(mixdown)) or 1.0
    mixdown = mixdown / peak * (10 ** (-18 / 20.0)) * 8.0   # about -18 dBFS RMS-ish, peak-limited below
    mixdown = np.clip(mixdown, -0.7, 0.7)
    pcm = (mixdown * 32767).astype("<i2")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with wave.open(OUT, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote", OUT, "%.1f s" % (len(pcm) / SR))


if __name__ == "__main__":
    main()
