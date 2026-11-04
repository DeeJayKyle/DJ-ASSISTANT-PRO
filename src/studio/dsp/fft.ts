/** Cached bit-reversal and twiddle tables per size. */
const tables = new Map<number, { rev: Uint32Array; cos: Float64Array; sin: Float64Array }>();
function table(n: number) {
  let t = tables.get(n);
  if (!t) {
    const rev = new Uint32Array(n);
    const bits = Math.log2(n);
    for (let i = 0; i < n; i++) { let r = 0; for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b); rev[i] = r; }
    const cos = new Float64Array(n / 2), sin = new Float64Array(n / 2);
    for (let k = 0; k < n / 2; k++) { cos[k] = Math.cos((-2 * Math.PI * k) / n); sin[k] = Math.sin((-2 * Math.PI * k) / n); }
    t = { rev, cos, sin };
    tables.set(n, t);
  }
  return t;
}

/** In-place radix-2 FFT on separate real/imaginary arrays (length must be a power of two). */
export function fft(re: Float64Array, im: Float64Array) {
  const n = re.length;
  const { rev, cos, sin } = table(n);
  for (let i = 0; i < n; i++) {
    const j = rev[i];
    if (i < j) { const tr = re[i]; re[i] = re[j]; re[j] = tr; const ti = im[i]; im[i] = im[j]; im[j] = ti; }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const half = len >> 1, step = n / len;
    for (let i = 0; i < n; i += len) {
      for (let k = 0, w = 0; k < half; k++, w += step) {
        const a = i + k, b = a + half;
        const wr = cos[w], wi = sin[w];
        const tr = re[b] * wr - im[b] * wi;
        const ti = re[b] * wi + im[b] * wr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr; im[a] += ti;
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
  for (let k = 0; k < size / 2; k++) out[k] = Math.sqrt(re[k] * re[k] + im[k] * im[k]);
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
