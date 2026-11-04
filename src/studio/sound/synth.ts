/**
 * A small subtractive synthesiser rendered sample by sample (deterministic, so the same patch
 * always makes the same sound): up to three oscillators with unison detune, a resonant
 * state-variable filter with its own envelope, an amp envelope, drive, chorus and a short reverb.
 */
export type Wave = 'sine' | 'triangle' | 'saw' | 'square' | 'noise';
export interface Env { a: number; d: number; s: number; r: number }
export interface Osc { wave: Wave; level: number; octave: number; detune: number }
export interface Patch {
  name: string;
  oscs: Osc[];
  unison: number; // voices per oscillator
  spread: number; // cents between unison voices
  filter: { type: 'lp' | 'bp' | 'hp'; cutoff: number; resonance: number; envAmount: number; env: Env; keyTrack: number };
  amp: Env;
  drive: number; // 0..1
  chorus: number; // 0..1
  reverb: { mix: number; size: number };
  glideBend?: number; // semitones the note slides from (e.g. 808s)
  gain: number;
}

export function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}

const envAt = (e: Env, t: number, held: number) => {
  const sustainLevel = (tt: number) => (tt < e.a ? tt / Math.max(1e-4, e.a) : tt < e.a + e.d ? 1 - (1 - e.s) * ((tt - e.a) / Math.max(1e-4, e.d)) : e.s);
  if (t < held) return sustainLevel(t);
  const atRelease = sustainLevel(held);
  const r = (t - held) / Math.max(1e-3, e.r);
  return r >= 1 ? 0 : atRelease * (1 - r) * (1 - r);
};

function osc(wave: Wave, phase: number, noise: () => number) {
  const p = phase - Math.floor(phase);
  switch (wave) {
    case 'sine': return Math.sin(2 * Math.PI * p);
    case 'triangle': return 1 - 4 * Math.abs(p - 0.5);
    case 'saw': return 2 * p - 1;
    case 'square': return p < 0.5 ? 1 : -1;
    default: return noise() * 2 - 1;
  }
}

/** Renders one note (`midi` pitch, held for `held` seconds) to stereo. */
export function renderNote(patch: Patch, midi: number, held: number, sampleRate = 44100, velocity = 1): Float32Array[] {
  const tail = patch.amp.r + patch.reverb.size * 1.5 * (patch.reverb.mix > 0 ? 1 : 0);
  const n = Math.ceil((held + tail + 0.02) * sampleRate);
  const L = new Float32Array(n), R = new Float32Array(n);
  const noise = rng(midi * 7919 + 13);
  const freq = 440 * 2 ** ((midi - 69) / 12);
  const voices: { inc: number; phase: number; pan: number; level: number; wave: Wave }[] = [];
  for (const o of patch.oscs) {
    const u = Math.max(1, Math.round(patch.unison));
    for (let v = 0; v < u; v++) {
      const cents = o.detune + (u > 1 ? (v / (u - 1) - 0.5) * patch.spread : 0);
      voices.push({ inc: (freq * 2 ** o.octave * 2 ** (cents / 1200)) / sampleRate, phase: noise(), pan: u > 1 ? v / (u - 1) - 0.5 : 0, level: o.level / Math.sqrt(u), wave: o.wave });
    }
  }
  // state variable filter per channel
  let lowL = 0, bandL = 0, lowR = 0, bandR = 0;
  const f = patch.filter;
  const keyCut = f.cutoff * 2 ** (((midi - 60) / 12) * f.keyTrack);
  for (let i = 0; i < n; i++) {
    const t = i / sampleRate;
    const bend = patch.glideBend ? 2 ** ((patch.glideBend * Math.exp(-t * 18)) / 12) : 1;
    let sl = 0, sr = 0;
    for (const v of voices) {
      v.phase += v.inc * bend;
      const s = osc(v.wave, v.phase, noise) * v.level;
      sl += s * (0.5 - v.pan * 0.8); sr += s * (0.5 + v.pan * 0.8);
    }
    const fe = envAt(f.env, t, held);
    const cutoff = Math.min(sampleRate * 0.45, Math.max(30, keyCut * 2 ** (f.envAmount * fe)));
    const F = 2 * Math.sin((Math.PI * cutoff) / sampleRate);
    const Q = 1 / Math.max(0.5, 0.7 + f.resonance * 6);
    for (const ch of [0, 1]) {
      const x = ch === 0 ? sl : sr;
      let low = ch === 0 ? lowL : lowR, band = ch === 0 ? bandL : bandR;
      low += F * band;
      const high = x - low - Q * band;
      band += F * high;
      if (!Number.isFinite(low) || Math.abs(low) > 50) { low = 0; band = 0; }
      const y = f.type === 'lp' ? low : f.type === 'bp' ? band : high;
      if (ch === 0) { lowL = low; bandL = band; L[i] = y; } else { lowR = low; bandR = band; R[i] = y; }
    }
    const a = envAt(patch.amp, t, held) * velocity * patch.gain;
    L[i] *= a; R[i] *= a;
    if (patch.drive > 0) { const k = 1 + patch.drive * 8; L[i] = Math.tanh(L[i] * k) / Math.tanh(k) ; R[i] = Math.tanh(R[i] * k) / Math.tanh(k); }
  }
  if (patch.chorus > 0) chorus(L, R, sampleRate, patch.chorus);
  if (patch.reverb.mix > 0) reverb(L, R, sampleRate, patch.reverb.mix, patch.reverb.size);
  return [L, R];
}

