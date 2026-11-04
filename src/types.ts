export type MatchMode = "all" | "any";
export type RuleNode =
  | { kind: "condition"; field: string; op: string; value?: unknown }
  | { kind: "group"; match: MatchMode; rules: RuleNode[] };
export interface RuleSet {
  match: MatchMode;
  rules: RuleNode[];
  exclude?: RuleNode[];
}

export interface TrackRow {
  id: number;
  uid: string;
  title: string | null;
  artist: string | null;
  album: string | null;
  genre: string | null;
  year: number | null;
  bpm: number | null;
  key: string | null;
  energy: number | null;
  rating: number | null;
  mood: string | null;
  color: string | null;
  version: string | null;
  clean_explicit: string | null;
  duration_ms: number | null;
  bitrate_kbps: number | null;
  format: string | null;
  lossless: boolean | null;
  quality: "lossless" | "lossy" | "low_bitrate" | "unknown" | "video";
  status: "ok" | "error" | "unsupported" | "missing" | "offline";
  file_name: string;
  path: string;
  file_size: number;
  tags: string[];
  bpm_source: "you" | "tag" | "analysis" | null;
  key_source: "you" | "tag" | "analysis" | null;
  energy_source: "you" | "analysis" | null;
  analysis: "ok" | "error" | null;
  original_year: number | null;
  media_kind: "audio" | "video";
  video_codec: string | null;
  width: number | null;
  height: number | null;
  frame_rate: number | null;
}

export interface TrackPage {
  total: number;
  offset: number;
  rows: TrackRow[];
}

export interface TrackQuery {
  text?: string | null;
  filters?: RuleSet | null;
  crate_id?: number | null;
  root_id?: number | null;
  include_missing?: boolean;
  sort?: string | null;
  desc?: boolean;
  offset?: number;
  limit?: number;
}

export interface TrackDetail {
  row: TrackRow;
  file: Record<string, unknown>;
  mine: Record<string, unknown>;
  technical: Record<string, unknown>;
  crates: [number, string][];
  read_error: string | null;
  analysis: AnalysisInfo | null;
  plays: number;
}

export interface AnalysisInfo {
  method: string;
  version: number;
  analysed_at: number;
  status: "ok" | "error";
  error: string | null;
  bpm: number | null;
  bpm_confidence: number | null;
  bpm_alt: number | null;
  key: string | null;
  camelot: string | null;
  key_confidence: number | null;
  energy: number | null;
  loudness_lufs: number | null;
  peak_dbfs: number | null;
  clipped_runs: number | null;
  silence_start_ms: number | null;
  silence_end_ms: number | null;
  intro_end_ms: number | null;
  outro_start_ms: number | null;
  tempo_stable: boolean | null;
  cues: { ms: number; label: string }[];
  warnings: string[];
  waveform: number[];
  duration_ms: number | null;
  has_fingerprint: boolean;
}

export interface Root {
  id: number;
  path: string;
  label: string | null;
  status: "online" | "offline" | "unknown";
  added_at: number;
  last_scan_at: number | null;
  last_scan_status: string | null;
  track_count: number;
}

export interface Crate {
  id: number;
  name: string;
  kind: "manual" | "smart";
  color: string | null;
  category: string | null;
  parent_id: number | null;
  sort_order: number;
  rules: RuleSet | null;
  track_count: number;
}

export interface ScanProgress {
  state: "idle" | "running" | "paused" | "completed" | "cancelled" | "failed";
  scan_id: number | null;
  phase: string;
  current_root: string | null;
  files_found: number;
  files_to_read: number;
  files_processed: number;
  added: number;
  updated: number;
  unchanged: number;
  missing: number;
  errors: number;
  offline_roots: number;
  message: string | null;
}

export interface HashProgress {
  state: string;
  candidates: number;
  hashed: number;
  errors: number;
}

export interface DupGroup {
  kind: "exact" | "possible" | "alternate";
  key: string;
  reason: string;
  decision: string | null;
  tracks: TrackRow[];
}

export interface HealthItem {
  id: string;
  label: string;
  explanation: string;
  count: number;
  filters: RuleSet;
  include_missing: boolean;
  fix_fields: string[];
}

