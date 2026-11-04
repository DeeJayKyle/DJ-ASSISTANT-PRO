import { DEFAULT_PATCH, rng, type Patch } from './synth';
import { PAD_LAYOUT, type Kit, type Pad } from './drums';

/**
 * Turns a description in plain words ("dark thick sub bass", "crisp trap kit") into a synth
 * patch or a drum kit. Built-in rules understand common sound-design words; with AI help turned
 * on, a model can return the same JSON for richer prompts. A seed gives endless variations.
 */
const has = (text: string, ...words: string[]) => words.some((w) => new RegExp(`\\b${w}`, 'i').test(text));
const titleCase = (s: string) => s.replace(/\b\w/g, (c) => c.toUpperCase());

export const SYNTH_IDEAS = [
  'bright cinematic synth organ', 'warm analog pad with slow attack', 'dark thick sub bass', 'punchy filtered ambient keys', 'glassy bell pluck',
  'gritty distorted reese bass', 'airy shimmering choir pad', 'retro 80s detuned lead', 'soft lofi electric piano', 'sharp dry stab chords',
];
export const DRUM_IDEAS = [
  'deep punchy techno kick-driven groove', 'crisp trap kit with booming 808', 'gritty saturated synthwave drums', 'dusty lofi hip hop kit', 'glitchy metallic IDM percussion',
  'tight drum and bass breaks', 'warm disco house kit', 'roomy live rock kit', 'minimal clicky tech house', 'afro house percussion with shakers',
];

