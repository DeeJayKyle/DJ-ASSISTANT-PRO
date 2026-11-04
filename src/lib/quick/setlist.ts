import { compatibleCamelot } from './key';
import { family } from './genres';

/** What ordering needs to know about a track. */
export interface SetTrack {
  id: string;
  bpm: number;
  camelot: string;
  energy: number;
  genre: string;
}

export const byAscendingBpm = <T extends SetTrack>(t: T[]) => [...t].sort((a, b) => (a.bpm || 999) - (b.bpm || 999) || a.energy - b.energy);
export const byDescendingBpm = <T extends SetTrack>(t: T[]) => [...t].sort((a, b) => (b.bpm || 0) - (a.bpm || 0));
export const byGenre = <T extends SetTrack>(t: T[]) =>
  [...t].sort((a, b) => family(a.genre).localeCompare(family(b.genre)) || a.genre.localeCompare(b.genre) || (a.bpm || 999) - (b.bpm || 999));
export const byKey = <T extends SetTrack>(t: T[]) => [...t].sort((a, b) => camelotOrder(a.camelot) - camelotOrder(b.camelot) || a.bpm - b.bpm);

const camelotOrder = (c: string) => {
  const m = c.match(/^(\d+)([AB])$/);
  return m ? Number(m[1]) * 2 + (m[2] === 'B' ? 1 : 0) : 999;
};

/** How smoothly b follows a: harmonic match, a small tempo change, and energy that doesn't drop much. */
export function transitionCost(a: SetTrack, b: SetTrack) {
  const harmonic = compatibleCamelot(a.camelot).includes(b.camelot) ? 0 : 3;
  const tempo = a.bpm && b.bpm ? Math.min(Math.abs(a.bpm - b.bpm), Math.abs(a.bpm - b.bpm * 2), Math.abs(a.bpm * 2 - b.bpm)) / 2 : 2;
  const energyDrop = Math.max(0, a.energy - b.energy) * 1.5;
  return harmonic + tempo + energyDrop;
}

/**
 * Warm-up → peak: starts with the calmest, slowest track and keeps choosing the next track that
 * mixes in best (harmonic, close tempo) while the energy builds.
 */
export function warmupToPeak<T extends SetTrack>(tracks: T[]): T[] {
  if (tracks.length < 3) return [...tracks].sort((a, b) => a.energy - b.energy || a.bpm - b.bpm);
  const left = [...tracks];
  left.sort((a, b) => a.energy - b.energy || (a.bpm || 999) - (b.bpm || 999));
  const out = [left.shift()!];
  while (left.length) {
    const cur = out[out.length - 1];
    // Look ahead only among the next calmest tracks so the arc keeps building.
    const window = left.slice(0, Math.max(3, Math.ceil(left.length / 3)));
    let best = window[0];
    let bestCost = Infinity;
    for (const t of window) {
      const c = transitionCost(cur, t) + Math.max(0, t.energy - cur.energy - 2);
      if (c < bestCost) {
        bestCost = c;
        best = t;
      }
    }
    out.push(best);
    left.splice(left.indexOf(best), 1);
  }
  return out;
}

/** Average transition cost of an ordering (lower is smoother). */
export const setCost = (t: SetTrack[]) => (t.length < 2 ? 0 : t.slice(1).reduce((s, x, i) => s + transitionCost(t[i], x), 0) / (t.length - 1));

export type SortCommand = 'ascending-bpm' | 'descending-bpm' | 'warmup-peak' | 'genre' | 'key' | 'energy-up' | 'energy-down';

/** Understands simple sort requests typed in plain words, without AI. */
export function parseSortRequest(text: string): SortCommand | null {
  const t = text.toLowerCase();
  if (/warm\s*-?\s*up|build|journey|peak|set\b/.test(t) && !/genre/.test(t)) return 'warmup-peak';
  if (/genre|style/.test(t)) return 'genre';
  if (/harmonic|camelot|\bkey\b/.test(t)) return 'key';
  if (/(bpm|tempo|speed).*(desc|high|fast|down)|(desc|fast|high).*(bpm|tempo)/.test(t)) return 'descending-bpm';
  if (/bpm|tempo|speed|slow/.test(t)) return 'ascending-bpm';
  if (/energy.*(down|desc|cool|low)|cool\s*down|wind\s*down/.test(t)) return 'energy-down';
  if (/energy/.test(t)) return 'energy-up';
  return null;
}

export function applySort<T extends SetTrack>(cmd: SortCommand, tracks: T[]): T[] {
  switch (cmd) {
    case 'ascending-bpm': return byAscendingBpm(tracks);
    case 'descending-bpm': return byDescendingBpm(tracks);
    case 'warmup-peak': return warmupToPeak(tracks);
    case 'genre': return byGenre(tracks);
    case 'key': return byKey(tracks);
    case 'energy-up': return [...tracks].sort((a, b) => a.energy - b.energy || a.bpm - b.bpm);
    case 'energy-down': return [...tracks].sort((a, b) => b.energy - a.energy || b.bpm - a.bpm);
  }
}

/** Energy roles DJs use for bins: spread over the library so each role gets tracks. */
export type Role = 'Warm Up' | 'Groove' | 'Peak Time';
export function assignRoles<T extends { id: string; energy: number; bpm: number }>(tracks: T[]): Map<string, Role> {
  const sorted = [...tracks].sort((a, b) => a.energy - b.energy || a.bpm - b.bpm);
  const roles = new Map<string, Role>();
  sorted.forEach((t, i) => {
    if (tracks.length < 3) roles.set(t.id, t.energy <= 4 ? 'Warm Up' : t.energy >= 8 ? 'Peak Time' : 'Groove');
    else roles.set(t.id, i < sorted.length / 3 ? 'Warm Up' : i < (2 * sorted.length) / 3 ? 'Groove' : 'Peak Time');
  });
  return roles;
}