export interface FixHint {
  field: string;
  value: string;
  source: string;
  evidence: string;
  suggestion_id: number | null;
}

export interface FixRow {
  track: TrackRow;
  folder: string;
  hints: FixHint[];
}

export interface FixList {
  category: string;
  label: string;
  fields: string[];
  total: number;
  rows: FixRow[];
}

export interface Health {
  items: HealthItem[];
  last_scan: null | {
    id: number;
    started_at: number;
    finished_at: number | null;
    status: string;
    files_seen: number;
    added: number;
    updated: number;
    unchanged: number;
    missing: number;
    errors: number;
    message: string | null;
  };
  recent_errors: { path: string; kind: string; message: string; at: number }[];
  low_bitrate_threshold_kbps: number;
}

export interface Stats {
  tracks: number;
  missing: number;
  offline: number;
  errors: number;
  unsupported: number;
  low_bitrate: number;
  lossless: number;
  total_bytes: number;
  total_duration_ms: number;
  roots: number;
  crates: number;
}

export interface Settings {
  low_bitrate_kbps: number;
  theme: "dark" | "light";
  chat_open: boolean;
  privacy_acknowledged: boolean;
  allow_file_changes: boolean;
  docs_enabled: boolean;
  watch_enabled: boolean;
  learning_enabled: boolean;
  gig_mode: boolean;
  auto_update: boolean;
  surface: "glass" | "solid";
  motion: "full" | "reduced";
  key_notation: "camelot" | "musical";
  scan_video: boolean;
  premium_ui: boolean;
}

export interface FieldInfo {
  id: string;
  label: string;
  type: "text" | "number" | "enum" | "tag" | "bool";
}

export interface AssistantReply {
  reply: string;
  understood: string[];
  action: "search" | "navigate" | "help";
  target: string | null;
  text: string | null;
  filters: RuleSet | null;
  total: number | null;
  sample: TrackRow[];
  params?: Partial<SetParams>;
}

export interface JobState {
  kind: string;
  state: "idle" | "running" | "paused" | "completed" | "cancelled" | "failed";
  done: number;
  total: number;
  errors: number;
  message: string | null;
  started_at: number | null;
  finished_at: number | null;
  result: unknown;
}

export interface Suggestion {
  id: number;
  track_id: number;
  track: string;
  field: string;
  current_value: string | null;
  suggested_value: string;
  source: string;
  evidence: string | null;
  confidence: number | null;
  status: "pending" | "accepted" | "rejected";
  created_at: number;
}

export interface Service {
  id: string;
  name: string;
  provides: string;
  sends: string;
  enabled: boolean;
  needs_key: boolean;
  has_key: boolean;
}

export interface CrateTemplate {
  id: string;
  name: string;
  description: string;
  crates: string[];
  needs_genre: boolean;
}

export interface Labels {
  energy: { min: number; max: number; label: string; hint: string }[];
  rating: Record<string, string>;
  rating_hint: Record<string, string>;
  color: Record<string, string>;
  tag_presets: string[];
}

export interface Recommendation {
  track_id: number;
  track: string;
  score: number;
  reasons: string[];
  source: string;
}

export interface CrateGaps {
  artists: { artist: string; in_crate: number; in_library: number; reason: string }[];
  decades: { decade: number; library: number; crate: number }[];
  missing_energy: number;
  missing_bpm: number;
  size: number;
}

export interface Overplayed {
  track_id: number;
  track: string;
  plays: number;
  alternatives: { track_id: number; track: string; plays: number; score: number }[];
}

export interface TracklistLine {
  line: number;
  text: string;
  artist?: string;
  title?: string;
  status: "owned" | "possibly_owned" | "missing" | "unknown";
  track_id?: number;
  match?: string;
  note?: string;
}

export interface TracklistMatch {
  lines: TracklistLine[];
  owned: number;
  possibly_owned: number;
  missing: number;
  unknown: number;
  note: string;
}

