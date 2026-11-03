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
};

export const STATUS_LABEL: Record<string, string> = {
  ok: "OK",
  error: "Unreadable",
  unsupported: "Unsupported",
  missing: "Missing",
  offline: "Offline",
};
