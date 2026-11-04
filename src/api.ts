// Transport to the local backend. In the desktop app this is Tauri IPC.
// The HTTP bridge is compiled in ONLY for development/e2e builds
// (VITE_DEV_BRIDGE=1) and talks to 127.0.0.1 — release builds never contain it.
import type {
  AiStatus, AiTurn, FixList,
  ChangeLogEntry, CrateGaps, CrateTemplate, DiscoveryItem, DocHit, DocsReport, Gig, GigRecap, JobState, Labels, Overplayed, PackPlan,
  PlannedChange, Preferences, Recommendation, SavedSet, Service, SetParams, SetPlan, Suggestion, TracklistMatch, WatchItem,
  AccountList, PackOptions,
  AssistantReply, Crate, DupGroup, FieldInfo, HashProgress, Health, Root, RuleSet,
  ScanProgress, Settings, Stats, TrackDetail, TrackPage, TrackQuery,
} from "./types";

const BRIDGE = import.meta.env.VITE_DEV_BRIDGE === "1";
const BRIDGE_URL = (import.meta.env.VITE_BRIDGE_URL as string | undefined) ?? "http://127.0.0.1:7878";

export const isDesktop = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export class ApiError extends Error {
  constructor(msg: string) {
    // Backend errors are prefixed with their kind; show people the sentence only.
    super(msg.replace(/^(invalid input|not found|busy|database error|file system error|serialization error): /i, "").replace(/^./, (c) => c.toUpperCase()));
  }
}

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

