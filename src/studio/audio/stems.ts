import { fft } from '../dsp/fft';

/**
 * Four-stem separation on this computer: vocals, drums, bass and melodies.
 *
 * Method (signal processing, no AI model): a short-time Fourier transform of both channels,
 * harmonic/percussive separation by median filtering (along time for sustained sounds, along
 * frequency for hits), a centre-panning measure (lead vocals sit in the middle of the stereo
 * image), and frequency bands for bass and voice. Each time-frequency point is shared between
 * the four stems by soft masks that always add up to one, so the stems add back up to the
 * original mix exactly. It's fast and private, but it is not as clean as AI separators.
 */
export type StemName = 'vocals' | 'drums' | 'bass' | 'melodies';
export const STEMS: StemName[] = ['vocals', 'drums', 'bass', 'melodies'];
export type Stems = Record<StemName, Float32Array[]>;

const N = 4096;
const HOP = 1024;
const MED = 17; // median window (frames for time, bins for frequency)

function median(a: Float32Array, scratch: Float32Array) {
  scratch.set(a);
  // insertion sort: tiny arrays
  for (let i = 1; i < scratch.length; i++) {
    const x = scratch[i];
    let j = i - 1;
    while (j >= 0 && scratch[j] > x) { scratch[j + 1] = scratch[j]; j--; }
    scratch[j + 1] = x;
  }
  return scratch[scratch.length >> 1];
}

const smooth = (x: number, a: number, b: number) => (x <= a ? 0 : x >= b ? 1 : ((x - a) / (b - a)) ** 2 * (3 - 2 * (x - a) / (b - a)));

const WIN = (() => { const w = new Float32Array(N); for (let i = 0; i < N; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N); return w; })(); // periodic Hann
const HALF = MED >> 1;
const PAD = N; // frames start before 0 so the edges are covered

/** Number of analysis frames for a signal of `len` samples. */
export const frameCount = (len: number) => Math.ceil((len + N) / HOP) + 1;

/** One piece of a separation job: the frames whose results it computes, and the input it needs. */
export interface PartPlan { f0: number; f1: number; inStart: number; inEnd: number }
export function planParts(len: number, parts: number): PartPlan[] {
  const frames = frameCount(len);
  const per = Math.ceil(frames / Math.max(1, parts));
  const out: PartPlan[] = [];
  for (let f0 = 0; f0 < frames; f0 += per) {
    const f1 = Math.min(frames, f0 + per);
    out.push({ f0, f1, inStart: Math.max(0, (f0 - HALF) * HOP - PAD), inEnd: Math.min(len, (f1 + HALF) * HOP - PAD + N) });
  }
  return out;
}

/** The result of one part: stem audio and window weights over samples [start, start + length). */
export interface Part { start: number; stems: Stems; norm: Float32Array }

/**
 * Separates frames [f0, f1) of a signal of `len` samples. `channels` hold samples from
 * `inStart` (a slice is enough). Parts of the same song add up to the whole.
 */
