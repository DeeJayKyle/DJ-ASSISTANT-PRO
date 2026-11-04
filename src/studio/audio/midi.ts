import { downsample } from '../dsp/fft';
import { fft } from '../dsp/fft';

/** Audio → MIDI: YIN pitch tracking for bass and melodies, onset detection for drums, and a Standard MIDI File writer. */
export interface Note { pitch: number; start: number; end: number; velocity: number }
export interface MidiTrack { name: string; channel: number; notes: Note[]; program?: number }

/** YIN fundamental frequency per frame. Returns f0 (0 = unvoiced) and confidence. */
export function yin(mono: Float32Array, sampleRate: number, opts: { minHz?: number; maxHz?: number; hop?: number } = {}) {
  const minHz = opts.minHz ?? 40, maxHz = opts.maxHz ?? 1500;
  const factor = Math.max(1, Math.floor(sampleRate / Math.max(8000, maxHz * 4)));
  const x = downsample(mono, factor);
  const sr = sampleRate / factor;
  const hop = Math.max(64, Math.round((opts.hop ?? 0.01) * sr));
  const maxLag = Math.ceil(sr / minHz), minLag = Math.floor(sr / maxHz);
  const W = maxLag + 1;
  const f0: number[] = [], conf: number[] = [], rms: number[] = [];
  const d = new Float64Array(maxLag + 1);
  for (let s = 0; s + W + maxLag < x.length; s += hop) {
    let e = 0;
    for (let i = 0; i < W; i++) e += x[s + i] * x[s + i];
    rms.push(Math.sqrt(e / W));
    for (let tau = 1; tau <= maxLag; tau++) {
      let sum = 0;
      for (let i = 0; i < W; i++) { const df = x[s + i] - x[s + i + tau]; sum += df * df; }
      d[tau] = sum;
    }
    // cumulative mean normalised difference
    let run = 0;
    let best = -1;
    for (let tau = 1; tau <= maxLag; tau++) {
      run += d[tau];
      d[tau] = run > 0 ? (d[tau] * tau) / run : 1;
    }
    for (let tau = minLag; tau <= maxLag; tau++) {
      if (d[tau] < 0.15) { while (tau + 1 <= maxLag && d[tau + 1] < d[tau]) tau++; best = tau; break; }
    }
    if (best < 0) { f0.push(0); conf.push(0); continue; }
    // parabolic interpolation
    const a = d[best - 1] ?? d[best], b = d[best], c = d[best + 1] ?? d[best];
    const shift = (a - c) / (2 * (a - 2 * b + c) || 1);
    f0.push(sr / (best + (Math.abs(shift) < 1 ? shift : 0)));
    conf.push(1 - b);
  }
  return { f0, conf, rms, hopSec: hop / sr };
}

/** Monophonic notes from a stem (bass or lead melody). */
export function transcribePitched(mono: Float32Array, sampleRate: number, range: { minHz: number; maxHz: number }): Note[] {
  const { f0, rms, hopSec } = yin(mono, sampleRate, { ...range, hop: 0.01 });
  const maxR = Math.max(...rms, 1e-9);
  const notes: Note[] = [];
  let cur: { pitch: number; start: number; frames: number; peak: number } | null = null;
  let gap = 0;
  const close = (t: number) => {
    if (cur && cur.frames >= 6) notes.push({ pitch: cur.pitch, start: cur.start, end: t, velocity: Math.round(40 + 80 * Math.min(1, cur.peak / maxR)) });
    cur = null;
  };
  for (let i = 0; i < f0.length; i++) {
    const t = i * hopSec;
    const voiced = f0[i] > 0 && rms[i] > maxR * 0.05;
    const p = voiced ? Math.round(69 + 12 * Math.log2(f0[i] / 440)) : -1;
    if (cur && p === cur.pitch) { cur.frames++; cur.peak = Math.max(cur.peak, rms[i]); gap = 0; continue; }
    if (cur && p < 0 && gap < 3) { gap++; continue; }
    close(t - gap * hopSec);
    gap = 0;
    if (p >= 0) cur = { pitch: p, start: t, frames: 1, peak: rms[i] };
  }
  close(f0.length * hopSec);
  return notes;
}

/** Drum hits from the drums stem: kick (36), snare (38) or hi-hat (42), by where the energy is. */
export function transcribeDrums(mono: Float32Array, sampleRate: number): Note[] {
  const size = 1024, hop = 256;
  const re = new Float64Array(size), im = new Float64Array(size);
  const bands = [[30, 150], [150, 2500], [5000, 15000]];
  const env: number[][] = [[], [], []];
  const prev = [0, 0, 0];
  for (let s = 0; s + size <= mono.length; s += hop) {
    for (let i = 0; i < size; i++) { re[i] = mono[s + i] * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / size)); im[i] = 0; }
    fft(re, im);
    bands.forEach(([a, b], j) => {
      let e = 0;
      for (let k = Math.floor((a * size) / sampleRate); k <= Math.min(size / 2, Math.ceil((b * size) / sampleRate)); k++) e += re[k] * re[k] + im[k] * im[k];
      const v = Math.log1p(e * 50);
      env[j].push(Math.max(0, v - prev[j]));
      prev[j] = v;
    });
  }
  const hopSec = hop / sampleRate;
  const notes: Note[] = [];
  const pitch = [36, 38, 42];
  env.forEach((e, j) => {
    const sorted = [...e].sort((a, b) => a - b);
    const thr = Math.max(sorted[Math.floor(sorted.length * 0.95)] ?? 0, (sorted[sorted.length - 1] ?? 0) * 0.25);
    let last = -1e9;
    const maxE = sorted[sorted.length - 1] || 1;
    for (let i = 1; i < e.length - 1; i++) {
      if (e[i] > thr && e[i] >= e[i - 1] && e[i] >= e[i + 1] && i - last > 0.06 / hopSec) {
        last = i;
        notes.push({ pitch: pitch[j], start: i * hopSec, end: i * hopSec + 0.1, velocity: Math.round(50 + 77 * Math.min(1, e[i] / maxE)) });
      }
    }
  });
  return notes.sort((a, b) => a.start - b.start);
}

