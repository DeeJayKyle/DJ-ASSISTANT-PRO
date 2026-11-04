import type { TrackRow } from "../../types";
import { cleanName, formatName, needsCleanup, type CleanName, type NameFormat } from "../../lib/quick/names";
import { guessGenre } from "../../lib/quick/genres";
import { assignRoles, type Role } from "../../lib/quick/setlist";

/**
 * Quick Prep works on a batch of catalogued tracks. Measured values (BPM,
 * key, energy) and your edits come from the catalogue; clean names and genre
 * proposals live here until you save or export them.
 */
export type QScreen = "start" | "analysing" | "paths" | "clean" | "playlist" | "folders" | "genres";

export interface FolderSetup {
  mains: { name: string; subs: string[] }[];
}

export interface Proposal {
  name: CleanName;
  /** Typed by you (kept over automatic and AI suggestions). */
  edited: boolean;
  /** Where a proposed genre came from (only used when the catalogue has none, or AI suggested one). */
  genre?: { value: string; source: "ai" };
}

export interface QState {
  account: string;
  screen: QScreen;
  label: string;
  /** Where the batch came from (a library folder or a crate). */
  source: { root_id?: number; crate_id?: number };
  ids: number[];
  rows: Record<number, TrackRow>;
  proposals: Record<number, Proposal>;
  phase: { step: "idle" | "scanning" | "analysing" | "ready" | "failed"; done: number; total: number; message?: string };
  format: NameFormat;
  useClean: boolean;
  cleanupDismissed: boolean;
  playlist: { name: string; order: number[]; note: string };
  folders: FolderSetup;
  foldersReady: boolean;
  bins: Record<number, number>;
  families: boolean;
}

export const initialState = (account: string): QState => ({
  account,
  screen: "start",
  label: "",
  source: {},
  ids: [],
  rows: {},
  proposals: {},
  phase: { step: "idle", done: 0, total: 0 },
  format: "artist-title",
  useClean: true,
  cleanupDismissed: false,
  playlist: { name: "My Set", order: [], note: "" },
  folders: { mains: [{ name: "Friday Night", subs: ["Warm Up", "Groove", "Peak Time"] }, { name: "Saturday", subs: ["Warm Up", "Groove", "Peak Time"] }] },
  foldersReady: false,
  bins: {},
  families: false,
});

/** The automatic clean name: catalogue values win, the file name fills gaps. */
export const autoName = (r: TrackRow): CleanName => {
  const n = cleanName(r.file_name, { artist: r.artist ?? undefined, title: r.title ?? undefined });
  return !n.mix && r.version ? { ...n, mix: r.version } : n;
};

export interface QTrack {
  id: number;
  row: TrackRow;
  name: CleanName;
  edited: boolean;
  display: string;
  genre: string;
  genreSource: "catalogue" | "ai" | "guess";
  bpm: number;
  camelot: string;
  energy: number;
  messy: boolean;
  role: Role;
}

export function tracksOf(st: QState): QTrack[] {
  const base = st.ids.map((id) => st.rows[id]).filter((r): r is TrackRow => !!r && r.status === "ok");
  const roles = assignRoles(base.map((r) => ({ id: String(r.id), energy: r.energy ?? 5, bpm: r.bpm ?? 0 })));
  return base.map((r) => {
    const p = st.proposals[r.id];
    const name = p?.name ?? autoName(r);
    const ai = p?.genre?.source === "ai" ? p.genre.value : null;
    const genre = ai ?? r.genre ?? guessGenre(r.bpm ?? 0, r.energy ?? 5);
    return {
      id: r.id,
      row: r,
      name,
      edited: !!p?.edited,
      display: formatName(name, st.format),
      genre,
      genreSource: ai ? "ai" : r.genre ? "catalogue" : "guess",
      bpm: r.bpm ?? 0,
      camelot: r.key ?? "",
      energy: r.energy ?? 5,
      // Messy until the clean name is in the catalogue (file names themselves never change).
      messy: needsCleanup(r.file_name, name, st.format) && !((name.title || null) === r.title && (name.artist || null) === r.artist && (name.mix || null) === (r.version ?? null)),
      role: roles.get(String(r.id)) ?? "Groove",
    };
  });
}

/** Bins in reading order: each sub-folder, or the main folder itself when it has none. */
export const flatBins = (f: FolderSetup) => f.mains.flatMap((m) => (m.subs.length ? m.subs.map((s) => ({ main: m.name, sub: s })) : [{ main: m.name, sub: "" }]));

/** Plain message from an API error. */
export const msg = (e: unknown) => String((e as Error)?.message ?? e);
