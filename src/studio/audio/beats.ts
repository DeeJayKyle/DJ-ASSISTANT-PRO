import { onsetEnvelope, detectTempo } from '../dsp/bpm';
import { detectKey } from '../dsp/key';

/** Tempo, beat phase and key for a song or stem, so decks and remix clips can be synced. */
export interface Rhythm { bpm: number; firstBeat: number; key: { tonic: number; mode: 'major' | 'minor'; short: string; camelot: string } }

/** Time of the first downbeat-ish beat: the phase whose beat grid lines up best with the onsets. */
export function beatPhase(mono: Float32Array, sampleRate: number, bpm: number) {
  const { env, rate } = onsetEnvelope(mono, sampleRate);
  if (!bpm || !env.length) return 0;
  const period = (60 / bpm) * rate;
  let best = 0, bestScore = -1;
  const steps = Math.max(8, Math.round(period));
  for (let s = 0; s < steps; s++) {
    const phase = (s / steps) * period;
    let score = 0;
    for (let t = phase; t < env.length; t += period) {
      const i = Math.round(t);
      score += (env[i] ?? 0) + 0.5 * ((env[i - 1] ?? 0) + (env[i + 1] ?? 0));
    }
    if (score > bestScore) { bestScore = score; best = phase; }
  }
  // The onset envelope is stamped at each 1024-sample frame's start, but an attack registers
  // as it enters the frame (~0.07 s later at the envelope's 11 kHz rate).
  return (best / rate + 0.07) % (60 / bpm);
}

export function rhythm(mono: Float32Array, sampleRate: number, knownBpm?: number): Rhythm {
  const bpm = knownBpm && knownBpm > 0 ? knownBpm : detectTempo(mono, sampleRate).bpm;
  const k = detectKey(mono, sampleRate);
  return { bpm, firstBeat: beatPhase(mono, sampleRate, bpm), key: { tonic: k.tonic, mode: k.mode, short: k.short, camelot: k.camelot } };
}