export function patchFromPrompt(prompt: string, seed = 1): Patch {
  const r = rng(seed * 2654435761);
  const j = (x: number, amt = 0.15) => x * (1 + (r() - 0.5) * 2 * amt);
  const p: Patch = structuredClone(DEFAULT_PATCH);
  const t = prompt.toLowerCase();
  p.name = titleCase(prompt.trim().split(/\s+/).slice(0, 5).join(' ')) || 'New Sound';

  // instrument families
  if (has(t, 'sub', '808', 'bass', 'reese')) {
    p.oscs = has(t, 'reese', 'gritt', 'distort') ? [{ wave: 'saw', level: 0.5, octave: -1, detune: -12 }, { wave: 'saw', level: 0.5, octave: -1, detune: 12 }] : [{ wave: 'sine', level: 0.8, octave: -1, detune: 0 }, { wave: 'triangle', level: 0.25, octave: -1, detune: 0 }];
    p.filter.cutoff = 600; p.amp = { a: 0.004, d: 0.4, s: 0.85, r: 0.15 }; p.reverb.mix = 0;
    if (has(t, '808')) { p.glideBend = 5; p.amp = { a: 0.002, d: 1.2, s: 0.2, r: 0.4 }; p.drive = 0.25; }
  }
  if (has(t, 'pad', 'choir', 'string', 'atmos', 'ambient')) {
    p.oscs = [{ wave: 'saw', level: 0.4, octave: 0, detune: 0 }, { wave: 'triangle', level: 0.4, octave: 1, detune: 5 }];
    p.unison = 4; p.spread = 22; p.amp = { a: 0.6, d: 1, s: 0.8, r: 1.4 }; p.filter.cutoff = 1800; p.filter.envAmount = 0.4; p.reverb = { mix: 0.45, size: 0.8 }; p.chorus = 0.4;
  }
  if (has(t, 'organ')) { p.oscs = [{ wave: 'sine', level: 0.5, octave: 0, detune: 0 }, { wave: 'sine', level: 0.35, octave: 1, detune: 0 }, { wave: 'square', level: 0.15, octave: -1, detune: 0 }]; p.amp = { a: 0.01, d: 0.1, s: 0.95, r: 0.12 }; p.filter.cutoff = 5000; p.filter.envAmount = 0; }
  if (has(t, 'pluck', 'bell', 'glass', 'mallet', 'marimba')) { p.oscs = has(t, 'bell', 'glass') ? [{ wave: 'sine', level: 0.6, octave: 0, detune: 0 }, { wave: 'sine', level: 0.3, octave: 2, detune: 8 }] : [{ wave: 'saw', level: 0.5, octave: 0, detune: 0 }, { wave: 'square', level: 0.25, octave: 1, detune: 0 }]; p.amp = { a: 0.002, d: 0.5, s: 0, r: 0.4 }; p.filter.envAmount = 2.5; p.filter.env = { a: 0.001, d: 0.25, s: 0, r: 0.2 }; p.filter.cutoff = 900; }
  if (has(t, 'key', 'piano', 'rhodes', 'electric piano', 'ep\\b')) { p.oscs = [{ wave: 'triangle', level: 0.6, octave: 0, detune: 0 }, { wave: 'sine', level: 0.35, octave: 1, detune: 3 }]; p.amp = { a: 0.003, d: 1.2, s: 0.25, r: 0.5 }; p.filter.cutoff = 2600; p.chorus = Math.max(p.chorus, 0.25); }
  if (has(t, 'lead', 'synth lead')) { p.oscs = [{ wave: 'saw', level: 0.5, octave: 0, detune: -7 }, { wave: 'square', level: 0.35, octave: 0, detune: 7 }]; p.amp = { a: 0.005, d: 0.2, s: 0.8, r: 0.2 }; p.filter.cutoff = 3200; }
  if (has(t, 'stab', 'chord')) { p.amp = { a: 0.002, d: 0.25, s: 0.1, r: 0.2 }; p.unison = Math.max(p.unison, 3); p.spread = Math.max(p.spread, 15); }

  // colour words
  if (has(t, 'bright', 'sharp', 'crisp', 'shimmer')) { p.filter.cutoff *= 2.4; p.filter.resonance = Math.max(p.filter.resonance, 0.25); }
  if (has(t, 'dark', 'deep', 'muffled', 'lofi', 'lo-fi', 'dusty')) p.filter.cutoff *= 0.45;
  if (has(t, 'warm', 'analog', 'vintage')) { p.drive = Math.max(p.drive, 0.15); p.oscs.forEach((o, i) => (o.detune += i % 2 ? 6 : -6)); }
  if (has(t, 'thick', 'fat', 'wide', 'huge', 'super')) { p.unison = Math.max(p.unison, 5); p.spread = Math.max(p.spread, 25); }
  if (has(t, 'gritt', 'distort', 'dirty', 'saturat', 'crunch')) p.drive = Math.max(p.drive, 0.55);
  if (has(t, 'filter', 'resonan', 'acid')) { p.filter.resonance = 0.6; p.filter.envAmount = Math.max(p.filter.envAmount, 2); }
  if (has(t, 'punch', 'snappy', 'tight')) { p.amp.a = 0.001; p.filter.env.d = 0.12; }
  if (has(t, 'soft', 'gentle', 'mellow')) { p.amp.a = Math.max(p.amp.a, 0.03); p.filter.cutoff *= 0.7; p.drive = 0; }
  if (has(t, 'slow attack', 'swell')) p.amp.a = Math.max(p.amp.a, 0.9);
  if (has(t, 'cinematic', 'epic', 'huge', 'hall')) p.reverb = { mix: Math.max(p.reverb.mix, 0.5), size: 0.95 };
  if (has(t, 'dry')) p.reverb.mix = 0;
  if (has(t, 'airy', 'breath')) p.oscs.push({ wave: 'noise', level: 0.08, octave: 0, detune: 0 });
  if (has(t, 'retro', '80s', 'synthwave')) { p.chorus = Math.max(p.chorus, 0.5); p.oscs.forEach((o) => { if (o.wave === 'sine') o.wave = 'square'; }); }

  // variation
  p.filter.cutoff = Math.min(16000, j(p.filter.cutoff, 0.25));
  p.filter.resonance = Math.min(0.9, j(p.filter.resonance + 0.001, 0.3));
  p.amp.d = j(p.amp.d); p.amp.r = j(p.amp.r);
  p.spread = j(p.spread, 0.3);
  p.oscs.forEach((o) => (o.detune += (r() - 0.5) * 6));
  return p;
}

