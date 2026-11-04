/**
 * Tempo and key changes without the chipmunk effect.
 *
 * - `timeStretch`: WSOLA (overlap-add with a small search for the best-matching splice point),
 *   which keeps drums tight. The search runs on a 4× downsampled guide for speed.
 * - `pitchShift`: stretch by the pitch ratio, then resample back to the original length.
 * - `Deck` (realtime): the same idea per 512-sample hop, so tempo and key can change while playing.
 */
const FRAME = 2048;
const HOP = 512;
const SEEK = 384;

const hann = (() => { const w = new Float32Array(FRAME); for (let i = 0; i < FRAME; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / FRAME); return w; })();

function guide(ch: Float32Array[]) {
  const n = Math.floor(ch[0].length / 4);
  const g = new Float32Array(n);
  for (let i = 0; i < n; i++) { let s = 0; for (const c of ch) s += c[i * 4] + c[i * 4 + 1] + c[i * 4 + 2] + c[i * 4 + 3]; g[i] = s; }
  return g;
}

/** Best splice offset within ±SEEK of `want` so the new frame lines up with the natural continuation. */
function bestOffset(g: Float32Array, want: number, natural: number) {
  const w = want >> 2, nat = natural >> 2, seek = SEEK >> 2, len = (FRAME / 2) >> 2;
  if (nat < 0 || nat + len >= g.length) return want;
  let best = 0, bestScore = -Infinity;
  for (let d = -seek; d <= seek; d++) {
    const p = w + d;
    if (p < 0 || p + len >= g.length) continue;
    let s = 0;
    for (let i = 0; i < len; i += 2) s += g[p + i] * g[nat + i];
    if (s > bestScore) { bestScore = s; best = d; }
  }
  return want + best * 4;
}

/** Changes the length by `ratio` (2 = twice as long, i.e. half speed) keeping the pitch. */
export function timeStretch(ch: Float32Array[], ratio: number): Float32Array[] {
  const n = ch[0].length;
  if (Math.abs(ratio - 1) < 1e-4) return ch.map((c) => c.slice());
  const outLen = Math.max(1, Math.round(n * ratio));
  const out = ch.map(() => new Float32Array(outLen + FRAME));
  const norm = new Float32Array(outLen + FRAME);
  const g = guide(ch);
  let prevIn = 0;
  for (let o = 0; o < outLen; o += HOP) {
    const want = Math.round(o / ratio);
    const src = o === 0 ? 0 : bestOffset(g, want, prevIn + HOP);
    for (let c = 0; c < ch.length; c++) {
      const x = ch[c], y = out[c];
      for (let i = 0; i < FRAME; i++) { const j = src + i; if (j >= 0 && j < n) y[o + i] += x[j] * hann[i]; }
    }
    for (let i = 0; i < FRAME; i++) norm[o + i] += hann[i];
    prevIn = src;
  }
  return out.map((y) => { const r = new Float32Array(outLen); for (let i = 0; i < outLen; i++) r[i] = norm[i] > 1e-3 ? y[i] / norm[i] : 0; return r; });
}

/** Linear-interpolation resampling to `outLen` samples. */
export function resample(x: Float32Array, outLen: number) {
  const r = new Float32Array(outLen);
  const step = (x.length - 1) / Math.max(1, outLen - 1);
  for (let i = 0; i < outLen; i++) { const p = i * step, j = Math.floor(p), f = p - j; r[i] = x[j] * (1 - f) + (x[j + 1] ?? x[j]) * f; }
  return r;
}

/** Shifts the key by `semitones`, keeping the length. */
export function pitchShift(ch: Float32Array[], semitones: number): Float32Array[] {
  if (!semitones) return ch.map((c) => c.slice());
  const ratio = 2 ** (semitones / 12);
  return timeStretch(ch, ratio).map((c) => resample(c, ch[0].length));
}

/** Tempo (playback speed, pitch kept) and key together, for one clip in a remix. */
export function retune(ch: Float32Array[], speed: number, semitones: number): Float32Array[] {
  const pitch = 2 ** (semitones / 12);
  const outLen = Math.max(1, Math.round(ch[0].length / speed));
  const stretched = timeStretch(ch, pitch / speed);
  return stretched.map((c) => resample(c, outLen));
}

