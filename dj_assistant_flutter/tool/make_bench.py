#!/usr/bin/env python3
"""Generates the precision benchmark: synthetic but music-like tracks with a
known tempo and key, to measure DJ Assistant's tempo and key detection.

Each track has drums in a genre pattern (kick, snare/clap, hats, sometimes
swing), a bass line on the chord roots, harmonic-rich chords following a
common progression in the key, a melody from the scale that resolves to the
tonic, noise, and sometimes a detuned source (vinyl pitch). Minor keys use
progressions that lean on the relative major (i-VI-III-VII), major keys ones
that visit the relative minor (I-V-vi-IV), and some minor tracks use the
harmonic-minor major V: the classic traps for key detection.

Usage: python3 tool/make_bench.py <out-dir> [count] [seconds] [seed]
Writes <out-dir>/NNN.wav and <out-dir>/truth.json. Needs numpy.
No copyrighted audio is involved.
"""
import json
import math
import sys
import wave

import numpy as np

SR = 22050
NOTES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B']
CAMELOT_MAJOR = ['8B', '3B', '10B', '5B', '12B', '7B', '2B', '9B', '4B', '11B', '6B', '1B']
CAMELOT_MINOR = ['5A', '12A', '7A', '2A', '9A', '4A', '11A', '6A', '1A', '8A', '3A', '10A']
MAJOR_SCALE = [0, 2, 4, 5, 7, 9, 11]
MINOR_SCALE = [0, 2, 3, 5, 7, 8, 10]

# (degree offset in semitones from tonic, quality) per chord
PROGRESSIONS = {
    'major': [
        [(0, 'maj'), (7, 'maj'), (9, 'min'), (5, 'maj')],      # I V vi IV
        [(0, 'maj'), (5, 'maj'), (7, 'maj'), (0, 'maj')],      # I IV V I
        [(0, 'maj'), (9, 'min'), (5, 'maj'), (7, 'maj')],      # I vi IV V
        [(0, 'maj7'), (2, 'min7'), (5, 'maj7'), (7, 'dom7')],  # I ii IV V (jazzy)
    ],
    'minor': [
        [(0, 'min'), (8, 'maj'), (3, 'maj'), (10, 'maj')],     # i VI III VII
        [(0, 'min'), (5, 'min'), (7, 'min'), (0, 'min')],      # i iv v i
        [(0, 'min'), (10, 'maj'), (8, 'maj'), (10, 'maj')],    # i VII VI VII
        [(0, 'min'), (5, 'min'), (7, 'maj'), (0, 'min')],      # i iv V i (harmonic)
        [(0, 'min7'), (5, 'min7'), (0, 'min7'), (7, 'min7')],  # deep house minor 7ths
    ],
}
CHORD = {
    'maj': [0, 4, 7], 'min': [0, 3, 7], 'maj7': [0, 4, 7, 11],
    'min7': [0, 3, 7, 10], 'dom7': [0, 4, 7, 10],
}
GENRES = [
    # name, bpm range, kick pattern (16ths), snare, hats, swing
    ('hiphop', (78, 98), [0, 7, 10], [4, 12], 'eighths', 0.12),
    ('rnb', (64, 80), [0, 9], [4, 12], 'eighths', 0.08),
    ('afro', (98, 114), [0, 6, 10], [4, 12], 'sixteenths', 0.05),
    ('amapiano', (110, 116), [0, 8], [4, 12], 'sixteenths', 0.0),
    ('house', (118, 128), [0, 4, 8, 12], [4, 12], 'offbeat', 0.0),
    ('techno', (128, 140), [0, 4, 8, 12], [], 'sixteenths', 0.0),
    ('dnb', (170, 176), [0, 10], [4, 12], 'sixteenths', 0.0),
    ('dancehall', (88, 102), [0, 6, 8, 14], [4, 12], 'eighths', 0.0),
]


def midi_hz(m, cents=0.0):
    return 440.0 * 2 ** ((m - 69 + cents / 100.0) / 12.0)


def tone(freq, n, harmonics, decay=0.0, phase=0.0):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for h, a in enumerate(harmonics, start=1):
        if freq * h > SR / 2 - 200:
            break
        out += a * np.sin(2 * math.pi * freq * h * t + phase * h)
    if decay:
        out *= np.exp(-decay * t)
    return out


def add(buf, at, sig):
    if at >= len(buf):
        return
    end = min(len(buf), at + len(sig))
    buf[at:end] += sig[: end - at]


