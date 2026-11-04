import { rng, reverb, type Env } from './synth';

/**
 * 16-pad drum kits made by synthesis (no samples): kick, snare, claps, hats, cymbals, toms and
 * percussion. Each pad has pitch, volume and an envelope you can fine-tune.
 */
export type DrumType = 'kick' | 'snare' | 'clap' | 'closedHat' | 'openHat' | 'crash' | 'ride' | 'tom' | 'rim' | 'shaker' | 'perc' | 'cowbell' | 'fx';
export interface Pad {
  name: string;
  type: DrumType;
  pitch: number; // Hz of the body (kick/tom/perc) or tone colour
  decay: number; // seconds
  tone: number; // 0..1 brightness / snap
  noise: number; // 0..1 noise vs tone
  drive: number; // 0..1
  volume: number; // 0..1.5
  env: Env;
  room: number; // 0..1 reverb send
  key: string; // computer key
  note: number; // MIDI note (36–51, the drum-pad convention)
}
export interface Kit { name: string; prompt: string; seed: number; pads: Pad[] }

export const PAD_LAYOUT: { name: string; type: DrumType; key: string }[] = [
  { name: 'Kick', type: 'kick', key: 'z' }, { name: 'Kick 2', type: 'kick', key: 'x' }, { name: 'Snare', type: 'snare', key: 'c' }, { name: 'Clap', type: 'clap', key: 'v' },
  { name: 'Closed Hat', type: 'closedHat', key: 'a' }, { name: 'Open Hat', type: 'openHat', key: 's' }, { name: 'Rim', type: 'rim', key: 'd' }, { name: 'Shaker', type: 'shaker', key: 'f' },
  { name: 'Tom Low', type: 'tom', key: 'q' }, { name: 'Tom Mid', type: 'tom', key: 'w' }, { name: 'Tom High', type: 'tom', key: 'e' }, { name: 'Perc', type: 'perc', key: 'r' },
  { name: 'Crash', type: 'crash', key: '1' }, { name: 'Ride', type: 'ride', key: '2' }, { name: 'Cowbell', type: 'cowbell', key: '3' }, { name: 'FX', type: 'fx', key: '4' },
];

/** Renders one hit to stereo. */
export function renderPad(p: Pad, sampleRate = 44100, velocity = 1): Float32Array[] {
  const dur = Math.min(4, p.env.a + p.decay * 3 + p.env.r + (p.room > 0 ? 0.8 : 0));
  const n = Math.ceil(dur * sampleRate);
  const x = new Float32Array(n);
  const rand = rng(Math.round(p.pitch * 1000) + p.type.length * 101);
  const noise = () => rand() * 2 - 1;
  let ph = 0, hp = 0, lpN = 0, bp1 = 0, bp2 = 0;
  const metal = [1, 1.342, 1.2312, 1.6532, 1.9523, 2.1523]; // inharmonic partials for cymbals
  const mph = metal.map(() => rand());
  for (let i = 0; i < n; i++) {
    const t = i / sampleRate;
    const amp = (t < p.env.a ? t / Math.max(1e-4, p.env.a) : Math.exp(-(t - p.env.a) / Math.max(0.005, p.decay)));
    let s = 0;
    switch (p.type) {
      case 'kick': {
        const f = p.pitch * (1 + 3 * Math.exp(-t * (30 + p.tone * 40)));
        ph += f / sampleRate;
        s = Math.sin(2 * Math.PI * ph) + (t < 0.004 ? noise() * p.tone * 0.6 : 0);
        break;
      }
      case 'tom': case 'perc': {
        const f = p.pitch * (1 + 0.6 * Math.exp(-t * 25));
        ph += f / sampleRate;
        s = Math.sin(2 * Math.PI * ph) * (1 - p.noise) + noise() * p.noise * Math.exp(-t * 40);
        break;
      }
      case 'snare': case 'rim': {
        ph += (p.pitch * (1 + 0.4 * Math.exp(-t * 60))) / sampleRate;
        const nz = noise(); hp = nz - lpN; lpN += (nz - lpN) * (0.2 + 0.6 * (1 - p.tone));
        s = Math.sin(2 * Math.PI * ph) * (1 - p.noise) + hp * p.noise * (p.type === 'rim' ? 0.4 : 1);
        break;
      }
      case 'clap': {
        const bursts = [0, 0.011, 0.022, 0.034];
        let e = 0; for (const b of bursts) if (t >= b) e = Math.max(e, Math.exp(-(t - b) * 180));
        const nz = noise(); bp1 += (nz - bp1) * 0.35; bp2 += (bp1 - bp2) * 0.35;
        s = (bp1 - bp2) * 3 * Math.max(e, t > 0.034 ? Math.exp(-(t - 0.034) / Math.max(0.01, p.decay)) : 0);
        break;
      }
      case 'closedHat': case 'openHat': case 'shaker': case 'crash': case 'ride': {
        let m = 0;
        for (let k = 0; k < metal.length; k++) { mph[k] += (p.pitch * metal[k]) / sampleRate; m += mph[k] % 1 < 0.5 ? 1 : -1; }
        const nz = noise();
        const raw = m / metal.length * (1 - p.noise) + nz * p.noise;
        hp = raw - lpN; lpN += (raw - lpN) * (0.05 + 0.4 * (1 - p.tone)); // high-pass
        s = hp * (p.type === 'shaker' ? Math.min(1, t / 0.01) : 1);
        break;
      }
      case 'cowbell': {
        ph += p.pitch / sampleRate;
        s = ((ph % 1 < 0.5 ? 1 : -1) + ((ph * 1.48) % 1 < 0.5 ? 1 : -1)) * 0.35;
        break;
      }
      default: { // fx: falling noise sweep
        ph += (p.pitch * (1 + 4 * (1 - t / dur))) / sampleRate;
        s = Math.sin(2 * Math.PI * ph) * 0.4 + noise() * 0.3 * p.noise;
      }
    }
    if (p.drive > 0) s = Math.tanh(s * (1 + p.drive * 6)) / Math.tanh(1 + p.drive * 6);
    const rel = t > dur - p.env.r ? Math.max(0, (dur - t) / Math.max(1e-3, p.env.r)) : 1;
    x[i] = s * amp * rel * p.volume * velocity * 0.9;
  }
  const L = x, R = x.slice();
  if (p.room > 0) reverb(L, R, sampleRate, p.room, 0.3);
  return [L, R];
}