export interface Preferences {
  enabled: boolean;
  explanation: string;
  genres: { name: string; weight: number; tracks: number }[];
  artists: { name: string; weight: number; tracks: number }[];
  feedback: { kind: string; subject: string; value: number; at: number }[];
}

export interface DiscoveryItem {
  id: number;
  source: string;
  kind: string;
  artist: string | null;
  title: string | null;
  detail: string | null;
  reason: string | null;
  url: string | null;
  released: string | null;
  fetched_at: number;
  owned_track_id: number | null;
  ownership: "owned" | "possibly_owned" | "missing";
  status: "new" | "wishlist" | "dismissed";
}

export interface SetParams {
  name?: string | null;
  event_type?: string | null;
  audience?: string | null;
  duration_min: number;
  genres: string[];
  must_play: number[];
  exclude: number[];
  exclude_tags: string[];
  clean_only: boolean;
  curve: string;
  custom_curve?: number[];
  bpm_min?: number | null;
  bpm_max?: number | null;
  crate_id?: number | null;
  harmonic?: boolean;
  min_track_seconds?: number;
}

export interface SetSlot {
  track_id: number;
  track: string;
  start_ms: number;
  target_energy: number;
  energy: number | null;
  bpm: number | null;
  key: string | null;
  must_play: boolean;
  reasons: string[];
  transition: string[];
  alternatives: { track_id: number; track: string; energy: number | null; bpm: number | null; key: string | null; score: number; reasons: string[] }[];
}

export interface SetPlan {
  params?: SetParams;
  curve: number[];
  slots: SetSlot[];
  emergency: { track_id: number; track: string; rating: number | null; energy: number | null; bpm: number | null }[];
  warnings?: string[];
  planned_ms?: number;
  note?: string;
}

export interface SavedSet {
  id: number;
  name: string;
  params: SetParams;
  count: number;
  created_at: number;
  updated_at: number;
}

export interface GigEvent {
  id: number;
  kind: "played" | "request" | "note";
  track_id: number | null;
  text: string | null;
  status: string | null;
  at: number;
  track: string | null;
}

export interface Gig {
  id: number;
  name: string;
  set_plan_id: number | null;
  started_at: number;
  events: GigEvent[];
}

export interface GigRecap {
  id: number;
  name: string;
  started_at: number;
  ended_at: number | null;
  duration_ms: number;
  played: GigEvent[];
  played_count: number;
  genres: { genre: string; count: number }[];
  energy: { at: number; energy: number | null }[];
  requests: GigEvent[];
  requests_total: number;
  requests_fulfilled: number;
  notes: GigEvent[];
}

export interface PackFile {
  n: number;
  track_id: number;
  artist: string | null;
  title: string | null;
  source: string;
  dest_name: string;
  size: number;
  available: boolean;
  problem: string | null;
}

export interface PackPlan {
  pack_dir: string;
  files: PackFile[];
  total_bytes: number;
  free_bytes: number | null;
  fits: boolean;
  missing: number;
  warnings: string[];
}

export interface PlannedChange {
  track_id: number;
  path: string;
  format: string;
  changes: Record<string, [string | null, string | null]>;
  warnings: string[];
  blocked: string | null;
}

export interface ChangeLogEntry {
  id: number;
  track_id: number | null;
  path: string;
  action: "tag_write" | "rollback";
  changes: Record<string, [string | null, string | null]> | { rolled_back_change: number };
  backup_path: string | null;
  status: "done" | "failed" | "rolled_back";
  error: string | null;
  at: number;
}

export interface DocHit {
  id: number;
  path: string;
  name: string;
  folder: string;
  ext: string;
  size: number;
  mtime: number | null;
  content_status: string;
  snippet: string | null;
}

export interface DocsReport {
  statuses: { status: string; count: number }[];
  duplicates: { paths: string[]; size: number }[];
  types: { ext: string; count: number; bytes: number }[];
  flagged: { path: string; status: string }[];
  suggestions: { folder: string; count: number; examples: string[]; note: string }[];
}

export interface WatchItem {
  id: number;
  path: string;
  kind: string;
  at: number;
  artist: string | null;
  title: string | null;
  genre: string | null;
  suggested_folder: string | null;
  note: string;
}