def kick(n):
    t = np.arange(n) / SR
    f = 50 + 90 * np.exp(-30 * t)
    return np.sin(2 * math.pi * np.cumsum(f) / SR) * np.exp(-9 * t)


def noise_hit(rng, n, decay, hp=True):
    x = rng.standard_normal(n)
    if hp:
        x = np.diff(np.concatenate([[0.0], x]))
    return x * np.exp(-decay * np.arange(n) / SR)


def make(rng, seconds):
    genre, (lo, hi), kicks, snares, hats, swing = GENRES[rng.integers(len(GENRES))]
    bpm = round(float(rng.uniform(lo, hi)), 1)
    mode = 'minor' if rng.random() < 0.6 else 'major'
    root = int(rng.integers(12))
    cents = float(rng.choice([0, 0, 0, rng.uniform(-35, 35)]))
    prog = PROGRESSIONS[mode][rng.integers(len(PROGRESSIONS[mode]))]
    n = int(seconds * SR)
    buf = np.zeros(n)
    beat = 60.0 / bpm
    six = beat / 4
    bars = int(seconds / (4 * beat)) + 1
    scale = MINOR_SCALE if mode == 'minor' else MAJOR_SCALE
    pad_h = [1, 0.5, 0.33, 0.25, 0.2, 0.16, 0.14, 0.12]  # saw-like
    bass_h = [1, 0.6, 0.3, 0.15]
    lead_h = [1, 0.3, 0.5, 0.1, 0.2]
    k = kick(int(0.4 * SR))
    for bar in range(bars):
        chord_root, quality = prog[bar % len(prog)]
        bar_t = bar * 4 * beat
        # drums
        for s in range(16):
            sw = swing * six if s % 2 else 0.0
            at = int((bar_t + s * six + sw) * SR)
            if s in kicks:
                add(buf, at, 0.9 * k)
            if s in snares:
                add(buf, at, 0.35 * noise_hit(rng, int(0.2 * SR), 18))
            hat = {'eighths': s % 2 == 0, 'sixteenths': True,
                   'offbeat': s % 4 == 2}[hats]
            if hat:
                add(buf, at, 0.08 * noise_hit(rng, int(0.05 * SR), 80))
        # bass: chord root, octave 2, eighth-note pattern
        bass_m = 36 + (root + chord_root) % 12
        for e in range(8):
            if rng.random() < 0.75:
                m = bass_m + (12 if e % 4 == 3 else 0)
                at = int((bar_t + e * 2 * six) * SR)
                add(buf, at, 0.35 * tone(midi_hz(m, cents), int(2 * six * SR), bass_h, 6))
        # chords: one per bar, octave 4
        for iv in CHORD[quality]:
            m = 60 + (root + chord_root + iv) % 12
            add(buf, int(bar_t * SR), 0.10 * tone(midi_hz(m, cents), int(4 * beat * SR), pad_h, 0.4))
        # melody: quarter notes from the scale; ends each 4 bars on the tonic
        for q in range(4):
            if bar % 4 == 3 and q == 3:
                deg = 0
            else:
                deg = scale[rng.integers(len(scale))]
            if rng.random() < 0.8:
                m = 72 + (root + deg) % 12
                add(buf, int((bar_t + q * beat) * SR),
                    0.12 * tone(midi_hz(m, cents), int(beat * SR), lead_h, 3))
    buf += 0.01 * rng.standard_normal(n)
    buf *= 0.8 / max(1e-9, np.max(np.abs(buf)))
    camelot = (CAMELOT_MINOR if mode == 'minor' else CAMELOT_MAJOR)[root]
    return buf, {
        'genre': genre, 'bpm': bpm, 'key': f'{NOTES[root]} {mode}',
        'camelot': camelot, 'cents': round(cents, 1),
        'progression': ' '.join(f'{c}{q}' for c, q in prog),
    }


def main():
    out = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 45
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 7
    rng = np.random.default_rng(seed)
    truth = {}
    for i in range(count):
        x, info = make(rng, seconds)
        name = f'{i:03d}.wav'
        with wave.open(f'{out}/{name}', 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((np.clip(x, -1, 1) * 32767).astype('<i2').tobytes())
        truth[name] = info
    with open(f'{out}/truth.json', 'w') as f:
        json.dump(truth, f, indent=1)
    print(f'wrote {count} tracks to {out}')


if __name__ == '__main__':
    main()
