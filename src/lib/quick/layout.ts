import { formatName, safeFileName, type CleanName, type NameFormat } from "./names";
import { family } from "./genres";

/** A track as Quick Prep's export needs it. */
export interface LayoutTrack {
  id: number;
  /** The name to use for the copy (clean, or the original file name without extension). */
  name: CleanName;
  genre: string;
  bpm: number;
}

export type Layout =
  | { kind: "clean" }
  | { kind: "playlist"; name: string; order: number[]; numbered: boolean }
  | { kind: "genres"; families: boolean }
  | { kind: "folders"; bins: { main: string; sub: string; ids: number[] }[] };

export interface PackLayout {
  items: { track_id: number; folder: string; name: string }[];
  playlists: { name: string; path: string; track_ids: number[] }[];
}

const folderName = (s: string) => safeFileName(s, 80);

/** Folders, file names and playlists for one of the four Quick Prep paths (the backend checks and copies). */
export function buildLayout(tracks: LayoutTrack[], layout: Layout, format: NameFormat): PackLayout {
  const byId = new Map(tracks.map((t) => [t.id, t]));
  const items: PackLayout["items"] = [];
  const playlists: PackLayout["playlists"] = [];
  const file = (t: LayoutTrack, prefix = "") => `${prefix}${safeFileName(formatName(t.name, format))}`;

  if (layout.kind === "clean") {
    for (const t of tracks) items.push({ track_id: t.id, folder: "", name: file(t) });
    playlists.push({ name: "All tracks", path: "All tracks.m3u8", track_ids: tracks.map((t) => t.id) });
  } else if (layout.kind === "playlist") {
    const dir = folderName(layout.name || "Playlist");
    const ordered = layout.order.map((id) => byId.get(id)).filter((t): t is LayoutTrack => !!t);
    const width = Math.max(2, String(ordered.length).length);
    ordered.forEach((t, i) => items.push({ track_id: t.id, folder: dir, name: file(t, layout.numbered ? `${String(i + 1).padStart(width, "0")} ` : "") }));
    playlists.push({ name: layout.name || "Playlist", path: `${dir}/${dir}.m3u8`, track_ids: ordered.map((t) => t.id) });
  } else if (layout.kind === "genres") {
    const groups = new Map<string, LayoutTrack[]>();
    for (const t of tracks) {
      const g = layout.families ? family(t.genre) : t.genre || "Other";
      groups.set(g, [...(groups.get(g) ?? []), t]);
    }
    for (const [g, list] of [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      const dir = folderName(g);
      const sorted = [...list].sort((a, b) => (a.bpm || 999) - (b.bpm || 999));
      for (const t of sorted) items.push({ track_id: t.id, folder: dir, name: file(t) });
      playlists.push({ name: g, path: `Playlists/${dir}.m3u8`, track_ids: sorted.map((t) => t.id) });
    }
  } else {
    const used = new Set<number>();
    for (const bin of layout.bins) {
      const list = bin.ids.map((id) => byId.get(id)).filter((t): t is LayoutTrack => !!t && !used.has(t.id));
      if (!list.length) continue;
      const dir = bin.sub ? `${folderName(bin.main)}/${folderName(bin.sub)}` : folderName(bin.main);
      const label = bin.sub ? `${bin.main} - ${bin.sub}` : bin.main;
      for (const t of list) {
        used.add(t.id);
        items.push({ track_id: t.id, folder: dir, name: file(t) });
      }
      playlists.push({ name: label, path: `Playlists/${folderName(label)}.m3u8`, track_ids: list.map((t) => t.id) });
    }
    const rest = tracks.filter((t) => !used.has(t.id));
    if (rest.length) {
      for (const t of rest) items.push({ track_id: t.id, folder: "Unsorted", name: file(t) });
      playlists.push({ name: "Unsorted", path: "Playlists/Unsorted.m3u8", track_ids: rest.map((t) => t.id) });
    }
  }
  return { items, playlists };
}
