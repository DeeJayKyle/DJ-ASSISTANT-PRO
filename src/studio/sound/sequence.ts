import { renderPad, type Kit } from './drums';
import { writeMidi, type Note } from '../audio/midi';

/** A 16-step drum pattern: one row of steps per pad, with tempo and swing. */
export interface Pattern { bpm: number; swing: number; steps: boolean[][] }

export const STEPS = 16;

/** A starting groove: four-on-the-floor kick, backbeat snare/clap, off-beat and 16th hats. */
export function defaultPattern(kit: Kit, bpm = 124): Pattern {
  const steps = kit.pads.map(() => new Array(STEPS).fill(false));
  const idx = (type: string) => kit.pads.findIndex((p) => p.type === type);
  const kick = idx('kick'), snare = idx('snare'), clap = idx('clap'), ch = idx('closedHat'), oh = idx('openHat');
  for (let s = 0; s < STEPS; s++) {
    if (kick >= 0 && s % 4 === 0) steps[kick][s] = true;
    if (clap >= 0 && (s === 4 || s === 12)) steps[clap][s] = true;
    if (snare >= 0 && s === 12) steps[snare][s] = true;
    if (oh >= 0 && s % 4 === 2) steps[oh][s] = true;
    if (ch >= 0 && s % 2 === 1) steps[ch][s] = true;
  }
  return { bpm, swing: 0, steps };
}

/** Start time (seconds) of each step in one bar; swing delays the off-beat 16ths. */
export function stepTimes(p: Pattern) {
  const step = 60 / p.bpm / 4;
  return Array.from({ length: STEPS }, (_, s) => s * step + (s % 2 === 1 ? p.swing * step * 0.5 : 0));
}

/** Renders `bars` bars of the pattern with the kit (stereo, exact loop length). */
export function renderPattern(kit: Kit, p: Pattern, bars = 2, sampleRate = 44100): Float32Array[] {
  const barSec = (60 / p.bpm) * 4;
  const n = Math.round(barSec * bars * sampleRate);
  const L = new Float32Array(n), R = new Float32Array(n);
  const times = stepTimes(p);
  kit.pads.forEach((pad, i) => {
    if (!p.steps[i]?.some(Boolean)) return;
    const [hl, hr] = renderPad(pad, sampleRate);
    for (let b = 0; b < bars; b++) {
      for (let s = 0; s < STEPS; s++) {
        if (!p.steps[i][s]) continue;
        const at = Math.round((b * barSec + times[s]) * sampleRate);
        // hits that ring past the end wrap round, so the loop is seamless
        for (let j = 0; j < hl.length; j++) { const k = (at + j) % n; L[k] += hl[j]; R[k] += hr[j]; }
      }
    }
  });
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
  if (peak > 0.98) { const g = 0.98 / peak; for (let i = 0; i < n; i++) { L[i] *= g; R[i] *= g; } }
  return [L, R];
}

/** The pattern as a MIDI drum track (channel 10, the kit's pad notes). */
export function patternMidi(kit: Kit, p: Pattern, bars = 4): Uint8Array {
  const barSec = (60 / p.bpm) * 4;
  const times = stepTimes(p);
  const notes: Note[] = [];
  for (let b = 0; b < bars; b++) kit.pads.forEach((pad, i) => p.steps[i]?.forEach((on, s) => { if (on) notes.push({ pitch: pad.note, start: b * barSec + times[s], end: b * barSec + times[s] + 0.1, velocity: 110 }); }));
  return writeMidi([{ name: kit.name, channel: 9, notes }], p.bpm);
}
