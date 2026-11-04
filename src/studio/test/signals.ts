/** Synthetic test audio: a kick drum pattern at a given tempo, and sustained chords. */
export function kickPattern(bpm: number, seconds: number, rate = 44100, opts: { hats?: boolean; offbeatBass?: boolean } = {}) {
  const out = new Float32Array(Math.floor(seconds * rate));
  const beat = (60 / bpm) * rate;
  for (let b = 0; b * beat < out.length; b++) {
    const start = Math.floor(b * beat);
    for (let i = 0; i < rate * 0.12 && start + i < out.length; i++) {
      const t = i / rate;
      out[start + i] += Math.sin(2 * Math.PI * (50 + 120 * Math.exp(-t * 40)) * t) * Math.exp(-t * 18) * 0.8;
    }
    if (opts.hats) {
      const h = Math.floor(start + beat / 2);
      for (let i = 0; i < rate * 0.03 && h + i < out.length; i++) out[h + i] += (Math.random() * 2 - 1) * Math.exp(-(i / rate) * 120) * 0.25;
    }
  }
  return out;
}

const freq = (midi: number) => 440 * 2 ** ((midi - 69) / 12);

/** A chord progression (MIDI note lists), each chord held for `chordSeconds`, with soft harmonics. */
export function chords(progression: number[][], chordSeconds: number, rate = 44100) {
  const out = new Float32Array(Math.floor(progression.length * chordSeconds * rate));
  progression.forEach((notes, c) => {
    const start = Math.floor(c * chordSeconds * rate);
    for (let i = 0; i < chordSeconds * rate; i++) {
      const t = i / rate;
      let s = 0;
      for (const n of notes) for (let h = 1; h <= 3; h++) s += Math.sin(2 * Math.PI * freq(n) * h * t) / (h * h);
      out[start + i] = (s / notes.length) * 0.3;
    }
  });
  return out;
}

export const mix = (...parts: Float32Array[]) => {
  const n = Math.min(...parts.map((p) => p.length));
  const out = new Float32Array(n);
  for (const p of parts) for (let i = 0; i < n; i++) out[i] += p[i];
  return out;
};
