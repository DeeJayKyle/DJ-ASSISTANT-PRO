/** In-place radix-2 FFT on separate real/imaginary arrays (length must be a power of two). */
export function fft(re: Float64Array, im: Float64Array) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k;
        const b = a + len / 2;
        const tr = re[b] * cr - im[b] * ci;
        const ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr;
        im[b] = im[a] - ti;
        re[a] += tr;
        im[a] += ti;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}

/** Hann window of the given size, cached. */
const windows = new Map<number, Float64Array>();
export function hann(size: number) {
  let w = windows.get(size);
  if (!w) {
    w = new Float64Array(size);
    for (let i = 0; i < size; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (size - 1));
    windows.set(size, w);
  }
  return w;
}

/** Magnitude spectrum (first size/2 bins) of one windowed frame starting at `start`. */
export function magnitudes(signal: Float32Array, start: number, size: number, out = new Float64Array(size / 2)) {
  const re = new Float64Array(size);
  const im = new Float64Array(size);
  const w = hann(size);
  for (let i = 0; i < size; i++) re[i] = (signal[start + i] ?? 0) * w[i];
  fft(re, im);
  for (let k = 0; k < size / 2; k++) out[k] = Math.hypot(re[k], im[k]);
  return out;
}

/** Averaging downsample by an integer factor (a cheap low-pass, good enough for rhythm and pitch). */
export function downsample(signal: Float32Array, factor: number) {
  if (factor <= 1) return signal;
  const out = new Float32Array(Math.floor(signal.length / factor));
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    for (let j = 0; j < factor; j++) s += signal[i * factor + j];
    out[i] = s / factor;
  }
  return out;
}
