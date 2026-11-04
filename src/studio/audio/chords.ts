import { downsample, magnitudes } from '../dsp/fft';

/**
 * Chord progression: a chroma vector every ~0.19 s, matched against major and minor triads,
 * smoothed with a Viterbi pass (chords tend to last), then merged into segments.
 */
export const NOTE_NAMES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];
export interface ChordSegment { start: number; end: number; name: string; root: number; quality: 'maj' | 'min' | 'none' }

const TEMPLATES: { root: number; quality: 'maj' | 'min'; v: number[] }[] = [];
for (let r = 0; r < 12; r++) for (const q of ['maj', 'min'] as const) {
  const v = new Array(12).fill(0);
  v[r] = 1; v[(r + (q === 'maj' ? 4 : 3)) % 12] = 0.8; v[(r + 7) % 12] = 0.8;
  TEMPLATES.push({ root: r, quality: q, v });
}

export const chordName = (root: number, quality: 'maj' | 'min' | 'none') => (quality === 'none' ? 'N.C.' : NOTE_NAMES[root] + (quality === 'min' ? 'm' : ''));

export function detectChords(mono: Float32Array, sampleRate: number): ChordSegment[] {
  const factor = Math.max(1, Math.round(sampleRate / 11025));
  const x = downsample(mono, factor);
  const rate = sampleRate / factor;
  const size = 4096, hop = 2048;
  const mags = new Float64Array(size / 2);
  const obs: number[][] = [];
  const energy: number[] = [];
  for (let s = 0; s + size <= x.length; s += hop) {
    magnitudes(x, s, size, mags);
    const c = new Array(12).fill(0);
    let e = 0;
    for (let k = 2; k < size / 2; k++) {
      const f = (k * rate) / size;
      if (f < 60 || f > 2100) continue;
      const midi = 69 + 12 * Math.log2(f / 440);
      const near = Math.round(midi);
      const w = Math.max(0, 1 - Math.abs(midi - near) * 2.5);
      if (!w) continue;
      const p = mags[k] * mags[k] * w;
      c[((near % 12) + 12) % 12] += f < 250 ? p * 1.6 : p; // bass notes say a lot about the root
      e += mags[k] * mags[k];
    }
    obs.push(c); energy.push(e);
  }
  if (!obs.length) return [];
  const maxE = Math.max(...energy, 1e-12);
  // emission scores: cosine similarity, "no chord" for near-silence
  const S = TEMPLATES.length + 1;
  const score = obs.map((c, t) => {
    const n = Math.hypot(...c) || 1;
    const row = TEMPLATES.map((tp) => { let d = 0; for (let i = 0; i < 12; i++) d += c[i] * tp.v[i]; return d / n / Math.hypot(...tp.v); });
    row.push(energy[t] / maxE < 0.002 ? 1 : 0.2);
    return row;
  });
  // Viterbi with a stay bonus
  const stay = 0.35;
  let prev = score[0].slice();
  const back: Int16Array[] = [];
  for (let t = 1; t < score.length; t++) {
    let bestPrev = 0;
    for (let j = 1; j < S; j++) if (prev[j] > prev[bestPrev]) bestPrev = j;
    const cur = new Array(S);
    const bk = new Int16Array(S);
    for (let j = 0; j < S; j++) {
      const keep = prev[j] + stay;
      if (keep >= prev[bestPrev]) { cur[j] = keep + score[t][j]; bk[j] = j; }
      else { cur[j] = prev[bestPrev] + score[t][j]; bk[j] = bestPrev; }
    }
    back.push(bk); prev = cur;
  }
  let state = 0;
  for (let j = 1; j < S; j++) if (prev[j] > prev[state]) state = j;
  const path = new Array(score.length);
  path[score.length - 1] = state;
  for (let t = score.length - 1; t > 0; t--) { state = back[t - 1][state]; path[t - 1] = state; }
  const sec = (t: number) => (t * hop + size / 2) / rate;
  const segs: ChordSegment[] = [];
  for (let t = 0; t < path.length; t++) {
    const st = path[t];
    const root = st < TEMPLATES.length ? TEMPLATES[st].root : 0;
    const quality = st < TEMPLATES.length ? TEMPLATES[st].quality : 'none';
    const last = segs[segs.length - 1];
    if (last && last.root === root && last.quality === quality) last.end = sec(t + 1);
    else segs.push({ start: t === 0 ? 0 : sec(t), end: sec(t + 1), name: chordName(root, quality), root, quality });
  }
  // fold very short blips into their neighbour
  return segs.filter((s, i) => s.end - s.start >= 0.4 || i === 0 || i === segs.length - 1).map((s, i, a) => (i > 0 ? { ...s, start: a[i - 1].end } : s));
}

export const chordAt = (segs: ChordSegment[], t: number) => segs.find((s) => t >= s.start && t < s.end) ?? null;
