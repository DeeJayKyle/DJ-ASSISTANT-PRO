import { retune, semitoneShift } from './audio/stretch';
import type { StemName } from './audio/stems';

/**
 * Remix projects: tracks of clips taken from songs or their stems, placed on a beat grid. The
 * project has one tempo and key; every clip is time-stretched and pitch-shifted to match, so
 * the DJ only makes the creative choices.
 */
export type Layer = 'mix' | StemName;
export interface Source {
  id: string;
  name: string;
  sampleRate: number;
  layers: Partial<Record<Layer, Float32Array[]>>;
  bpm: number;
  firstBeat: number; // seconds
  key: { tonic: number; mode: 'major' | 'minor'; short: string };
  durationSec: number;
}
export interface Clip { id: string; sourceId: string; layer: Layer; start: number; offset: number; length: number; loops: number }
export interface RTrack { id: string; name: string; gain: number; pan: number; mute: boolean; solo: boolean; clips: Clip[] }
export interface Project { name: string; bpm: number; key: { tonic: number; mode: 'major' | 'minor' }; tracks: RTrack[] }

let seq = 0;
export const uid = (p: string) => `${p}${Date.now().toString(36)}${(seq++).toString(36)}`;

/** Semitones to move a source into the project key (minor ↔ major goes via the relative key). */
export function keyShift(src: { tonic: number; mode: string }, project: { tonic: number; mode: string }) {
  let target = project.tonic;
  if (src.mode !== project.mode) target = project.mode === 'major' ? (project.tonic + 9) % 12 : (project.tonic + 3) % 12;
  return semitoneShift(src.tonic, target);
}

/** Beats in a source after its first beat. */
export const sourceBeats = (s: Source) => Math.max(1, Math.floor(((s.durationSec - s.firstBeat) * s.bpm) / 60));

export function newTrackFor(source: Source, layer: Layer, project: Project): RTrack {
  const beats = Math.min(sourceBeats(source), 64);
  return { id: uid('t'), name: `${source.name}${layer === 'mix' ? '' : ` · ${layer}`}`, gain: 0.8, pan: 0, mute: false, solo: false, clips: [{ id: uid('c'), sourceId: source.id, layer, start: 0, offset: 0, length: beats, loops: 1 }] };
  void project;
}

export const projectBeats = (p: Project) => Math.max(16, ...p.tracks.flatMap((t) => t.clips.map((c) => c.start + c.length * c.loops)));

const cache = new Map<string, Float32Array[]>();
export const clearRenderCache = () => cache.clear();

function clipAudio(clip: Clip, src: Source, project: Project): Float32Array[] | null {
  const ch = src.layers[clip.layer];
  if (!ch) return null;
  const speed = project.bpm / (src.bpm || project.bpm);
  const semis = keyShift(src.key, project.key);
  const key = `${src.id}|${clip.layer}|${clip.offset}|${clip.length}|${speed.toFixed(5)}|${semis}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const a = Math.max(0, Math.round((src.firstBeat + (clip.offset * 60) / src.bpm) * src.sampleRate));
  const b = Math.min(ch[0].length, a + Math.round(((clip.length * 60) / src.bpm) * src.sampleRate));
  if (b <= a) return null;
  const seg = ch.map((c) => c.subarray(a, b));
  const out = retune(seg, speed, semis);
  cache.set(key, out);
  return out;
}

/** Renders the whole project (and each track on its own) at `sampleRate`. */
export function renderProject(project: Project, sources: Map<string, Source>, sampleRate: number): { mix: Float32Array[]; tracks: Map<string, Float32Array[]> } {
  const beatSec = 60 / project.bpm;
  const total = Math.ceil(projectBeats(project) * beatSec * sampleRate) + sampleRate;
  const mix = [new Float32Array(total), new Float32Array(total)];
  const tracks = new Map<string, Float32Array[]>();
  const soloed = project.tracks.some((t) => t.solo);
  for (const t of project.tracks) {
    const tl = [new Float32Array(total), new Float32Array(total)];
    for (const c of t.clips) {
      const src = sources.get(c.sourceId);
      if (!src) continue;
      const audio = clipAudio(c, src, project);
      if (!audio) continue;
      const loopLen = Math.round(c.length * beatSec * sampleRate);
      for (let rep = 0; rep < Math.max(1, c.loops); rep++) {
        const at = Math.round((c.start + rep * c.length) * beatSec * sampleRate);
        const n = Math.min(loopLen, audio[0].length, total - at);
        for (let ch = 0; ch < 2; ch++) {
          const x = audio[ch] ?? audio[0];
          const y = tl[ch];
          for (let i = 0; i < n; i++) y[at + i] += x[i];
        }
        // tiny fades at clip edges avoid clicks
        const f = Math.min(64, n >> 1);
        for (let i = 0; i < f; i++) for (let ch = 0; ch < 2; ch++) { tl[ch][at + i] *= i / f; tl[ch][at + n - 1 - i] *= i / f; }
      }
    }
    const angle = ((t.pan + 1) * Math.PI) / 4;
    const gl = Math.cos(angle) * Math.SQRT2 * t.gain, gr = Math.sin(angle) * Math.SQRT2 * t.gain;
    for (let i = 0; i < total; i++) { tl[0][i] *= gl; tl[1][i] *= gr; }
    tracks.set(t.id, tl);
    const audible = soloed ? t.solo : !t.mute;
    if (audible) for (let i = 0; i < total; i++) { mix[0][i] += tl[0][i]; mix[1][i] += tl[1][i]; }
  }
  // soft limit so stacked tracks don't clip
  for (const c of mix) for (let i = 0; i < c.length; i++) { const x = c[i]; c[i] = Math.abs(x) < 0.8 ? x : Math.sign(x) * (0.8 + 0.2 * Math.tanh((Math.abs(x) - 0.8) / 0.2)); }
  return { mix, tracks };
}