export function kitFromPrompt(prompt: string, seed = 1): Kit {
  const r = rng(seed * 40503 + 7);
  const j = (x: number, amt = 0.12) => x * (1 + (r() - 0.5) * 2 * amt);
  const t = prompt.toLowerCase();
  const style = {
    kickPitch: 52, kickDecay: 0.28, kickTone: 0.5, snarePitch: 190, snareNoise: 0.65, snareDecay: 0.16, hatPitch: 420, hatTone: 0.7, hatDecay: 0.05,
    drive: 0.1, room: 0.08, tomBase: 90, decayScale: 1,
  };
  if (has(t, 'techno', 'industrial', 'warehouse')) Object.assign(style, { kickPitch: 48, kickDecay: 0.42, kickTone: 0.7, drive: 0.35, hatTone: 0.85, room: 0.12 });
  if (has(t, 'trap', '808', 'drill')) Object.assign(style, { kickPitch: 42, kickDecay: 1.1, kickTone: 0.35, snarePitch: 220, snareNoise: 0.8, snareDecay: 0.12, hatTone: 0.95, hatDecay: 0.035, drive: 0.2, room: 0.05 });
  if (has(t, 'lofi', 'lo-fi', 'dusty', 'boom bap', 'hip hop')) Object.assign(style, { kickPitch: 55, kickDecay: 0.22, kickTone: 0.25, hatTone: 0.4, snareNoise: 0.55, drive: 0.4, room: 0.18 });
  if (has(t, 'synthwave', '80s', 'retro')) Object.assign(style, { snareDecay: 0.32, room: 0.45, drive: 0.25 });
  if (has(t, 'house', 'disco')) Object.assign(style, { kickPitch: 54, kickDecay: 0.3, hatTone: 0.75, room: 0.1 });
  if (has(t, 'drum and bass', 'dnb', 'jungle', 'break')) Object.assign(style, { kickPitch: 58, kickDecay: 0.18, snarePitch: 240, snareDecay: 0.14, hatDecay: 0.04 });
  if (has(t, 'rock', 'live', 'acoustic', 'roomy')) Object.assign(style, { kickPitch: 60, kickDecay: 0.25, snarePitch: 180, snareNoise: 0.55, room: 0.4, tomBase: 80 });
  if (has(t, 'minimal', 'click', 'tech house')) Object.assign(style, { kickDecay: 0.22, hatDecay: 0.03, snareNoise: 0.5, room: 0.06 });
  if (has(t, 'glitch', 'idm', 'metallic')) Object.assign(style, { hatPitch: 780, hatTone: 1, decayScale: 0.6, drive: 0.3 });
  if (has(t, 'afro', 'latin', 'percussion', 'shaker')) Object.assign(style, { tomBase: 140, room: 0.15 });
  if (has(t, 'deep', 'boom')) style.kickPitch *= 0.88;
  if (has(t, 'punch', 'tight')) style.kickDecay *= 0.75;
  if (has(t, 'crisp', 'sharp', 'razor')) { style.hatTone = 1; style.snareNoise = Math.min(1, style.snareNoise + 0.15); }
  if (has(t, 'gritt', 'saturat', 'crunch', 'distort')) style.drive = Math.max(style.drive, 0.5);
  if (has(t, 'soft', 'warm')) style.drive *= 0.5;

  const env = (decay: number) => ({ a: 0.0008, d: decay, s: 0, r: 0.02 });
  const pads: Pad[] = PAD_LAYOUT.map((l, i) => {
    const base: Pad = { name: l.name, type: l.type, pitch: 200, decay: 0.2, tone: 0.5, noise: 0.5, drive: style.drive, volume: 0.9, env: env(0.2), room: style.room, key: l.key, note: 36 + i };
    switch (l.type) {
      case 'kick': Object.assign(base, { pitch: j(style.kickPitch * (l.name.endsWith('2') ? 1.2 : 1)), decay: j(style.kickDecay * (l.name.endsWith('2') ? 0.6 : 1)), tone: style.kickTone, noise: 0, volume: 1, room: style.room * 0.3 }); break;
      case 'snare': Object.assign(base, { pitch: j(style.snarePitch), decay: j(style.snareDecay), noise: style.snareNoise, tone: 0.6 }); break;
      case 'clap': Object.assign(base, { decay: j(0.14), noise: 1, tone: 0.6 }); break;
      case 'rim': Object.assign(base, { pitch: j(420), decay: 0.04, noise: 0.3, tone: 0.8, volume: 0.7 }); break;
      case 'closedHat': Object.assign(base, { pitch: j(style.hatPitch), decay: j(style.hatDecay * style.decayScale), tone: style.hatTone, noise: 0.45, volume: 0.6 }); break;
      case 'openHat': Object.assign(base, { pitch: j(style.hatPitch), decay: j(0.32 * style.decayScale), tone: style.hatTone, noise: 0.45, volume: 0.55 }); break;
      case 'shaker': Object.assign(base, { pitch: 900, decay: j(0.07), tone: 0.9, noise: 0.95, volume: 0.45 }); break;
      case 'crash': Object.assign(base, { pitch: j(330), decay: j(1.2), tone: 0.8, noise: 0.6, volume: 0.5 }); break;
      case 'ride': Object.assign(base, { pitch: j(520), decay: j(0.9), tone: 0.65, noise: 0.25, volume: 0.45 }); break;
      case 'tom': { const k = l.name.includes('Low') ? 1 : l.name.includes('Mid') ? 1.33 : 1.75; Object.assign(base, { pitch: j(style.tomBase * k), decay: j(0.35), noise: 0.15 }); break; }
      case 'perc': Object.assign(base, { pitch: j(style.tomBase * 3.2), decay: j(0.09), noise: 0.1, volume: 0.7 }); break;
      case 'cowbell': Object.assign(base, { pitch: j(560), decay: j(0.18), volume: 0.5 }); break;
      default: Object.assign(base, { pitch: j(300), decay: j(0.6), noise: 0.6, volume: 0.5, room: Math.max(0.3, style.room) });
    }
    base.env = env(base.decay);
    return base;
  });
  return { name: titleCase(prompt.trim().split(/\s+/).slice(0, 5).join(' ')) || 'New Kit', prompt, seed, pads };
}