/** Chords as MIDI (root-position triads around middle C), from detected chord segments. */
export function chordNotes(segs: { start: number; end: number; root: number; quality: string }[]): Note[] {
  const out: Note[] = [];
  for (const s of segs) {
    if (s.quality === 'none') continue;
    const base = 48 + s.root;
    for (const iv of [0, s.quality === 'min' ? 3 : 4, 7]) out.push({ pitch: base + iv, start: s.start, end: s.end, velocity: 80 });
  }
  return out;
}

const vlq = (n: number) => {
  const bytes = [n & 0x7f];
  while ((n >>= 7)) bytes.unshift((n & 0x7f) | 0x80);
  return bytes;
};

/** A Standard MIDI File (type 1, 480 ticks per beat). */
export function writeMidi(tracks: MidiTrack[], bpm: number): Uint8Array {
  const ppq = 480;
  const tick = (sec: number) => Math.max(0, Math.round((sec * bpm * ppq) / 60));
  const chunk = (id: string, data: number[]) => [...[...id].map((c) => c.charCodeAt(0)), (data.length >>> 24) & 255, (data.length >>> 16) & 255, (data.length >>> 8) & 255, data.length & 255, ...data];
  const tempo = Math.round(60_000_000 / (bpm || 120));
  const meta = [0, 0xff, 0x51, 3, (tempo >> 16) & 255, (tempo >> 8) & 255, tempo & 255, 0, 0xff, 0x58, 4, 4, 2, 24, 8, 0, 0xff, 0x2f, 0];
  const out = [...chunk('MThd', [0, 1, 0, tracks.length + 1, ppq >> 8, ppq & 255]), ...chunk('MTrk', meta)];
  for (const t of tracks) {
    const ev: { at: number; bytes: number[] }[] = [];
    const name = [...new TextEncoder().encode(t.name)];
    ev.push({ at: 0, bytes: [0xff, 0x03, ...vlq(name.length), ...name] });
    if (t.program != null) ev.push({ at: 0, bytes: [0xc0 | t.channel, t.program] });
    for (const n of t.notes) {
      const p = Math.max(0, Math.min(127, n.pitch)), v = Math.max(1, Math.min(127, n.velocity));
      ev.push({ at: tick(n.start), bytes: [0x90 | t.channel, p, v] });
      ev.push({ at: Math.max(tick(n.start) + 1, tick(n.end)), bytes: [0x80 | t.channel, p, 0] });
    }
    ev.sort((a, b) => a.at - b.at || (a.bytes[0] & 0xf0) - (b.bytes[0] & 0xf0));
    const data: number[] = [];
    let now = 0;
    for (const e of ev) { data.push(...vlq(e.at - now), ...e.bytes); now = e.at; }
    data.push(0, 0xff, 0x2f, 0);
    out.push(...chunk('MTrk', data));
  }
  return new Uint8Array(out);
}

/** Reads note events back from a MIDI file (for checks and the piano-roll preview). */
export function readMidi(bytes: Uint8Array): { ppq: number; tracks: { name: string; notes: { pitch: number; tick: number; len: number }[] }[] } {
  let o = 0;
  const u32 = () => ((bytes[o++] << 24) | (bytes[o++] << 16) | (bytes[o++] << 8) | bytes[o++]) >>> 0;
  const u16 = () => (bytes[o++] << 8) | bytes[o++];
  const vl = () => { let n = 0, b; do { b = bytes[o++]; n = (n << 7) | (b & 0x7f); } while (b & 0x80); return n; };
  o = 4; u32(); u16(); const ntr = u16(); const ppq = u16();
  const tracks = [];
  for (let t = 0; t < ntr; t++) {
    o += 4; const end = u32() + o;
    let now = 0, status = 0, name = '';
    const open = new Map<number, number>();
    const notes: { pitch: number; tick: number; len: number }[] = [];
    while (o < end) {
      now += vl();
      let st = bytes[o];
      if (st & 0x80) o++; else st = status;
      status = st;
      if (st === 0xff) { const type = bytes[o++]; const len = vl(); if (type === 3) name = new TextDecoder().decode(bytes.slice(o, o + len)); o += len; }
      else if ((st & 0xf0) === 0x90 || (st & 0xf0) === 0x80) {
        const p = bytes[o++], v = bytes[o++];
        if ((st & 0xf0) === 0x90 && v > 0) open.set(p, now);
        else if (open.has(p)) { notes.push({ pitch: p, tick: open.get(p)!, len: now - open.get(p)! }); open.delete(p); }
      } else if ((st & 0xf0) === 0xc0 || (st & 0xf0) === 0xd0) o += 1;
      else o += 2;
    }
    tracks.push({ name, notes });
  }
  return { ppq, tracks };
}
