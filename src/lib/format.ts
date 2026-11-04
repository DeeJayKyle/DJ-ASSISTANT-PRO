export const UNKNOWN = "—";

export function duration(ms: number | null | undefined): string {
  if (ms == null || ms <= 0) return UNKNOWN;
  const s = Math.round(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

export function longDuration(ms: number): string {
  const h = Math.floor(ms / 3_600_000);
  const m = Math.round((ms % 3_600_000) / 60_000);
  if (h === 0) return `${m} min`;
  return `${h} h ${m} min`;
}

export function bytes(n: number | null | undefined): string {
  if (n == null) return UNKNOWN;
  const u = ["B", "KB", "MB", "GB", "TB"];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)} ${u[i]}`;
}

export function bpm(v: number | null | undefined): string {
  if (v == null) return UNKNOWN;
  return Number.isInteger(v) ? String(v) : v.toFixed(1);
}

export function text(v: unknown): string {
  if (v == null || v === "") return UNKNOWN;
  return String(v);
}

export function dateTime(ms: number | null | undefined): string {
  if (!ms) return UNKNOWN;
  return new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

export function plural(n: number, word: string, pluralWord = `${word}s`): string {
  return `${n.toLocaleString()} ${n === 1 ? word : pluralWord}`;
}

export const QUALITY_LABEL: Record<string, string> = {
  lossless: "Lossless",
  lossy: "Lossy",
  low_bitrate: "Low bitrate",
  unknown: "Unknown",
  video: "Video",
};

export const STATUS_LABEL: Record<string, string> = {
  ok: "OK",
  error: "Unreadable",
  unsupported: "Unsupported",
  missing: "Missing",
  offline: "Offline",
};

// ---- Key notation --------------------------------------------------------
// The catalogue always stores and reports Camelot codes (8A). The DJ can
// choose to see them as Camelot or as standard musical names (Am).
export type KeyNotation = "camelot" | "musical";
let keyNotation: KeyNotation = "camelot";
export function setKeyNotation(n: KeyNotation) {
  keyNotation = n === "musical" ? "musical" : "camelot";
}
export function getKeyNotation(): KeyNotation {
  return keyNotation;
}
const MINOR = ["Abm", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am", "Em", "Bm", "F#m", "C#m"];
const MAJOR = ["B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E"];

/** Camelot code -> musical name, e.g. "8A" -> "Am". Null if not a Camelot code. */
export function camelotToMusical(c: string): string | null {
  const m = /^\s*0?(1[0-2]|[1-9])\s*([AaBb])\s*$/.exec(c);
  if (!m) return null;
  const i = Number(m[1]) - 1;
  return m[2].toUpperCase() === "A" ? MINOR[i] : MAJOR[i];
}

/** Musical name -> Camelot code, e.g. "F#m" / "F# minor" -> "11A". */
export function musicalToCamelot(k: string): string | null {
  const t = k.trim().replace(/♯/g, "#").replace(/♭/g, "b").replace(/\s+/g, "");
  if (camelotToMusical(t)) return t.replace(/^0/, "").toUpperCase();
  const m = /^([A-Ga-g])([#b]?)(m|min|minor|maj|major)?$/i.exec(t);
  if (!m) return null;
  const minor = !!m[3] && /^m(in(or)?)?$/i.test(m[3]);
  const aliases: Record<string, string> = { "C#": "Db", "D#": "Eb", "Gb": "F#", "G#": "Ab", "A#": "Bb", "Cb": "B", "Fb": "E", "E#": "F", "B#": "C" };
  let root = m[1].toUpperCase() + (m[2] || "");
  if (minor) {
    const minorAliases: Record<string, string> = { "Db": "C#", "Gb": "F#", "G#": "Ab", "D#": "Eb", "A#": "Bb", "Cb": "B", "Fb": "E", "E#": "F", "B#": "C" };
    root = minorAliases[root] ?? root;
    const i = MINOR.indexOf(root + "m");
    return i < 0 ? null : `${i + 1}A`;
  }
  root = aliases[root] ?? root;
  const i = MAJOR.indexOf(root);
  return i < 0 ? null : `${i + 1}B`;
}

/** Display a key in the chosen notation. Unrecognised text is shown as-is. */
export function keyName(k: string | null | undefined, notation: KeyNotation = keyNotation): string {
  if (k == null || k === "") return UNKNOWN;
  const c = musicalToCamelot(k);
  if (!c) return k;
  return notation === "musical" ? camelotToMusical(c) ?? k : c;
}

/** The other notation, for a hover hint ("8A = Am"). */
export function keyHint(k: string | null | undefined): string | undefined {
  if (!k) return undefined;
  const c = musicalToCamelot(k);
  if (!c) return undefined;
  return `${c} = ${camelotToMusical(c)}`;
}

// ---- Video ---------------------------------------------------------------
/** "1080p", "4K", "720p" from a frame height. */
export function resLabel(height: number | null | undefined): string {
  if (!height) return UNKNOWN;
  if (height >= 2000) return "4K";
  if (height >= 1400) return "1440p";
  return `${height}p`;
}

/** "1920×1080 · H.264 · 29.97 fps" */
export function videoSummary(t: { width: number | null; height: number | null; video_codec: string | null; frame_rate: number | null }): string {
  const parts = [
    t.width && t.height ? `${t.width}×${t.height}` : null,
    t.video_codec,
    t.frame_rate ? `${Math.round(t.frame_rate * 100) / 100} fps` : null,
  ].filter(Boolean);
  return parts.length ? parts.join(" · ") : "Video";
}