/** Semitones to move `from` to `to` (either way round the octave, at most a tritone). */
export function semitoneShift(fromRoot: number, toRoot: number) {
  let d = (((toRoot - fromRoot) % 12) + 12) % 12;
  if (d > 6) d -= 12;
  return d;
}

/**
 * Realtime deck: reads one or more stereo layers (whole song or stems) with independent gains,
 * at a tempo `rate` (1 = original) and `pitch` ratio. Call `render` for each block.
 */
export class Deck {
  layers: Float32Array[][];
  gains: number[];
  rate = 1;
  pitch = 1;
  pos = 0; // source position in samples
  playing = false;
  /** Active loop in source samples (end > start), or null. */
  loop: { start: number; end: number } | null = null;
  private ring: Float32Array[] = [new Float32Array(FRAME * 2), new Float32Array(FRAME * 2)];
  private ringNorm = new Float32Array(FRAME * 2);
  private outPos = 0; // samples emitted since the last grain
  private readPos = 0; // read index in the ring
  private lastSrc = 0;

  constructor(layers: Float32Array[][]) {
    this.layers = layers;
    this.gains = layers.map(() => 1);
  }

  get length() { return this.layers[0]?.[0].length ?? 0; }

  seek(pos: number) {
    this.pos = Math.max(0, Math.min(this.length, pos));
    this.ring.forEach((r) => r.fill(0)); this.ringNorm.fill(0);
    this.outPos = 0; this.readPos = 0; this.lastSrc = this.pos;
    this.grain(true);
  }

  private sample(c: number, p: number) {
    const j = Math.floor(p), f = p - j;
    let s = 0;
    for (let l = 0; l < this.layers.length; l++) {
      const g = this.gains[l];
      if (!g) continue;
      const x = this.layers[l][c] ?? this.layers[l][0];
      if (j < 0 || j + 1 >= x.length) continue;
      s += (x[j] * (1 - f) + x[j + 1] * f) * g;
    }
    return s;
  }

  private match(want: number) {
    // small WSOLA search against the natural continuation of the last grain
    const nat = this.lastSrc + HOP * this.pitch;
    let best = 0, bestScore = -Infinity;
    for (let d = -128; d <= 128; d += 8) {
      let s = 0;
      for (let i = 0; i < 256; i += 4) s += this.sample(0, want + d + i * this.pitch) * this.sample(0, nat + i * this.pitch);
      if (s > bestScore) { bestScore = s; best = d; }
    }
    return want + best;
  }

  private grain(first = false) {
    const src = first ? this.pos : this.match(this.pos);
    const base = this.readPos;
    for (let i = 0; i < FRAME; i++) {
      const k = (base + i) % this.ringNorm.length;
      const w = hann[i];
      for (let c = 0; c < 2; c++) this.ring[c][k] += this.sample(c, src + i * this.pitch) * w;
      this.ringNorm[k] += w;
    }
    this.lastSrc = src;
    this.pos += HOP * this.rate;
    // Beat loops: jump back by the loop length, keeping the phase so the loop stays on the beat.
    if (this.loop && this.loop.end > this.loop.start && this.pos >= this.loop.end) {
      const len = this.loop.end - this.loop.start;
      this.pos = this.loop.start + ((this.pos - this.loop.start) % len);
      this.lastSrc = this.pos - HOP * this.pitch;
    }
  }

  /** Fills `out` (two channels) with the next block. */
  render(out: Float32Array[], frames: number) {
    for (let i = 0; i < frames; i++) {
      if (!this.playing || this.pos >= this.length) { out[0][i] = 0; out[1][i] = 0; continue; }
      const k = this.readPos % this.ringNorm.length;
      const nrm = this.ringNorm[k] > 1e-3 ? this.ringNorm[k] : 1;
      out[0][i] = this.ring[0][k] / nrm;
      out[1][i] = this.ring[1][k] / nrm;
      this.ring[0][k] = 0; this.ring[1][k] = 0; this.ringNorm[k] = 0;
      this.readPos++;
      if (++this.outPos >= HOP) { this.outPos = 0; this.grain(); }
    }
  }

  /** Where the listener is now, in source seconds (the grain buffer adds a little latency). */
  time(sampleRate: number) { return Math.max(0, this.pos - (FRAME - HOP) * this.rate) / sampleRate; }
}
