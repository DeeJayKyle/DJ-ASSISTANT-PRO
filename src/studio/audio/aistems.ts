import { fft } from '../dsp/fft';
import { resample } from './stretch';

/**
 * AI stem separation with HTDemucs (Meta, MIT licence) exported to ONNX.
 *
 * The model takes a 7.8 s stereo segment as a waveform plus its spectrogram and returns,
 * for drums / bass / other / vocals, a spectrogram and a waveform that are added together.
 * The pre- and post-processing here follows the demucs-web reference (timcsy, MIT) exactly:
 * periodic Hann window, FFT 4096, hop 1024, 1/√N normalisation, reflect padding, frames 2…337.
 * Segments overlap by a quarter and are cross-faded.
 *
 * `run` is the model call (onnxruntime-web in the app); it is injected so the signal
 * path can be tested without the model.
 */
export const SR = 44100;
export const N_FFT = 4096;
export const HOP = 1024;
export const SEG = 343980;
export const BINS = 2048;
export const FRAMES = 336;
export const OVERLAP = 0.25;
export const AI_STEMS = ['drums', 'bass', 'other', 'vocals'] as const;

export type ModelRun = (waveform: Float32Array, spec: Float32Array) => Promise<{ freq: Float32Array | null; time: Float32Array }>;

const hannP = new Map<number, Float64Array>();
function hannPeriodic(n: number) {
  let w = hannP.get(n);
  if (!w) { w = new Float64Array(n); for (let i = 0; i < n; i++) w[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / n)); hannP.set(n, w); }
  return w;
}

export function reflectPad(x: Float32Array, left: number, right: number) {
  const n = x.length, out = new Float32Array(left + n + right);
  for (let i = 0; i < left; i++) out[i] = x[Math.min(left - i, n - 1)];
  out.set(x, left);
  for (let i = 0; i < right; i++) out[left + n + i] = x[Math.max(0, n - 2 - i)];
  return out;
}

/** Frame-major STFT: real/imag [frames × (N/2+1)]. */
export function stft(x: Float32Array) {
  const frames = Math.floor((x.length - N_FFT) / HOP) + 1, bins = N_FFT / 2 + 1;
  const w = hannPeriodic(N_FFT), scale = 1 / Math.sqrt(N_FFT);
  const real = new Float32Array(frames * bins), imag = new Float32Array(frames * bins);
  const re = new Float64Array(N_FFT), im = new Float64Array(N_FFT);
  for (let f = 0; f < frames; f++) {
    const s = f * HOP;
    for (let i = 0; i < N_FFT; i++) { re[i] = x[s + i] * w[i]; im[i] = 0; }
    fft(re, im);
    const o = f * bins;
    for (let k = 0; k < bins; k++) { real[o + k] = re[k] * scale; imag[o + k] = im[k] * scale; }
  }
  return { real, imag, frames, bins };
}

/** Inverse of `stft` (weighted overlap-add). */
export function istft(real: Float32Array, imag: Float32Array, frames: number, bins: number, length: number) {
  const out = new Float32Array(length), wsum = new Float32Array(length);
  const w = hannPeriodic(N_FFT), scale = Math.sqrt(N_FFT);
  const re = new Float64Array(N_FFT), im = new Float64Array(N_FFT);
  for (let f = 0; f < frames; f++) {
    re.fill(0); im.fill(0);
    for (let k = 0; k < bins; k++) { re[k] = real[f * bins + k]; im[k] = imag[f * bins + k]; }
    for (let k = 1; k < bins - 1; k++) { re[N_FFT - k] = re[k]; im[N_FFT - k] = -im[k]; }
    // inverse FFT = conj(FFT(conj(x))) / N
    for (let i = 0; i < N_FFT; i++) im[i] = -im[i];
    fft(re, im);
    const s = f * HOP;
    for (let i = 0; i < N_FFT && s + i < length; i++) {
      out[s + i] += (re[i] / N_FFT) * w[i] * scale;
      wsum[s + i] += w[i] * w[i];
    }
  }
  for (let i = 0; i < length; i++) if (wsum[i] > 1e-8) out[i] /= wsum[i];
  return out;
}

