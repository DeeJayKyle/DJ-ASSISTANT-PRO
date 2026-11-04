import { describe, it, expect } from 'vitest';
import { kickPattern, chords, mix } from './signals';
import { separate, instrumental, STEMS } from '../audio/stems';
import { detectChords } from '../audio/chords';
import { transcribePitched, transcribeDrums, writeMidi, readMidi, chordNotes } from '../audio/midi';
import { encodeWav, decodeWav } from '../audio/wav';
import { timeStretch, pitchShift, retune, Deck, semitoneShift } from '../audio/stretch';
import { beatPhase } from '../audio/beats';
import { renderNote } from '../sound/synth';
import { renderPad } from '../sound/drums';
import { patchFromPrompt, kitFromPrompt, patchFromAi } from '../sound/prompt';
import { kitFiles, instrumentFiles } from '../sound/export';
import { renderProject, keyShift, type Project, type Source } from '../remix';

const SR = 22050;
const tone = (hz: number, sec: number, harmonics = 1, vib = 0) => {
  const x = new Float32Array(Math.floor(sec * SR));
  let ph = 0;
  for (let i = 0; i < x.length; i++) {
    const f = hz * (1 + vib * Math.sin(2 * Math.PI * 5 * (i / SR)));
    ph += f / SR;
    let s = 0;
    for (let h = 1; h <= harmonics; h++) s += Math.sin(2 * Math.PI * ph * h) / h;
    x[i] = s * 0.25;
  }
  return x;
};
const zeroCrossHz = (x: Float32Array, sr: number) => { let z = 0; for (let i = 1; i < x.length; i++) if (x[i - 1] < 0 && x[i] >= 0) z++; return z / (x.length / sr); };
const dot = (a: Float32Array, b: Float32Array) => { let s = 0; for (let i = 0; i < Math.min(a.length, b.length); i++) s += a[i] * b[i]; return s; };
const energy = (a: Float32Array) => dot(a, a);

describe('stem separation', () => {
  it('sends each part of a mix to the right stem, and the stems add back up to the mix', () => {
    const sec = 6;
    const kick = kickPattern(120, sec, SR);
    const bass = tone(55, sec, 1);
    const voice = tone(330, sec, 6, 0.01);
    const pad = tone(523, sec, 3);
    const L = mix(kick, bass, voice, pad);
    const R = mix(kick, bass, voice); // pad only on the left
    const stems = separate([L, R], SR);
    // the stems sum back to the mix
    let err = 0;
    for (let i = 4000; i < L.length - 4000; i += 7) { let s = 0; for (const st of STEMS) s += stems[st][0][i]; err = Math.max(err, Math.abs(s - L[i])); }
    expect(err).toBeLessThan(1e-3);
    // each source lands mostly in its stem (fraction of the source's energy captured by projection)
    const share = (stem: keyof typeof stems, src: Float32Array) => dot(stems[stem][1], src) / energy(src) + (stem === 'melodies' ? 0 : 0);
    expect(share('drums', kick)).toBeGreaterThan(0.5);
    expect(share('bass', bass)).toBeGreaterThan(0.6);
    expect(share('vocals', voice)).toBeGreaterThan(0.5);
    expect(dot(stems.melodies[0], pad) / energy(pad)).toBeGreaterThan(0.5);
    const inst = instrumental(stems);
    expect(dot(inst[1], voice) / energy(voice)).toBeLessThan(0.5);
  }, 60_000);
});

