// Colour themes, background styles, page transitions and animation speed.
// Everything is applied as CSS variables on <html>, so it repaints instantly.

export interface UiPrefs {
  preset?: string;          // colour preset id
  accent?: string;          // custom accent colour (#rrggbb) — overrides the preset's accent
  background?: "deep" | "midnight" | "plum" | "charcoal";
  transition?: "slide" | "fade" | "zoom";
  speed?: number;           // animation speed multiplier, 0.5 (slow) … 1.5 (snappy)
  sounds?: boolean;         // completion sounds
  volume?: number;          // 0 … 1
}

export const PRESETS: Array<{ id: string; name: string; accent: string; accent2: string }> = [
  { id: "mint", name: "Mint", accent: "#4fe0a6", accent2: "#2fc58e" },
  { id: "ocean", name: "Ocean", accent: "#4cb8ff", accent2: "#2f8fe0" },
  { id: "violet", name: "Violet", accent: "#a98bff", accent2: "#8466f0" },
  { id: "sunset", name: "Sunset", accent: "#ff9f5a", accent2: "#f07a3a" },
  { id: "rose", name: "Rose", accent: "#ff6f9c", accent2: "#e94d80" },
  { id: "gold", name: "Gold", accent: "#f5c74f", accent2: "#d9a92a" },
  { id: "cyan", name: "Cyan", accent: "#2ee6e6", accent2: "#14bcbc" },
  { id: "lime", name: "Lime", accent: "#b4f04a", accent2: "#8fcc2a" },
];

export const BACKGROUNDS: Array<{ id: NonNullable<UiPrefs["background"]>; name: string; bg: string; bg2: string; panel: string }> = [
  { id: "deep", name: "Deep", bg: "#0c0f12", bg2: "#11151a", panel: "#161b21" },
  { id: "midnight", name: "Midnight blue", bg: "#0a0e1a", bg2: "#0f1526", panel: "#141c30" },
  { id: "plum", name: "Plum", bg: "#110c16", bg2: "#17111e", panel: "#1e1627" },
  { id: "charcoal", name: "Charcoal", bg: "#121212", bg2: "#181818", panel: "#1f1f1f" },
];

function hexToRgb(h: string): [number, number, number] | null {
  const m = /^#?([0-9a-f]{6})$/i.exec(h.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
const rgba = (rgb: [number, number, number], a: number) => `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, ${a})`;
function shade(rgb: [number, number, number], f: number): string {
  const c = rgb.map((v) => Math.round(Math.max(0, Math.min(255, f < 0 ? v * (1 + f) : v + (255 - v) * f))));
  return `#${c.map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}
/** Text colour that stays readable on the accent. */
function inkFor(rgb: [number, number, number]): string {
  const l = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
  return l > 0.55 ? "#07130e" : "#ffffff";
}

const VARS = ["--mint", "--mint-2", "--mint-ink", "--mint-soft", "--mint-line", "--mint-deep", "--focus", "--bg", "--bg-2", "--panel", "--dur-press", "--dur-hover", "--dur-card", "--dur-modal", "--dur-chart", "--accent-glow"];

export function applyUiPrefs(p: UiPrefs | undefined, light: boolean) {
  const r = document.documentElement;
  const s = r.style;
  VARS.forEach((v) => s.removeProperty(v));
  const prefs = p ?? {};
  const preset = PRESETS.find((x) => x.id === prefs.preset);
  const accent = hexToRgb(prefs.accent ?? preset?.accent ?? "") ?? null;
  if (accent) {
    const a2 = prefs.accent ? shade(accent, -0.18) : preset!.accent2;
    s.setProperty("--mint", shade(accent, 0));
    s.setProperty("--mint-2", a2);
    s.setProperty("--mint-ink", inkFor(accent));
    s.setProperty("--mint-soft", rgba(accent, light ? 0.16 : 0.13));
    s.setProperty("--mint-line", rgba(accent, 0.45));
    s.setProperty("--mint-deep", shade(accent, -0.68));
    s.setProperty("--focus", shade(accent, 0.25));
    s.setProperty("--accent-glow", rgba(accent, 0.1));
  }
  const bg = BACKGROUNDS.find((b) => b.id === prefs.background);
  if (bg && !light) {
    s.setProperty("--bg", bg.bg);
    s.setProperty("--bg-2", bg.bg2);
    s.setProperty("--panel", bg.panel);
  }
  const k = Math.min(1.5, Math.max(0.5, prefs.speed ?? 1));
  // Higher speed = shorter durations.
  const d = (ms: number) => `${Math.round(ms / k)}ms`;
  if (k !== 1) {
    s.setProperty("--dur-press", d(120));
    s.setProperty("--dur-hover", d(150));
    s.setProperty("--dur-card", d(300));
    s.setProperty("--dur-modal", d(220));
    s.setProperty("--dur-chart", d(600));
  }
  r.dataset.transition = prefs.transition ?? "slide";
}
