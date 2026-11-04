import { downsample, magnitudes } from './fft';

/**
 * Tempo from the onset strength (spectral flux) envelope: its autocorrelation is scored with a
 * comb over the first beats of each candidate tempo, on a fine grid, so the estimate is precise to
 * a fraction of a BPM. Candidates are weighted towards the range DJs mix in (about 85–175 BPM).
 */
export interface TempoResult {
  bpm: number;
  confidence: number;
}

const TARGET_RATE = 11025;
const FRAME = 1024;
const HOP = 128;

export function onsetEnvelope(mono: Float32Array, sampleRate: number) {
  const factor = Math.max(1, Math.round(sampleRate / TARGET_RATE));
  const x = downsample(mono, factor);
  const rate = sampleRate / factor;
  const frames = Math.max(0, Math.floor((x.length - FRAME) / HOP));
  const env = new Float64Array(frames);
  let prev = new Float64Array(FRAME / 2);
  let cur = new Float64Array(FRAME / 2);
  for (let f = 0; f < frames; f++) {
    magnitudes(x, f * HOP, FRAME, cur);
    let flux = 0;
    // Up to ~5.5 kHz; log compression makes quiet hats count alongside loud kicks.
    for (let k = 1; k < FRAME / 2; k++) {
      const v = Math.log1p(100 * cur[k]);
      const d = v - prev[k];
      if (d > 0) flux += d;
      prev[k] = v;
    }
    env[f] = flux;
  }
  // Remove the slowly varying part so only the attacks remain.
  const win = Math.round((rate / HOP) * 0.5);
  const out = new Float64Array(frames);
  let acc = 0;
  for (let i = 0; i < frames; i++) {
    acc += env[i];
    if (i >= win) acc -= env[i - win];
    const mean = acc / Math.min(i + 1, win);
    out[i] = Math.max(0, env[i] - mean);
  }
  return { env: out, rate: rate / HOP };
}

function autocorrelation(env: Float64Array, maxLag: number) {
  const n = env.length;
  let mean = 0;
  for (let i = 0; i < n; i++) mean += env[i];
  mean /= n || 1;
  const ac = new Float64Array(maxLag + 2);
  for (let lag = 0; lag <= maxLag + 1; lag++) {
    let s = 0;
    for (let i = 0; i + lag < n; i++) s += (env[i] - mean) * (env[i + lag] - mean);
    ac[lag] = s / (n - lag || 1);
  }
  return ac;
}

const at = (ac: Float64Array, x: number) => {
  const i = Math.floor(x);
  const f = x - i;
  return i + 1 < ac.length ? ac[i] * (1 - f) + ac[i + 1] * f : 0;
};

export function detectTempo(mono: Float32Array, sampleRate: number, opts: { min?: number; max?: number } = {}): TempoResult {
  const min = opts.min ?? 60;
  const max = opts.max ?? 200;
  const { env, rate } = onsetEnvelope(mono, sampleRate);
  if (env.length < rate * 4) return { bpm: 0, confidence: 0 };
  const beatsInComb = 8;
  const maxLag = Math.ceil(((60 / min) * rate) * beatsInComb);
  const ac = autocorrelation(env, Math.min(maxLag, env.length - 2));
  const score = (bpm: number) => {
    const period = (60 / bpm) * rate;
    let s = 0;
    let n = 0;
    for (let k = 1; k <= beatsInComb; k++) {
      const lag = period * k;
      if (lag >= ac.length - 1) break;
      s += at(ac, lag);
      n++;
    }
    return n ? s / n : 0;
  };
  // Prefer the usual DJ range, gently: a log-normal weight around 125 BPM.
  const prior = (bpm: number) => Math.exp(-0.5 * (Math.log2(bpm / 125) / 0.9) ** 2);
  let best = 0;
  let bestScore = -Infinity;
  const scores: [number, number][] = [];
  for (let bpm = min; bpm <= max; bpm += 0.05) {
    const s = score(bpm) * prior(bpm);
    scores.push([bpm, s]);
    if (s > bestScore) {
      bestScore = s;
      best = bpm;
    }
  }
  // Octave check: a strong half/double tempo inside 85–175 wins over an out-of-range pick.
  if (best < 85 && score(best * 2) > 0.5 * score(best)) best *= 2;
  else if (best > 175 && score(best / 2) > 0.5 * score(best)) best /= 2;
  // Confidence: how far the peak stands above the typical score.
  const sorted = scores.map((s) => s[1]).sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  const top = Math.max(bestScore, 1e-12);
  const confidence = Math.max(0, Math.min(1, (top - median) / top));
  return { bpm: Math.round(best * 10) / 10, confidence: Math.round(confidence * 100) / 100 };
}