describe('chords, key and MIDI', () => {
  it('follows a chord progression', () => {
    // A minor, F, C, G — with the root in the bass
    const prog = [[45, 57, 60, 64], [41, 57, 60, 65], [48, 55, 60, 64], [43, 55, 59, 62]];
    const segs = detectChords(chords(prog, 2, SR), SR);
    const names = segs.filter((s) => s.end - s.start > 1).map((s) => s.name);
    expect(names).toEqual(['Am', 'F', 'C', 'G']);
    expect(chordNotes(segs).length).toBeGreaterThanOrEqual(12);
  });

  it('transcribes a bass line and drum hits, and writes a MIDI file that reads back', () => {
    const line = [33, 36, 40, 43]; // A1 C2 E2 G2
    const bass = new Float32Array(Math.floor(2 * SR));
    line.forEach((m, k) => { const t = tone(440 * 2 ** ((m - 69) / 12), 0.5, 2); bass.set(t, Math.floor(k * 0.5 * SR)); });
    const notes = transcribePitched(bass, SR, { minHz: 30, maxHz: 400 });
    expect(notes.map((n) => n.pitch)).toEqual(line);
    const drums = transcribeDrums(kickPattern(120, 4, SR), SR);
    const kicks = drums.filter((n) => n.pitch === 36);
    expect(kicks.length).toBeGreaterThanOrEqual(7);
    expect(kicks.length).toBeLessThanOrEqual(9);
    const file = writeMidi([{ name: 'Bass', channel: 0, notes }, { name: 'Drums', channel: 9, notes: drums }], 120);
    const back = readMidi(file);
    expect(back.ppq).toBe(480);
    expect(back.tracks[1].name).toBe('Bass');
    expect(back.tracks[1].notes.map((n) => n.pitch)).toEqual(line);
    // 0.5 s at 120 BPM = one beat = 480 ticks
    expect(Math.abs(back.tracks[1].notes[1].tick - 480)).toBeLessThan(30);
  });

  it('finds the beat phase', () => {
    const x = new Float32Array(Math.floor(8 * SR));
    x.set(kickPattern(120, 7.8, SR), Math.floor(0.2 * SR));
    const ph = beatPhase(x, SR, 120);
    expect(Math.abs(((ph - 0.2 + 0.25) % 0.5) - 0.25)).toBeLessThan(0.03);
  });

  it('writes and reads WAV', () => {
    const a = tone(440, 0.1);
    for (const bits of [16, 24] as const) {
      const back = decodeWav(encodeWav([a, a], SR, bits));
      expect(back.sampleRate).toBe(SR);
      expect(back.channels).toHaveLength(2);
      expect(Math.abs(back.channels[1][100] - a[100])).toBeLessThan(1e-3);
    }
  });
});

describe('tempo and key changes', () => {
  it('stretches without changing pitch, and shifts pitch without changing length', () => {
    const a = tone(440, 1);
    const s = timeStretch([a], 1.5)[0];
    expect(s.length).toBe(Math.round(a.length * 1.5));
    expect(Math.abs(zeroCrossHz(s.subarray(2000, s.length - 2000), SR) - 440)).toBeLessThan(12);
    const p = pitchShift([a], 12)[0];
    expect(p.length).toBe(a.length);
    expect(Math.abs(zeroCrossHz(p.subarray(2000, p.length - 2000), SR) - 880)).toBeLessThan(25);
    const r = retune([a], 1.25, -12)[0];
    expect(Math.abs(r.length - a.length / 1.25)).toBeLessThan(2);
    expect(Math.abs(zeroCrossHz(r.subarray(2000, r.length - 2000), SR) - 220)).toBeLessThan(10);
  });

  it('plays a deck in real time at any tempo and key', () => {
    const a = tone(440, 2);
    const deck = new Deck([[a, a]]);
    deck.seek(0);
    deck.playing = true;
    const out = [new Float32Array(SR), new Float32Array(SR)];
    for (let o = 0; o < SR; o += 128) deck.render([out[0].subarray(o, o + 128), out[1].subarray(o, o + 128)], Math.min(128, SR - o));
    expect(Math.abs(zeroCrossHz(out[0].subarray(4000), SR) - 440)).toBeLessThan(10);
    const fast = new Deck([[a, a]]);
    fast.rate = 1.5; fast.pitch = 2 ** (2 / 12); fast.seek(0); fast.playing = true;
    const o2 = [new Float32Array(SR / 2), new Float32Array(SR / 2)];
    for (let o = 0; o < SR / 2; o += 128) fast.render([o2[0].subarray(o, o + 128), o2[1].subarray(o, o + 128)], 128);
    expect(fast.pos).toBeGreaterThan(SR * 0.7);
    expect(Math.abs(zeroCrossHz(o2[0].subarray(3000), SR) - 440 * 2 ** (2 / 12))).toBeLessThan(15);
  });

  it('moves keys the short way round', () => {
    expect(semitoneShift(9, 0)).toBe(3);
    expect(semitoneShift(0, 11)).toBe(-1);
    expect(keyShift({ tonic: 9, mode: 'minor' }, { tonic: 0, mode: 'major' })).toBe(0); // A minor ↔ C major
    expect(keyShift({ tonic: 2, mode: 'minor' }, { tonic: 9, mode: 'minor' })).toBe(-5);
  });
});

describe('remix', () => {
  it('syncs clips to the project tempo and mixes tracks', () => {
    const loop = kickPattern(100, 4.8, SR); // 8 beats at 100 BPM
    const src: Source = { id: 's', name: 'Loop', sampleRate: SR, layers: { mix: [loop, loop] }, bpm: 100, firstBeat: 0, key: { tonic: 0, mode: 'major', short: 'C' }, durationSec: 4.8 };
    const project: Project = { name: 'Test', bpm: 120, key: { tonic: 0, mode: 'major' }, tracks: [{ id: 't1', name: 'Loop', gain: 1, pan: 0, mute: false, solo: false, clips: [{ id: 'c', sourceId: 's', layer: 'mix', start: 4, offset: 0, length: 4, loops: 2 }] }] };
    const { mix: m, tracks } = renderProject(project, new Map([['s', src]]), SR);
    // clip starts at beat 4 = 2 s at 120 BPM; nothing before it
    expect(energy(m[0].subarray(0, Math.floor(1.9 * SR)))).toBe(0);
    expect(energy(m[0].subarray(Math.floor(2 * SR), Math.floor(6 * SR)))).toBeGreaterThan(1);
    // two loops of 4 beats = 4 s; then silence
    expect(energy(m[0].subarray(Math.floor(6.2 * SR)))).toBeLessThan(0.05);
    expect(tracks.get('t1')).toBeTruthy();
    project.tracks[0].mute = true;
    expect(energy(renderProject(project, new Map([['s', src]]), SR).mix[0])).toBe(0);
  });
});

