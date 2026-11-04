import { downsample, magnitudes } from './fft';

/**
 * Musical key from a chromagram (energy per pitch class, from the spectrum between ~55 Hz and
 * ~2 kHz), correlated with major and minor key profiles (Krumhansl–Kessler). Reported as a key
 * name and its Camelot code, the wheel DJs use for harmonic mixing.
 */
export const PITCHES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'] as const;
const FLAT_NAMES: Record<string, string> = { 'C#': 'Db', 'D#': 'Eb', 'F#': 'F#', 'G#': 'Ab', 'A#': 'Bb' };

const MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const MINOR = [6.33, 2.68, 3.52, 5.38, 2.6, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

/** Camelot codes: minor keys are "A", major keys are "B". */
const CAMELOT_MINOR: Record<string, string> = { 'G#': '1A', 'D#': '2A', 'A#': '3A', F: '4A', C: '5A', G: '6A', D: '7A', A: '8A', E: '9A', B: '10A', 'F#': '11A', 'C#': '12A' };
const CAMELOT_MAJOR: Record<string, string> = { B: '1B', 'F#': '2B', 'C#': '3B', 'G#': '4B', 'D#': '5B', 'A#': '6B', F: '7B', C: '8B', G: '9B', D: '10B', A: '11B', E: '12B' };

export interface KeyResult {
  /** e.g. "A minor" */
  key: string;
  /** e.g. "Am" */
  short: string;
  /** e.g. "8A" */
  camelot: string;
  confidence: number;
  /** 0 = C … 11 = B */
  tonic: number;
  mode: 'major' | 'minor';
}

export function keyFrom(tonic: number, mode: 'major' | 'minor', confidence = 1): KeyResult {
  const p = PITCHES[tonic];
  const name = mode === 'minor' && (p === 'D#' || p === 'A#' || p === 'G#') ? FLAT_NAMES[p] : mode === 'major' && p.includes('#') && p !== 'F#' ? FLAT_NAMES[p] : p;
  return {
    key: `${name} ${mode}`,
    short: `${name}${mode === 'minor' ? 'm' : ''}`,
    camelot: (mode === 'minor' ? CAMELOT_MINOR : CAMELOT_MAJOR)[p],
    confidence: Math.round(confidence * 100) / 100,
    tonic,
    mode,
  };
}

export function chromagram(mono: Float32Array, sampleRate: number) {
  const factor = Math.max(1, Math.round(sampleRate / 11025));
  const x = downsample(mono, factor);
  const rate = sampleRate / factor;
  const size = 8192;
  const hop = 4096;
  const chroma = new Float64Array(12);
  // The bassline usually sits on the tonic, which tells a key from its relative major/minor.
  const bass = new Float64Array(12);
  const mags = new Float64Array(size / 2);
  for (let start = 0; start + size <= x.length; start += hop) {
    magnitudes(x, start, size, mags);
    const frame = new Float64Array(12);
    const low = new Float64Array(12);
    for (let k = 1; k < size / 2; k++) {
      const f = (k * rate) / size;
      if (f < 55 || f > 2000) continue;
      const midi = 69 + 12 * Math.log2(f / 440);
      const nearest = Math.round(midi);
      // Only bins close to a semitone centre count, so noise between notes doesn't smear the profile.
      if (Math.abs(midi - nearest) > 0.3) continue;
      const pc = ((nearest % 12) + 12) % 12;
      frame[pc] += mags[k] * mags[k];
      if (f < 200) low[pc] += mags[k] * mags[k];
    }
    let sum = 0;
    for (const v of frame) sum += v;
    if (sum > 0) for (let i = 0; i < 12; i++) chroma[i] += Math.sqrt(frame[i] / sum);
    let lowSum = 0;
    for (const v of low) lowSum += v;
    if (lowSum > 0) for (let i = 0; i < 12; i++) bass[i] += Math.sqrt(low[i] / lowSum);
  }
  return { chroma, bass };
}

function correlation(a: ArrayLike<number>, b: ArrayLike<number>) {
  const n = a.length;
  let ma = 0;
  let mb = 0;
  for (let i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  let num = 0;
  let da = 0;
  let db = 0;
  for (let i = 0; i < n; i++) {
    num += (a[i] - ma) * (b[i] - mb);
    da += (a[i] - ma) ** 2;
    db += (b[i] - mb) ** 2;
  }
  return da && db ? num / Math.sqrt(da * db) : 0;
}

export function keyFromChroma(chroma: ArrayLike<number>, bass?: ArrayLike<number>): KeyResult {
  let bassMax = 0;
  if (bass) for (let i = 0; i < 12; i++) bassMax = Math.max(bassMax, bass[i]);
  const results: { tonic: number; mode: 'major' | 'minor'; r: number }[] = [];
  for (let tonic = 0; tonic < 12; tonic++) {
    const rotated = Array.from({ length: 12 }, (_, i) => chroma[(i + tonic) % 12]);
    // A strong bass on the candidate tonic nudges it ahead of its relative key.
    const tonicBass = bass && bassMax > 0 ? (bass[tonic] / bassMax) * 0.12 : 0;
    results.push({ tonic, mode: 'major', r: correlation(rotated, MAJOR) + tonicBass });
    results.push({ tonic, mode: 'minor', r: correlation(rotated, MINOR) + tonicBass });
  }
  results.sort((a, b) => b.r - a.r);
  const [best, second] = results;
  const confidence = Math.max(0, Math.min(1, (best.r - second.r) * 4 + Math.max(0, best.r) * 0.5));
  return keyFrom(best.tonic, best.mode, confidence);
}

export function detectKey(mono: Float32Array, sampleRate: number) {
  const { chroma, bass } = chromagram(mono, sampleRate);
  return keyFromChroma(chroma, bass);
}

/** Reads a key written in tags ("Am", "A minor", "8A", "F#m"…) into a KeyResult. */
export function parseKey(text: string | undefined): KeyResult | null {
  if (!text) return null;
  const t = text.trim();
  const cam = t.match(/^(1[0-2]|[1-9])\s*([AB])$/i);
  if (cam) {
    const code = `${cam[1]}${cam[2].toUpperCase()}`;
    const table = code.endsWith('A') ? CAMELOT_MINOR : CAMELOT_MAJOR;
    const p = Object.keys(table).find((k) => table[k] === code);
    return p ? keyFrom(PITCHES.indexOf(p as any), code.endsWith('A') ? 'minor' : 'major') : null;
  }
  const m = t.match(/^([A-Ga-g])\s*([#b♯♭]?)\s*(m(?!aj)|min(?:or)?|maj(?:or)?|major|minor)?$/);
  if (!m) return null;
  const flats: Record<string, string> = { Db: 'C#', Eb: 'D#', Gb: 'F#', Ab: 'G#', Bb: 'A#', Cb: 'B', Fb: 'E' };
  let name = m[1].toUpperCase() + (m[2] === '♯' ? '#' : m[2] === '♭' ? 'b' : m[2]);
  if (flats[name]) name = flats[name];
  if (name === 'E#') name = 'F';
  if (name === 'B#') name = 'C';
  const idx = PITCHES.indexOf(name as any);
  if (idx < 0) return null;
  const minor = !!m[3] && /^m(in)?/i.test(m[3]) && !/^maj/i.test(m[3]);
  return keyFrom(idx, minor ? 'minor' : 'major');
}

/** Camelot neighbours that mix well: same code, ±1 on the wheel, and the relative major/minor. */
export function compatibleCamelot(code: string) {
  const m = code.match(/^(\d+)([AB])$/);
  if (!m) return [];
  const n = Number(m[1]);
  const l = m[2];
  const wrap = (x: number) => ((x - 1 + 12) % 12) + 1;
  return [code, `${wrap(n + 1)}${l}`, `${wrap(n - 1)}${l}`, `${n}${l === 'A' ? 'B' : 'A'}`];
}
