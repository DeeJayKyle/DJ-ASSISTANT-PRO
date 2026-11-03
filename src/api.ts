// Transport to the local backend. In the desktop app this is Tauri IPC.
// The HTTP bridge is compiled in ONLY for development/e2e builds
// (VITE_DEV_BRIDGE=1) and talks to 127.0.0.1 — release builds never contain it.
import type {
  AssistantReply, Crate, DupGroup, FieldInfo, HashProgress, Health, Root, RuleSet,
  ScanProgress, Settings, Stats, TrackDetail, TrackPage, TrackQuery,
} from "./types";

const BRIDGE = import.meta.env.VITE_DEV_BRIDGE === "1";
const BRIDGE_URL = (import.meta.env.VITE_BRIDGE_URL as string | undefined) ?? "http://127.0.0.1:7878";

export const isDesktop = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export class ApiError extends Error {}

export async function call<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  if (isDesktop()) {
    const { invoke } = await import("@tauri-apps/api/core");
    try {
      return await invoke<T>("api", { cmd, args });
    } catch (e) {
      throw new ApiError(String(e));
    }
  }
  if (BRIDGE) {
    const res = await fetch(BRIDGE_URL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ cmd, args }) });
    const body = await res.json();
    if (body.error) throw new ApiError(body.error);
    return body.ok as T;
  }
  throw new ApiError("The DJ Assistant backend is not available. Please run the desktop app.");
}

/** Native folder picker (desktop only). Returns null if cancelled/unavailable. */
export async function pickFolders(): Promise<string[] | null> {
  if (!isDesktop()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const res = await open({ directory: true, multiple: true, title: "Choose music folders (read-only)" });
  if (res === null) return null;
  return Array.isArray(res) ? res : [res];
}

export const api = {
  appInfo: () => call<{ version: string; db_path: string; read_only_files: boolean; network_features: boolean }>("app_info"),
  stats: () => call<Stats>("stats"),
  listRoots: () => call<Root[]>("list_roots"),
  addRoot: (path: string) => call<Root>("add_root", { path }),
  removeRoot: (id: number) => call<{ removed_tracks: number }>("remove_root", { id }),
  startScan: (root_ids?: number[]) => call("start_scan", { root_ids: root_ids ?? null }),
  scanStatus: () => call<ScanProgress>("scan_status"),
  pauseScan: (paused: boolean) => call("pause_scan", { paused }),
  cancelScan: () => call("cancel_scan"),
  search: (query: TrackQuery) => call<TrackPage>("search", { query }),
  trackDetail: (id: number) => call<TrackDetail>("track_detail", { id }),
  updateUserFields: (ids: number[], patch: Record<string, unknown>) => call<{ updated: number }>("update_user_fields", { ids, patch }),
  setTags: (ids: number[], add: string[], remove: string[] = []) => call("set_tags", { ids, add, remove }),
  listTags: () => call<[string, number][]>("list_tags"),
  facet: (field: string) => call<[string, number][]>("facet", { field }),
  listCrates: () => call<Crate[]>("list_crates"),
  createCrate: (input: Record<string, unknown>) => call<Crate>("create_crate", { input }),
  updateCrate: (id: number, input: Record<string, unknown>) => call<Crate>("update_crate", { id, input }),
  deleteCrate: (id: number) => call("delete_crate", { id }),
  crateAdd: (crate_id: number, ids: number[]) => call<{ added: number }>("crate_add", { crate_id, ids }),
  crateAddQuery: (crate_id: number, query: TrackQuery) => call<{ added: number }>("crate_add_query", { crate_id, query }),
  crateRemove: (crate_id: number, ids: number[]) => call<{ removed: number }>("crate_remove", { crate_id, ids }),
  previewRules: (rules: RuleSet) => call<{ total: number; sample: TrackPage["rows"] }>("preview_rules", { rules }),
  ruleFields: () => call<FieldInfo[]>("rule_fields"),
  startHash: () => call("start_hash"),
  hashStatus: () => call<HashProgress>("hash_status"),
  cancelHash: () => call("cancel_hash"),
  duplicates: () => call<DupGroup[]>("duplicates"),
  setDupDecision: (key: string, decision: string | null) => call("set_dup_decision", { key, decision }),
  health: () => call<Health>("health"),
  getSettings: () => call<Settings>("get_settings"),
  setSetting: (key: string, value: unknown) => call("set_setting", { key, value }),
  assistant: (message: string) => call<AssistantReply>("assistant", { message }),
};