describe('sound design from words', () => {
  it('turns descriptions into patches and kits', () => {
    const sub = patchFromPrompt('dark thick sub bass');
    expect(sub.oscs[0].octave).toBe(-1);
    expect(sub.unison).toBeGreaterThanOrEqual(5);
    const organ = patchFromPrompt('bright cinematic synth organ');
    expect(organ.reverb.mix).toBeGreaterThanOrEqual(0.5);
    expect(organ.filter.cutoff).toBeGreaterThan(sub.filter.cutoff);
    expect(patchFromPrompt('warm pad', 1)).not.toEqual(patchFromPrompt('warm pad', 2));
    expect(patchFromPrompt('warm pad', 3)).toEqual(patchFromPrompt('warm pad', 3));
    const trap = kitFromPrompt('crisp trap kit with booming 808');
    const techno = kitFromPrompt('deep punchy techno');
    expect(trap.pads).toHaveLength(16);
    expect(trap.pads.map((p) => p.note)).toEqual(Array.from({ length: 16 }, (_, i) => 36 + i));
    expect(trap.pads[0].decay).toBeGreaterThan(techno.pads[0].decay);
    const ai = patchFromAi({ name: 'AI Pad', oscs: [{ wave: 'saw', level: 2, octave: 9, detune: 0 }, { wave: 'bogus' }], filter: { cutoff: 99999 } }, sub);
    expect(ai.oscs).toHaveLength(1);
    expect(ai.oscs[0].level).toBe(1);
    expect(ai.oscs[0].octave).toBe(3);
    expect(ai.filter.cutoff).toBe(18000);
  });

  it('renders playable notes and drum hits', () => {
    const note = renderNote({ ...patchFromPrompt('soft sine organ'), oscs: [{ wave: 'sine', level: 0.6, octave: 0, detune: 0 }], reverb: { mix: 0, size: 0 }, chorus: 0, unison: 1 }, 69, 0.5, SR);
    expect(note[0].every(Number.isFinite)).toBe(true);
    expect(Math.abs(zeroCrossHz(note[0].subarray(1000, Math.floor(0.45 * SR)), SR) - 440)).toBeLessThan(8);
    for (const p of kitFromPrompt('gritty saturated synthwave drums').pads) {
      const [l] = renderPad(p, SR);
      expect(l.every(Number.isFinite)).toBe(true);
      expect(energy(l)).toBeGreaterThan(0);
    }
  });

  it('exports kits and instruments as WAV + SFZ', () => {
    const files = kitFiles(kitFromPrompt('dusty lofi hip hop kit'), SR);
    expect(files).toHaveLength(18);
    expect(decodeWav(files[0].bytes).channels).toHaveLength(2);
    const sfz = new TextDecoder().decode(files.find((f) => f.name.endsWith('.sfz'))!.bytes);
    expect(sfz).toContain('key=36');
    const inst = instrumentFiles(patchFromPrompt('glassy bell pluck'), SR);
    expect(inst.filter((f) => f.name.endsWith('.wav')).length).toBe(13);
  });
});

describe('parallel separation', () => {
  it('gives the same stems when split into parts', async () => {
    const { planParts, separatePart, mergeParts, separate: whole } = await import('../audio/stems');
    const sec = 3;
    const L = mix(kickPattern(120, sec, SR), tone(220, sec, 4)), R = mix(kickPattern(120, sec, SR), tone(330, sec, 2));
    const ref = whole([L, R], SR);
    const parts = planParts(L.length, 3).map((p) => separatePart([L.subarray(p.inStart, p.inEnd), R.subarray(p.inStart, p.inEnd)], p.inStart, L.length, SR, p.f0, p.f1));
    const got = mergeParts(parts, L.length);
    let err = 0;
    for (const st of STEMS) for (let c = 0; c < 2; c++) for (let i = 0; i < L.length; i += 3) err = Math.max(err, Math.abs(got[st][c][i] - ref[st][c][i]));
    expect(err).toBeLessThan(1e-5);
  }, 60_000);
});
