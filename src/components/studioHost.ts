import { api, call, isDesktop, pickFolder, pickSave, reveal, trackUrl, isBridge, bridgeUrl } from "../api";
import type { StudioHost } from "../studio/ui/host";
import { keyName } from "../lib/format";

/**
 * Connects the Studio to DJ Assistant: catalogue tracks (read-only previews over track:),
 * new files saved through the backend (never over music files), and the assistant's AI model.
 */
declare global { interface Window { __studioSaveDir?: string } }

async function write(bytes: Uint8Array, headers: Record<string, string>): Promise<string> {
  const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k, encodeURIComponent(v)]));
  if (isDesktop()) {
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke<string>("studio_write", bytes, { headers: h });
  }
  if (isBridge) {
    const r = await fetch(`${bridgeUrl}/studio-write`, { method: "POST", headers: h, body: bytes as BodyInit });
    const b = await r.json();
    if (b.error) throw new Error(b.error);
    return b.ok as string;
  }
  throw new Error("Saving needs the desktop app.");
}

const sep = (dir: string) => (dir.includes("\\") ? "\\" : "/");

export function makeStudioHost(toast: (m: string, err?: boolean) => void): StudioHost {
  return {
    appName: "DJ Assistant",
    async songs(q) {
      const page = await api.search({ text: q || null, limit: 300, sort: "artist" });
      return page.rows
        .filter((r) => r.status === "ok" && r.media_kind === "audio")
        .map((r) => ({ id: String(r.id), title: ((t) => (r.artist ? `${r.artist} - ${t}` : t))(r.title ?? r.file_name.replace(/\.[^.]+$/, "")), artist: r.artist, bpm: r.bpm, key: r.key ? keyName(r.key) : null, durationSec: r.duration_ms ? r.duration_ms / 1000 : null }));
    },
    audioUrl: (s) => trackUrl(Number(s.id)),
    async saveFile(name, bytes) {
      const ext = name.split(".").pop() ?? "wav";
      let path: string | null = null;
      if (isDesktop()) path = await pickSave("Save", name, [ext]);
      else if (window.__studioSaveDir) path = `${window.__studioSaveDir}${sep(window.__studioSaveDir)}${name}`;
      if (!path) return null;
      return write(bytes, { "x-mode": "file", "x-path": path, "x-overwrite": isDesktop() ? "1" : "0" });
    },
    async saveFiles(folderName, files) {
      const parent = isDesktop() ? await pickFolder("Where to save") : (window.__studioSaveDir ?? null);
      if (!parent) return null;
      const { path } = await call<{ path: string }>("studio_new_folder", { parent, name: folderName });
      for (const f of files) await write(f.bytes, { "x-mode": "into", "x-path": path, "x-name": f.name });
      return path;
    },
    ai: async (system, user) => {
      const st = await api.aiStatus();
      if (!st.ready) throw new Error("AI is off");
      return (await call<{ text: string }>("ai_complete", { system, user })).text;
    },
    reveal: (p) => void reveal(p),
    toast,
  };
}