/** Builds a prompt for an AI model to return a patch as JSON (optional AI help). */
export const AI_SYNTH_SYSTEM = 'You design synthesiser patches. Reply only with JSON matching this TypeScript type: {name:string; oscs:{wave:"sine"|"triangle"|"saw"|"square"|"noise"; level:number; octave:number; detune:number}[]; unison:number; spread:number; filter:{type:"lp"|"bp"|"hp"; cutoff:number; resonance:number; envAmount:number; env:{a:number;d:number;s:number;r:number}; keyTrack:number}; amp:{a:number;d:number;s:number;r:number}; drive:number; chorus:number; reverb:{mix:number;size:number}; gain:number}. Times in seconds, cutoff in Hz, levels 0..1, resonance 0..0.9.';

/** Validates an AI patch, filling gaps from the rule-based one. */
export function patchFromAi(json: unknown, fallback: Patch): Patch {
  const j = json as Partial<Patch> | null;
  if (!j || typeof j !== 'object') return fallback;
  const num = (v: unknown, lo: number, hi: number, d: number) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);
  const env = (e: Partial<Patch['amp']> | undefined, d: Patch['amp']) => ({ a: num(e?.a, 0, 4, d.a), d: num(e?.d, 0.001, 6, d.d), s: num(e?.s, 0, 1, d.s), r: num(e?.r, 0.001, 8, d.r) });
  const waves = ['sine', 'triangle', 'saw', 'square', 'noise'];
  const oscs = Array.isArray(j.oscs) ? j.oscs.slice(0, 3).filter((o) => o && waves.includes(o.wave)).map((o) => ({ wave: o.wave, level: num(o.level, 0, 1, 0.5), octave: Math.round(num(o.octave, -3, 3, 0)), detune: num(o.detune, -100, 100, 0) })) : [];
  return {
    name: typeof j.name === 'string' && j.name.trim() ? j.name.trim().slice(0, 60) : fallback.name,
    oscs: oscs.length ? oscs : fallback.oscs,
    unison: Math.round(num(j.unison, 1, 7, fallback.unison)),
    spread: num(j.spread, 0, 60, fallback.spread),
    filter: { type: j.filter && ['lp', 'bp', 'hp'].includes(j.filter.type) ? j.filter.type : fallback.filter.type, cutoff: num(j.filter?.cutoff, 40, 18000, fallback.filter.cutoff), resonance: num(j.filter?.resonance, 0, 0.9, fallback.filter.resonance), envAmount: num(j.filter?.envAmount, -4, 5, fallback.filter.envAmount), env: env(j.filter?.env, fallback.filter.env), keyTrack: num(j.filter?.keyTrack, 0, 1, fallback.filter.keyTrack) },
    amp: env(j.amp, fallback.amp),
    drive: num(j.drive, 0, 1, fallback.drive),
    chorus: num(j.chorus, 0, 1, fallback.chorus),
    reverb: { mix: num(j.reverb?.mix, 0, 1, fallback.reverb.mix), size: num(j.reverb?.size, 0, 1, fallback.reverb.size) },
    gain: num(j.gain, 0.1, 1.2, fallback.gain),
    glideBend: fallback.glideBend,
  };
}