function chorus(L: Float32Array, R: Float32Array, sr: number, amount: number) {
  const n = L.length, max = Math.ceil(0.03 * sr);
  const dl = L.slice(), dr = R.slice();
  for (let i = max; i < n; i++) {
    const m = (0.012 + 0.004 * Math.sin((2 * Math.PI * 0.8 * i) / sr)) * sr;
    const j = i - m, k = Math.floor(j), fr = j - k;
    L[i] += amount * 0.5 * (dl[k] * (1 - fr) + dl[k + 1] * fr);
    const m2 = (0.014 + 0.004 * Math.cos((2 * Math.PI * 0.67 * i) / sr)) * sr;
    const j2 = i - m2, k2 = Math.floor(j2), fr2 = j2 - k2;
    R[i] += amount * 0.5 * (dr[k2] * (1 - fr2) + dr[k2 + 1] * fr2);
  }
}

/** A compact Schroeder-style reverb (4 combs + 2 allpasses per side). */
export function reverb(L: Float32Array, R: Float32Array, sr: number, mix: number, size: number) {
  const combs = [1116, 1188, 1277, 1356].map((d) => Math.round((d * sr) / 44100 * (0.6 + size * 0.8)));
  const aps = [556, 441].map((d) => Math.round((d * sr) / 44100));
  const fb = 0.7 + size * 0.25;
  for (const [x, off] of [[L, 0], [R, 23]] as const) {
    const dry = x.slice();
    const wet = new Float32Array(x.length);
    for (const d0 of combs) {
      const d = d0 + off, buf = new Float32Array(d);
      let p = 0, lp = 0;
      for (let i = 0; i < x.length; i++) { const y = buf[p]; lp = y * 0.8 + lp * 0.2; buf[p] = dry[i] * 0.25 + lp * fb; wet[i] += y; p = (p + 1) % d; }
    }
    for (const d0 of aps) {
      const d = d0 + off, buf = new Float32Array(d);
      let p = 0;
      for (let i = 0; i < x.length; i++) { const b = buf[p]; const y = -wet[i] + b; buf[p] = wet[i] + b * 0.5; wet[i] = y; p = (p + 1) % d; }
    }
    for (let i = 0; i < x.length; i++) x[i] = dry[i] * (1 - mix * 0.5) + wet[i] * mix * 0.35;
  }
}

export const DEFAULT_PATCH: Patch = {
  name: 'Init',
  oscs: [{ wave: 'saw', level: 0.6, octave: 0, detune: 0 }],
  unison: 1, spread: 0,
  filter: { type: 'lp', cutoff: 2400, resonance: 0.15, envAmount: 1, env: { a: 0.005, d: 0.4, s: 0.3, r: 0.3 }, keyTrack: 0.5 },
  amp: { a: 0.005, d: 0.3, s: 0.7, r: 0.3 },
  drive: 0, chorus: 0, reverb: { mix: 0.15, size: 0.4 }, gain: 0.8,
};
