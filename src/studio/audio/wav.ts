/** 16- or 24-bit PCM WAV encoding/decoding (stereo or mono) for stems, remixes and drum kits. */
export function encodeWav(channels: Float32Array[], sampleRate: number, bits: 16 | 24 = 16): Uint8Array {
  const n = channels[0]?.length ?? 0;
  const ch = channels.length;
  const bps = bits / 8;
  const data = n * ch * bps;
  const buf = new ArrayBuffer(44 + data);
  const v = new DataView(buf);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  str(0, 'RIFF'); v.setUint32(4, 36 + data, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, ch, true);
  v.setUint32(24, sampleRate, true); v.setUint32(28, sampleRate * ch * bps, true); v.setUint16(32, ch * bps, true); v.setUint16(34, bits, true);
  str(36, 'data'); v.setUint32(40, data, true);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < ch; c++) {
      const s = Math.max(-1, Math.min(1, channels[c][i]));
      if (bits === 16) { v.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true); o += 2; }
      else {
        const x = Math.round(s < 0 ? s * 0x800000 : s * 0x7fffff);
        v.setUint8(o, x & 0xff); v.setUint8(o + 1, (x >> 8) & 0xff); v.setUint8(o + 2, (x >> 16) & 0xff); o += 3;
      }
    }
  }
  return new Uint8Array(buf);
}

/** Reads PCM WAV (8/16/24/32-bit int or 32-bit float). */
export function decodeWav(bytes: Uint8Array): { sampleRate: number; channels: Float32Array[] } {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (o: number) => String.fromCharCode(v.getUint8(o), v.getUint8(o + 1), v.getUint8(o + 2), v.getUint8(o + 3));
  if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw new Error('not a WAV file');
  let o = 12;
  let fmt = { format: 1, ch: 2, rate: 44100, bits: 16 };
  while (o + 8 <= bytes.length) {
    const id = tag(o);
    const size = v.getUint32(o + 4, true);
    if (id === 'fmt ') fmt = { format: v.getUint16(o + 8, true), ch: v.getUint16(o + 10, true), rate: v.getUint32(o + 12, true), bits: v.getUint16(o + 22, true) };
    if (id === 'data') {
      const bps = fmt.bits / 8;
      const n = Math.floor(Math.min(size, bytes.length - o - 8) / (bps * fmt.ch));
      const out = Array.from({ length: fmt.ch }, () => new Float32Array(n));
      let p = o + 8;
      for (let i = 0; i < n; i++) for (let c = 0; c < fmt.ch; c++) {
        let s: number;
        if (fmt.format === 3) s = v.getFloat32(p, true);
        else if (fmt.bits === 8) s = (v.getUint8(p) - 128) / 128;
        else if (fmt.bits === 16) s = v.getInt16(p, true) / 32768;
        else if (fmt.bits === 24) { const x = v.getUint8(p) | (v.getUint8(p + 1) << 8) | (v.getInt8(p + 2) << 16); s = x / 8388608; }
        else s = v.getInt32(p, true) / 2147483648;
        out[c][i] = s;
        p += bps;
      }
      return { sampleRate: fmt.rate, channels: out };
    }
    o += 8 + size + (size & 1);
  }
  throw new Error('WAV has no audio data');
}

export const mono = (ch: Float32Array[]) => {
  if (ch.length === 1) return ch[0];
  const out = new Float32Array(ch[0].length);
  for (let i = 0; i < out.length; i++) { let s = 0; for (const c of ch) s += c[i]; out[i] = s / ch.length; }
  return out;
};

export const peak = (ch: Float32Array[]) => { let p = 0; for (const c of ch) for (let i = 0; i < c.length; i++) p = Math.max(p, Math.abs(c[i])); return p; };

/** Waveform overview: `bins` peak values from 0 to 1. */
export function overview(ch: Float32Array[], bins = 600) {
  const n = ch[0]?.length ?? 0;
  const out = new Float32Array(bins);
  const step = Math.max(1, Math.floor(n / bins));
  for (let b = 0; b < bins; b++) {
    let p = 0;
    for (let i = b * step; i < Math.min(n, (b + 1) * step); i += 4) for (const c of ch) p = Math.max(p, Math.abs(c[i]));
    out[b] = p;
  }
  const m = Math.max(...out, 1e-9);
  return out.map((x) => x / m);
}
