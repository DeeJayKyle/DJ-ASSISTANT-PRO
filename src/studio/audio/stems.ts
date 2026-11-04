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
  // A fixed pool of frames, reused as a ring (no per-frame allocation).
  const pool: Frame[] = Array.from({ length: MED }, () => ({ lr: new Float32Array(bins), li: new Float32Array(bins), rr: new Float32Array(bins), ri: new Float32Array(bins), mag: new Float32Array(bins), start: 0 }));
  let ringStart = 0, ringLen = 0; // ring = pool[(ringStart + i) % MED] for i < ringLen
  const zr = new Float64Array(N), zi = new Float64Array(N);

  // Both channels in one forward FFT: z = l + i·r, then XL = (Z[k] + conj Z[N-k]) / 2, XR = (Z[k] − conj Z[N-k]) / 2i.
  const analyse = (start: number, f: Frame) => {
    for (let i = 0; i < N; i++) {
      const j = start + i, q = j - inStart;
      const inside = j >= 0 && j < len && q >= 0 && q < L.length;
      zr[i] = inside ? L[q] * win[i] : 0;
      zi[i] = inside ? R[q] * win[i] : 0;
    }
    fft(zr, zi);
    for (let k = 0; k < bins; k++) {
      const m = k === 0 ? 0 : N - k;
      const ar = zr[k], ai = zi[k], cr = zr[m], ci = zi[m];
      const lr = (ar + cr) / 2, li = (ai - ci) / 2, rr = (ai + ci) / 2, ri = -(ar - cr) / 2;
      f.lr[k] = lr; f.li[k] = li; f.rr[k] = rr; f.ri[k] = ri;
      f.mag[k] = (Math.sqrt(lr * lr + li * li) + Math.sqrt(rr * rr + ri * ri)) / 2;
    }
    f.start = start;
  };

  // Per-bin sorted windows of the last MED magnitudes, updated as frames arrive (running time median).
  const tWin = new Float32Array(bins * MED);
  let tCount = 0;
  const sortedInsert = (arr: Float32Array, off: number, n: number, v: number) => {
    let i = off + n - 1;
    while (i >= off && arr[i] > v) { arr[i + 1] = arr[i]; i--; }
    arr[i + 1] = v;
  };
  const sortedRemove = (arr: Float32Array, off: number, n: number, v: number) => {
    let i = off;
    const end = off + n;
    while (i < end && arr[i] !== v) i++;
    for (; i < end - 1; i++) arr[i] = arr[i + 1];
  };
  const fSorted = new Float32Array(MED);

  const sre = new Float64Array(N), sim = new Float64Array(N);
  const masks = [new Float32Array(bins), new Float32Array(bins), new Float32Array(bins), new Float32Array(bins)];
  // Both channels in one inverse FFT: x = ifft(XL + i·XR) has xL as its real part and xR as its imaginary part.
  const synth = (f: Frame) => {
    // Melodies are what's left (the masks add up to one), so only three stems need an inverse FFT.
    for (let s = 0; s < 3; s++) {
      const stem = STEMS[s];
      const m = masks[s];
      for (let k = 0; k < bins; k++) {
        const g = m[k];
        const lr = f.lr[k] * g, li = f.li[k] * g, rr = f.rr[k] * g, ri = f.ri[k] * g;
        sre[k] = lr - ri; sim[k] = -(li + rr);
        if (k > 0 && k < N / 2) { sre[N - k] = lr + ri; sim[N - k] = li - rr; }
      }
      fft(sre, sim);
      const dl = out[stem][0], dr = out[stem][1];
      for (let i = 0; i < N; i++) {
        const j = f.start + i - spanStart;
        if (j < 0 || j >= span) continue;
        const w = win[i] / N;
        dl[j] += sre[i] * w; dr[j] -= sim[i] * w;
      }
    }
    const ml = out.melodies[0], mr = out.melodies[1];
    for (let i = 0; i < N; i++) {
      const j = f.start + i - spanStart;
      if (j < 0 || j >= span) continue;
      const w2 = win[i] * win[i];
      norm[j] += w2;
      const q = f.start + i - inStart;
      if (q >= 0 && q < L.length && f.start + i < len) { ml[j] += L[q] * w2; mr[j] += R[q] * w2; }
    }
  };

  const first = Math.max(0, f0 - HALF), last = Math.min(frames, f1 + HALF); // frames to analyse
  for (let t = first; t < last + HALF; t++) {
    if (t < last) {
      // reuse the oldest frame slot once the ring is full
      let slot: Frame;
      if (ringLen < MED) { slot = pool[(ringStart + ringLen) % MED]; ringLen++; }
      else {
        slot = pool[ringStart];
        for (let k = 0; k < bins; k++) sortedRemove(tWin, k * MED, MED, slot.mag[k]);
        tCount = MED - 1;
        ringStart = (ringStart + 1) % MED;
      }
      analyse(t * HOP - PAD, slot);
      for (let k = 0; k < bins; k++) sortedInsert(tWin, k * MED, tCount, slot.mag[k]);
      tCount++;
    }
    const centre = t - HALF;
    if (centre < f0 || centre >= f1) continue;
    const newest = Math.min(t, last - 1);
    const back = newest - centre;
    if (back >= ringLen) continue;
    const f = pool[(ringStart + ringLen - 1 - back) % MED];
    const full = tCount === MED;
    const mag = f.mag;
    // running frequency median: start with the window around bin 0 (edges clamped)
    let fn = 0;
    for (let d = -HALF; d <= HALF; d++) sortedInsert(fSorted, 0, fn++, mag[Math.min(bins - 1, Math.max(0, d))]);
    for (let k = 0; k < bins; k++) {
      if (k > 0) {
        sortedRemove(fSorted, 0, MED, mag[Math.max(0, k - 1 - HALF)]);
        sortedInsert(fSorted, 0, MED - 1, mag[Math.min(bins - 1, k + HALF)]);
      }
      const H = full ? tWin[k * MED + HALF] : mag[k];
      const P = fSorted[HALF];
      const h = (H * H) / (H * H + P * P + 1e-12);
      const p = 1 - h;
      const lr = f.lr[k], li = f.li[k], rr = f.rr[k], ri = f.ri[k];
      const e = lr * lr + li * li + rr * rr + ri * ri;
      const c = e > 1e-24 ? Math.max(0, (2 * (lr * rr + li * ri)) / (e + 1e-12)) : 0;
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
  // melodies = (windowed mix) − vocals − drums − bass, all still un-normalised
  for (let c = 0; c < 2; c++) {
    const m = out.melodies[c], v = out.vocals[c], d = out.drums[c], b = out.bass[c];
    for (let i = 0; i < span; i++) m[i] -= v[i] + d[i] + b[i];
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