/** Model inputs for one segment: waveform [2 × SEG] and spectrogram [4 × BINS × FRAMES]. */
export function prepare(left: Float32Array, right: Float32Array) {
  const l = new Float32Array(SEG), r = new Float32Array(SEG);
  l.set(left.subarray(0, Math.min(SEG, left.length))); r.set(right.subarray(0, Math.min(SEG, right.length)));
  const le = Math.ceil(SEG / HOP), pad = Math.floor(HOP / 2) * 3, padR = pad + le * HOP - SEG, c = N_FFT / 2;
  const sl = stft(reflectPad(reflectPad(l, pad, padR), c, c)), sr = stft(reflectPad(reflectPad(r, pad, padR), c, c));
  const spec = new Float32Array(4 * BINS * FRAMES), plane = BINS * FRAMES;
  for (let f = 0; f < FRAMES; f++) {
    const src = (f + 2) * sl.bins;
    for (let b = 0; b < BINS; b++) {
      const o = b * FRAMES + f;
      spec[o] = sl.real[src + b]; spec[plane + o] = sl.imag[src + b];
      spec[2 * plane + o] = sr.real[src + b]; spec[3 * plane + o] = sr.imag[src + b];
    }
  }
  const waveform = new Float32Array(2 * SEG);
  waveform.set(l, 0); waveform.set(r, SEG);
  return { waveform, spec };
}

/** One stem's spectrogram output [4 × BINS × FRAMES] back to a stereo waveform of SEG samples. */
export function inverse(freq: Float32Array, stem: number): [Float32Array, Float32Array] {
  const plane = BINS * FRAMES, base = stem * 4 * plane, pb = BINS + 1, pf = FRAMES + 4;
  const len = (pf - 1) * HOP + N_FFT, off = N_FFT / 2 + Math.floor(HOP / 2) * 3;
  const ch = (rp: number, ip: number) => {
    const real = new Float32Array(pf * pb), imag = new Float32Array(pf * pb);
    for (let f = 0; f < FRAMES; f++) for (let b = 0; b < BINS; b++) {
      const s = base + b * FRAMES + f, d = (f + 2) * pb + b;
      real[d] = freq[s + rp * plane]; imag[d] = freq[s + ip * plane];
    }
    return istft(real, imag, pf, pb, len).slice(off, off + SEG);
  };
  return [ch(0, 1), ch(2, 3)];
}

/** Separates a stereo song (any sample rate) into the four AI stems at the song's rate. */
export async function separateAi(
  mix: Float32Array[], sampleRate: number, run: ModelRun,
  onProgress: (done: number, total: number) => void = () => {},
  cancelled: () => boolean = () => false,
): Promise<Record<(typeof AI_STEMS)[number], Float32Array[]>> {
  const n0 = mix[0].length;
  const n = Math.round((n0 * SR) / sampleRate);
  const L = sampleRate === SR ? mix[0] : resample(mix[0], n);
  const R = sampleRate === SR ? mix[1] : resample(mix[1], n);
  const stride = Math.floor(SEG * (1 - OVERLAP));
  const total = Math.max(1, Math.ceil(Math.max(0, n - SEG) / stride) + 1);
  const out = AI_STEMS.map(() => [new Float32Array(n), new Float32Array(n)]);
  const weight = new Float32Array(n);
  let seg = 0;
  for (let start = 0; start < n; start += stride) {
    if (cancelled()) throw new Error('cancelled');
    const len = Math.min(SEG, n - start);
    const { waveform, spec } = prepare(L.subarray(start, start + len), R.subarray(start, start + len));
    const { freq, time } = await run(waveform, spec);
    const fade = (i: number) => Math.min(1, (i + 1) / (stride * 0.5), (len - i) / (stride * 0.5));
    for (let t = 0; t < 4; t++) {
      const fx = freq ? inverse(freq, t) : null;
      for (let c = 0; c < 2; c++) {
        const o = out[t][c], tb = (t * 2 + c) * SEG;
        for (let i = 0; i < len; i++) o[start + i] += (time[tb + i] + (fx ? fx[c][i] : 0)) * fade(i);
      }
    }
    for (let i = 0; i < len; i++) weight[start + i] += fade(i);
    onProgress(++seg, total);
    if (start + SEG >= n) break;
  }
  for (const st of out) for (const c of st) for (let i = 0; i < n; i++) if (weight[i] > 0) c[i] /= weight[i];
  const back = (c: Float32Array) => (sampleRate === SR ? c : resample(c, n0));
  return Object.fromEntries(AI_STEMS.map((k, i) => [k, out[i].map(back)])) as Record<(typeof AI_STEMS)[number], Float32Array[]>;
}