/** Native single-folder picker. */
export async function pickFolder(title: string): Promise<string | null> {
  if (!isDesktop()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const res = await open({ directory: true, multiple: false, title });
  return typeof res === "string" ? res : null;
}

/** Native file picker. */
export async function pickFile(title: string, extensions: string[]): Promise<string | null> {
  if (!isDesktop()) return null;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const res = await open({ multiple: false, title, filters: [{ name: extensions.join(", ").toUpperCase(), extensions }] });
  return typeof res === "string" ? res : null;
}

/** Native save dialog (asks before overwriting). */
export async function pickSave(title: string, defaultPath: string, extensions: string[]): Promise<string | null> {
  if (!isDesktop()) return null;
  const { save } = await import("@tauri-apps/plugin-dialog");
  return (await save({ title, defaultPath, filters: [{ name: extensions.join(", ").toUpperCase(), extensions }] })) ?? null;
}

/** Open an https link in the default browser. */
export async function openUrl(url: string): Promise<void> {
  if (!/^https:\/\//.test(url)) return;
  if (isDesktop()) {
    const { openUrl } = await import("@tauri-apps/plugin-opener");
    await openUrl(url);
  } else window.open(url, "_blank", "noopener");
}

/** Show a file in Explorer (read-only). */
export async function reveal(path: string): Promise<void> {
  if (!isDesktop()) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("reveal", { path });
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
  healthFixList: (category: string, limit = 100, offset = 0) => call<FixList>("health_fix_list", { category, limit, offset }),
  getSettings: () => call<Settings>("get_settings"),
  setSetting: (key: string, value: unknown) => call("set_setting", { key, value }),
  assistant: (message: string) => call<AssistantReply>("assistant", { message }),

  // ---- v1 ----
  jobs: () => call<JobState[]>("jobs"),
  jobStatus: (kind: string) => call<JobState>("job_status", { kind }),
  cancelJob: (kind: string) => call("cancel_job", { kind }),
  pauseJob: (kind: string, paused: boolean) => call("pause_job", { kind, paused }),
  startAnalysis: (ids?: number[], force = false) => call<{ started: boolean; paused_for_gig: boolean }>("start_analysis", { ids: ids ?? null, force }),
  analysisSummary: () => call<{ analysed: number; errors: number; pending: number; method: string; version: number }>("analysis_summary"),
  generateSuggestions: () => call<{ created: number }>("generate_suggestions"),
  suggestions: (status?: string | null, track_id?: number | null) => call<Suggestion[]>("suggestions", { status: status ?? null, track_id: track_id ?? null }),
  suggestionCounts: () => call<Record<string, number>>("suggestion_counts"),
  acceptSuggestion: (id: number, value?: string | null) => call("accept_suggestion", { id, value: value ?? null }),
  rejectSuggestion: (id: number) => call("reject_suggestion", { id }),
  resetSuggestion: (id: number) => call("reset_suggestion", { id }),
  acceptBulk: (min_confidence: number, source?: string | null) => call<{ accepted: number }>("accept_suggestions_bulk", { min_confidence, source: source ?? null }),
  lookupMusicBrainz: (sel: Selection) => call("lookup_musicbrainz", sel),
  lookupAcoustid: (sel: Selection) => call("lookup_acoustid", { ...sel, confirmed: true }),
  services: () => call<Service[]>("services"),
  setService: (service: string, enabled: boolean) => call("set_service", { service, enabled }),
  aiStatus: () => call<AiStatus>("ai_status"),
  aiChat: (message: string, conversation_id?: string | null) => call<AiTurn>("ai_chat", { message, conversation_id: conversation_id ?? null }),
  aiConfirm: (conversation_id: string, decisions: Record<string, boolean>) => call<AiTurn>("ai_confirm", { conversation_id, decisions }),
  aiReset: (conversation_id: string) => call("ai_reset", { conversation_id }),
  aiLocalModels: () => call<string[]>("ai_local_models"),
  aiLocalSetup: () => call<any>("ai_local_setup"), // eslint-disable-line @typescript-eslint/no-explicit-any
  aiLocalStart: () => call<{ running: boolean }>("ai_local_start"),
  aiLocalPull: (model?: string) => call<{ started: boolean }>("ai_local_pull", { model: model ?? null }),
  setSecret: (service: string, value: string) => call("set_secret", { service, value }),
  deleteSecret: (service: string) => call("delete_secret", { service }),
  crateTemplates: () => call<CrateTemplate[]>("crate_templates"),
  applyTemplate: (id: string, genre?: string | null) => call<{ created: number; skipped: number; parent: string }>("apply_template", { id, genre: genre ?? null }),
  labels: () => call<Labels>("labels"),
  setLabels: (labels: Labels) => call("set_labels", { labels }),
  colourByEnergy: (only_uncoloured: boolean) => call<{ updated: number }>("colour_by_energy", { only_uncoloured }),
  crateHygiene: () => call<{ issues: { crate_id: number; crate: string; issue: string; advice: string }[]; untagged_unrated: number }>("crate_hygiene"),
  moveCrate: (id: number, parent_id: number | null) => call("move_crate", { id, parent_id }),
  exportM3u: (sel: Selection, path: string, overwrite = true) => call<{ written: number }>("export_m3u", { ...sel, path, overwrite }),
  exportCsv: (sel: Selection, path: string, overwrite = true) => call<{ written: number }>("export_csv", { ...sel, path, overwrite }),
  crateFit: (crate_id: number) => call<Recommendation[]>("crate_fit", { crate_id }),
  crateGaps: (crate_id: number) => call<CrateGaps>("crate_gaps", { crate_id }),
  overplayed: () => call<Overplayed[]>("overplayed"),
  matchTracklist: (text: string) => call<TracklistMatch>("match_tracklist", { text }),
  preferences: () => call<Preferences>("preferences"),
  prefFeedback: (kind: string, subject: string, value: number) => call("pref_feedback", { kind, subject, value }),
  resetLearning: () => call<{ removed: number }>("reset_learning"),
  lastfmCrate: (crate_id: number) => call<{ found: number }>("lastfm_crate", { crate_id }),
  lastfmTrack: (track_id: number) => call<{ found: number }>("lastfm_track", { track_id }),
  follow: (name: string) => call("follow", { name, kind: "artist" }),
  unfollow: (id: number) => call("unfollow", { id }),
  followed: () => call<{ id: number; name: string; kind: string; added_at: number }[]>("followed"),
  refreshReleases: () => call("refresh_releases"),
  discoveryItems: (status?: string | null) => call<DiscoveryItem[]>("discovery_items", { status: status ?? null }),
  discoveryStatus: (id: number, status: string) => call("discovery_status", { id, status }),
  storeLinks: (artist: string, title: string) => call<{ store: string; url: string }[]>("store_links", { artist, title }),
  planSet: (params: SetParams) => call<SetPlan>("plan_set", { params }),
  saveSet: (id: number | null, name: string, plan: SetPlan) => call<{ id: number }>("save_set", { id, name, plan }),
  listSets: () => call<SavedSet[]>("list_sets"),
  getSet: (id: number) => call<SetPlan & { id: number; name: string }>("get_set", { id }),
  deleteSet: (id: number) => call("delete_set", { id }),
  reviewSet: (ids: number[]) => call<{ from: number; to: number; score: number; notes: string[] }[]>("review_set", { ids }),
  setToCrate: (id: number, name: string) => call<Crate>("set_to_crate", { id, name }),
  gigCurrent: () => call<Gig | null>("gig_current"),
  gigStart: (name: string, set_plan_id: number | null) => call<{ id: number }>("gig_start", { name, set_plan_id }),
  gigEnd: () => call<{ id: number | null }>("gig_end"),
  gigEvent: (kind: string, track_id: number | null, text: string | null) => call<{ id: number }>("gig_event", { kind, track_id, text }),
  gigRequest: (id: number, status: string, track_id?: number | null) => call("gig_request", { id, status, track_id: track_id ?? null }),
  gigDeleteEvent: (id: number) => call("gig_delete_event", { id }),
  gigs: () => call<{ id: number; name: string; started_at: number; ended_at: number | null; played: number }[]>("gigs"),
  gigRecap: (id: number) => call<GigRecap>("gig_recap", { id }),
  exportRecap: (id: number, path: string) => call("export_recap", { id, path, overwrite: true }),
  gigpackPreview: (sel: Selection, dest: string, name: string, options?: PackOptions) => call<{ token: string; plan: PackPlan }>("gigpack_preview", { ...sel, dest, name, options: options ?? null }),
  gigpackStart: (token: string) => call("gigpack_start", { token }),
  writePreview: (sel: Selection, values: Record<string, string | null>) => call<{ token: string; plan: PlannedChange[] }>("write_preview", { ...sel, values }),
  writeApply: (token: string) => call<{ track_id: number; status: string; message?: string }[]>("write_apply", { token, approved: true }),
  changeLog: () => call<ChangeLogEntry[]>("change_log"),
  rollback: (id: number) => call("rollback_change", { id }),
  seratoImport: (path: string) => call<{ crates: { crate: string; tracks: number; matched: number; unmatched: number }[]; note: string }>("serato_import_crates", { path }),
  historyImport: (args: { path?: string; text?: string; session?: string }) => call<{ matched: number; unmatched: number }>("history_import_csv", args),
  history: () => call<{ id: number; source: string; session: string | null; track_id: number | null; artist: string | null; title: string | null }[]>("history"),
  clearHistory: () => call("clear_history"),
  docsRoots: () => call<{ id: number; path: string; status: string; last_scan_at: number | null; count: number }[]>("docs_roots"),
  docsAddRoot: (path: string) => call("docs_add_root", { path }),
  docsRemoveRoot: (id: number) => call("docs_remove_root", { id }),
  docsScan: () => call("docs_scan"),
  docsSearch: (text: string, ext?: string | null) => call<DocHit[]>("docs_search", { text, ext: ext ?? null }),
  docsReport: () => call<DocsReport>("docs_report"),
  docsClear: () => call("docs_clear"),
  watchStatus: () => call<{ enabled: boolean; active: boolean; roots: string[]; pending: WatchItem[] }>("watch_status"),
  watchClear: () => call("watch_clear", { root_id: null }),

  // ---- local accounts (no sign-in) ----
  accounts: () => call<AccountList>("accounts"),
  accountCreate: (name: string) => call<AccountList>("account_create", { name }),
  accountSwitch: (id: string) => call<AccountList>("account_switch", { id }),
  accountRename: (id: string, name: string) => call<AccountList>("account_rename", { id, name }),
  accountDelete: (id: string) => call<AccountList & { kept_backups: string | null }>("account_delete", { id }),

  // ---- Quick Prep: AI help (uses the assistant's model) ----
  aiTidy: (tracks: { id: number; current: Record<string, string> }[], genres: string[]) => call<{ id: number; artist: string; title: string; mix: string; genre: string | null }[]>("ai_tidy", { tracks, genres }),
  aiOrder: (request: string, ids: number[]) => call<{ order: number[]; note: string }>("ai_order", { request, ids }),
};

/** A URL the audio player can stream a catalogued track from (read-only, by id). */
export function trackUrl(id: number): string {
  // The bridge branch is compiled in only for development/e2e builds.
  if (BRIDGE && !isDesktop()) return `${BRIDGE_URL}/track/${id}`;
  return navigator.userAgent.includes("Windows") ? `http://track.localhost/${id}` : `track://localhost/${id}`;
}

export type Selection = { ids?: number[]; crate_id?: number; set_id?: number; query?: TrackQuery };
