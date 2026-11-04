// In-app updates: signed releases from GitHub. Only the app version and
// platform are sent when checking; the DJ can turn automatic checks off.
import { isDesktop } from "../api";

export interface UpdateInfo {
  version: string;
  notes: string | null;
  date: string | null;
  install: (onProgress: (pct: number | null) => void) => Promise<void>;
}

export async function checkForUpdate(): Promise<UpdateInfo | null> {
  if (!isDesktop()) return null;
  const { check } = await import("@tauri-apps/plugin-updater");
  const u = await check();
  if (!u) return null;
  return {
    version: u.version,
    notes: u.body ?? null,
    date: u.date ?? null,
    install: async (onProgress) => {
      let total = 0;
      let got = 0;
      await u.downloadAndInstall((e) => {
        if (e.event === "Started") total = e.data.contentLength ?? 0;
        if (e.event === "Progress") {
          got += e.data.chunkLength;
          onProgress(total ? Math.round((100 * got) / total) : null);
        }
        if (e.event === "Finished") onProgress(100);
      });
      const { relaunch } = await import("@tauri-apps/plugin-process");
      await relaunch();
    },
  };
}