export function separatePart(channels: Float32Array[], inStart: number, len: number, sampleRate: number, f0: number, f1: number, onProgress?: (fraction: number) => void): Part {
  const L = channels[0];
  const R = channels[1] ?? channels[0];
  const frames = frameCount(len);
  const bins = N / 2 + 1;
  const spanStart = Math.max(0, f0 * HOP - PAD);
  const spanEnd = Math.min(len, (f1 - 1) * HOP - PAD + N);
  const span = Math.max(0, spanEnd - spanStart);
  const mk = () => [new Float32Array(span), new Float32Array(span)];
  const out: Stems = { vocals: mk(), drums: mk(), bass: mk(), melodies: mk() };
  const norm = new Float32Array(span);
  const win = WIN;

  // Frequency weights depend only on the bin.
  const vocalBand = new Float32Array(bins);
  const bassBand = new Float32Array(bins);
  for (let k = 0; k < bins; k++) {
    const f = (k * sampleRate) / N;
    vocalBand[k] = smooth(f, 110, 220) * (1 - smooth(f, 6000, 9500));
    bassBand[k] = 1 - smooth(f, 140, 260);
  }

  type Frame = { lr: Float32Array; li: Float32Array; rr: Float32Array; ri: Float32Array; mag: Float32Array; start: number };
  const ring: Frame[] = [];
  const reL = new Float64Array(N), imL = new Float64Array(N), reR = new Float64Array(N), imR = new Float64Array(N);
  const tScratch = new Float32Array(MED), tVals = new Float32Array(MED);
  const fScratch = new Float32Array(MED), fVals = new Float32Array(MED);

  const analyse = (start: number): Frame => {
    for (let i = 0; i < N; i++) {
      const j = start + i, q = j - inStart;
      const w = win[i];
      const inside = j >= 0 && j < len && q >= 0 && q < L.length;
      reL[i] = inside ? L[q] * w : 0; imL[i] = 0;
      reR[i] = inside ? R[q] * w : 0; imR[i] = 0;
    }
    fft(reL, imL); fft(reR, imR);
    const f: Frame = { lr: new Float32Array(bins), li: new Float32Array(bins), rr: new Float32Array(bins), ri: new Float32Array(bins), mag: new Float32Array(bins), start };
    for (let k = 0; k < bins; k++) {
      f.lr[k] = reL[k]; f.li[k] = imL[k]; f.rr[k] = reR[k]; f.ri[k] = imR[k];
      f.mag[k] = (Math.hypot(reL[k], imL[k]) + Math.hypot(reR[k], imR[k])) / 2;
    }
    return f;
  };

  const sre = new Float64Array(N), sim = new Float64Array(N);
  const masks = [new Float32Array(bins), new Float32Array(bins), new Float32Array(bins), new Float32Array(bins)];
  // Both channels in one inverse FFT: x = ifft(XL + i·XR) has xL as its real part and xR as its imaginary part.
  const synth = (f: Frame) => {
    STEMS.forEach((stem, s) => {
      const m = masks[s];
      for (let k = 0; k < bins; k++) {
        const lr = f.lr[k] * m[k], li = f.li[k] * m[k], rr = f.rr[k] * m[k], ri = f.ri[k] * m[k];
        sre[k] = lr - ri; sim[k] = li + rr;
        if (k > 0 && k < N / 2) { sre[N - k] = lr + ri; sim[N - k] = -li + rr; }
      }
      for (let k = 0; k < N; k++) sim[k] = -sim[k];
      fft(sre, sim);
      const dl = out[stem][0], dr = out[stem][1];
      for (let i = 0; i < N; i++) {
        const j = f.start + i - spanStart;
        if (j < 0 || j >= span) continue;
        const w = win[i] / N;
        dl[j] += sre[i] * w; dr[j] -= sim[i] * w;
      }
    });
    for (let i = 0; i < N; i++) { const j = f.start + i - spanStart; if (j >= 0 && j < span) norm[j] += win[i] * win[i]; }
  };

  const first = Math.max(0, f0 - HALF), last = Math.min(frames, f1 + HALF); // frames to analyse
  for (let t = first; t < last + HALF; t++) {
    if (t < last) { ring.push(analyse(t * HOP - PAD)); if (ring.length > MED) ring.shift(); }
    const centre = t - HALF;
    if (centre < f0 || centre >= f1) continue;
    const newest = Math.min(t, last - 1);
    const f = ring[ring.length - 1 - (newest - centre)];
    if (!f) continue;
    const full = ring.length === MED;
    for (let k = 0; k < bins; k++) {
      let H = f.mag[k];
      if (full) { for (let q = 0; q < MED; q++) tVals[q] = ring[q].mag[k]; H = median(tVals, tScratch); }
      for (let d = -HALF; d <= HALF; d++) fVals[d + HALF] = f.mag[Math.min(bins - 1, Math.max(0, k + d))];
      const P = median(fVals, fScratch);
      const h = (H * H) / (H * H + P * P + 1e-12);
      const p = 1 - h;
      const ml = Math.hypot(f.lr[k], f.li[k]), mr = Math.hypot(f.rr[k], f.ri[k]);
      const dot = f.lr[k] * f.rr[k] + f.li[k] * f.ri[k];
      const c = ml + mr > 1e-12 ? Math.max(0, (2 * dot) / (ml * ml + mr * mr + 1e-12)) : 0;
      const centred = c * c * vocalBand[k];
      const v = h * centred;
      const b = h * bassBand[k] * (1 - centred);
      const d = p * (1 - 0.5 * centred);
      const m = h * (1 - centred) * (1 - bassBand[k]);
      const sum = v + b + d + m;
      if (sum > 1e-9) { masks[0][k] = v / sum; masks[1][k] = d / sum; masks[2][k] = b / sum; masks[3][k] = m / sum; }
      else { masks[0][k] = 0; masks[1][k] = 0; masks[2][k] = 0; masks[3][k] = 1; }
    }
    synth(f);
    if (onProgress && centre % 64 === 0) onProgress(Math.min(1, (centre - f0) / Math.max(1, f1 - f0)));
  }
  onProgress?.(1);
  return { start: spanStart, stems: out, norm };
}

/** Adds parts together and applies the overlap-add normalisation. */
export function mergeParts(parts: Part[], len: number, channels = 2): Stems {
  const out: Stems = { vocals: [], drums: [], bass: [], melodies: [] };
  for (const st of STEMS) out[st] = [new Float32Array(len), new Float32Array(len)];
  const norm = new Float32Array(len);
  for (const p of parts) {
    for (let i = 0; i < p.norm.length; i++) norm[p.start + i] += p.norm[i];
    for (const st of STEMS) for (let c = 0; c < 2; c++) { const d = out[st][c], s = p.stems[st][c]; for (let i = 0; i < s.length; i++) d[p.start + i] += s[i]; }
  }
  for (const st of STEMS) for (const ch of out[st]) for (let i = 0; i < len; i++) ch[i] = norm[i] > 1e-6 ? ch[i] / norm[i] : 0;
  if (channels === 1) for (const st of STEMS) out[st] = [out[st][0]];
  return out;
}

/** Separates a whole song in this thread. */
export function separate(channels: Float32Array[], sampleRate: number, onProgress?: (fraction: number) => void): Stems {
  const len = channels[0].length;
  const part = separatePart(channels, 0, len, sampleRate, 0, frameCount(len), onProgress);
  return mergeParts([part], len, channels.length);
}

/** Everything but the vocals. */
export function instrumental(stems: Stems): Float32Array[] {
  return stems.drums.map((_, c) => {
    const o = new Float32Array(stems.drums[c].length);
    for (const s of ['drums', 'bass', 'melodies'] as StemName[]) { const x = stems[s][c]; for (let i = 0; i < o.length; i++) o[i] += x[i]; }
    return o;
  });
}
