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
  quality: "lossless" | "lossy" | "low_bitrate" | "unknown";
  status: "ok" | "error" | "unsupported" | "missing" | "offline";
  file_name: string;
  path: string;
  file_size: number;
  tags: string[];
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
}
