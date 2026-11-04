//! The AI assistant: a language model that knows the app (docs/ASSISTANT_GUIDE.md
//! is its built-in knowledge) and works through the app's own commands.
//!
//! Every tool maps onto an existing `App::dispatch` command and has a tier:
//! * `Read`  — looks things up; runs automatically.
//! * `Ui`    — changes only what is on screen (navigate, filter the library);
//!   runs automatically and is applied by the front end.
//! * `Act`   — changes the catalogue or starts work. Never runs on the model's
//!   say-so: it is shown to the DJ as an action card and runs only after they
//!   press Run.
//!
//! No tool can write, move, rename or delete music files, or touch Serato data.
//! Tool results sent to the model never include file paths.
//!
//! The conversation is kept in the Anthropic Messages format (also when a local
//! model is used — the online crate converts), and assistant turns are stored
//! exactly as returned so thinking blocks are passed back unchanged.
use crate::api::App;
use crate::db;
use crate::error::{invalid, Error, Result};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;

pub const GUIDE: &str = include_str!("../../../docs/ASSISTANT_GUIDE.md");
const MAX_STEPS: usize = 10;
const MAX_RESULT_CHARS: usize = 24_000;

/// Which model to use and how to reach it.
#[derive(Debug, Clone, Serialize)]
pub struct LlmConfig {
    /// "claude" or "local".
    pub provider: String,
    pub model: String,
    #[serde(skip)]
    pub api_key: Option<String>,
    /// Base URL of the local model server (Ollama).
    pub local_url: String,
}

pub const CLAUDE_MODELS: &[(&str, &str)] = &[
    (
        "claude-opus-5-5",
        "Claude Opus 5.5 — most capable (default)",
    ),
    (
        "claude-sonnet-5-5",
        "Claude Sonnet 5.5 — fast and capable, lower cost",
    ),
    (
        "claude-haiku-5-5",
        "Claude Haiku 5.5 — fastest, lowest cost",
    ),
];
pub const DEFAULT_LOCAL_MODEL: &str = "qwen2.5:7b";
pub const DEFAULT_LOCAL_URL: &str = "http://127.0.0.1:11434";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Read,
    Ui,
    Act,
}

struct ToolDef {
    name: &'static str,
    tier: Tier,
    description: &'static str,
    schema: fn() -> Value,
}

fn rules_schema() -> Value {
    json!({"type": "object", "description": "A rule set: {\"match\": \"all\"|\"any\", \"rules\": [{\"kind\": \"condition\", \"field\", \"op\", \"value\"} | {\"kind\": \"group\", \"match\", \"rules\"}]}. See list_rule_fields.",
        "properties": {"match": {"type": "string", "enum": ["all", "any"]}, "rules": {"type": "array", "items": {"type": "object"}}},
        "required": ["match", "rules"]})
}
fn ids_schema(desc: &str) -> Value {
    json!({"type": "array", "items": {"type": "integer"}, "description": desc})
}

const TOOLS: &[ToolDef] = &[
    ToolDef { name: "library_overview", tier: Tier::Read, description: "Counts for the whole library (tracks, videos, lossless, low bitrate, missing, offline, errors, folders, total duration) plus the top genres and decades.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "search_tracks", tier: Tier::Read, description: "Find tracks in the catalogue by free text and/or a rule set. Returns the total and up to `limit` compact rows (id, artist, title, genre, year, bpm, key, energy, rating, version, quality, format, media, duration). Use the ids in other tools.", schema: || json!({"type": "object", "properties": {
        "text": {"type": "string", "description": "Free text matched against title, artist, album, genre, label, file name and tags (accent-insensitive)."},
        "filters": rules_schema(),
        "sort": {"type": "string", "enum": ["title", "artist", "album", "genre", "year", "bpm", "key", "energy", "rating", "duration", "added", "plays"]},
        "desc": {"type": "boolean"},
        "limit": {"type": "integer", "minimum": 1, "maximum": 100}}}) },
    ToolDef { name: "get_track", tier: Tier::Read, description: "Full details for one track: catalogue values, original file tags, analysis (BPM, key, energy, loudness, intro/outro, cue ideas), crates it is in and play count.", schema: || json!({"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}) },
    ToolDef { name: "list_rule_fields", tier: Tier::Read, description: "Every field usable in filters and smart crates, with its type.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "facet_values", tier: Tier::Read, description: "Distinct values with counts for a field, to see what genres, keys, formats, moods, labels, decades or versions exist.", schema: || json!({"type": "object", "properties": {"field": {"type": "string", "enum": ["genre", "artist", "format", "key", "mood", "label", "decade", "version"]}}, "required": ["field"]}) },
    ToolDef { name: "list_crates", tier: Tier::Read, description: "All crates (id, name, kind manual/smart, parent folder, colour, track count, rules).", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "crate_tracks", tier: Tier::Read, description: "Tracks in one crate (compact rows).", schema: || json!({"type": "object", "properties": {"crate_id": {"type": "integer"}, "limit": {"type": "integer", "minimum": 1, "maximum": 200}}, "required": ["crate_id"]}) },
    ToolDef { name: "crate_templates", tier: Tier::Read, description: "Crate templates from the Crate & Playlist Cheat Sheet (id, name, what crates they create).", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "library_health", tier: Tier::Read, description: "Library Health cards with counts (missing metadata, low bitrate, unreadable, unsupported, offline, missing files) and the last scan.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "duplicates_summary", tier: Tier::Read, description: "Duplicate groups (exact / possible / alternate versions) with their tracks and reasons. Exact groups need a full-file hash run first.", schema: || json!({"type": "object", "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 50}}}) },
    ToolDef { name: "suggestions_summary", tier: Tier::Read, description: "Pending metadata suggestions (field, current value, suggested value, source, confidence).", schema: || json!({"type": "object", "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 100}}}) },
    ToolDef { name: "jobs_status", tier: Tier::Read, description: "Scan, analysis and other background jobs with progress, plus analysis coverage.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "crate_fit", tier: Tier::Read, description: "Library tracks that would fit a crate but are not in it, with reasons.", schema: || json!({"type": "object", "properties": {"crate_id": {"type": "integer"}}, "required": ["crate_id"]}) },
    ToolDef { name: "list_sets", tier: Tier::Read, description: "Saved sets from Set Studio.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "preview_set", tier: Tier::Read, description: "Build a set plan without saving it: running order with transition notes. Use it to discuss options; open_view set-studio with params to let the DJ edit it, or save_set to keep it.", schema: set_params_schema },
    ToolDef { name: "gig_status", tier: Tier::Read, description: "The current gig (if gig mode is on): set list position, requests, notes.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "get_settings", tier: Tier::Read, description: "Current app settings (theme, key notation, premium UI, video scanning, low-bitrate threshold, online services, gig mode…).", schema: || json!({"type": "object", "properties": {}}) },

    ToolDef { name: "show_tracks", tier: Tier::Ui, description: "Show tracks in the Library view with these filters/text applied (the DJ sees them immediately and can edit the filters).", schema: || json!({"type": "object", "properties": {"text": {"type": "string"}, "filters": rules_schema(), "label": {"type": "string", "description": "Short description of what is shown."}}}) },
    ToolDef { name: "open_view", tier: Tier::Ui, description: "Open a screen in the app. For set-studio you can pre-fill set parameters; for crate you need crate_id; for health-fix you need category (missing_core, missing_genre, missing_year, missing_album, missing_bpm, missing_key).", schema: || json!({"type": "object", "properties": {
        "view": {"type": "string", "enum": ["library", "crates", "crate", "duplicates", "activity", "health", "health-fix", "set-studio", "discovery", "suggestions", "gig", "gig-pack", "settings"]},
        "crate_id": {"type": "integer"}, "category": {"type": "string"}, "set_params": {"type": "object"}}, "required": ["view"]}) },

    ToolDef { name: "create_crate", tier: Tier::Act, description: "Create a crate. kind 'smart' needs rules (it updates itself); kind 'manual' can be filled with track_ids. Optional parent_id puts it in a folder crate; color is one of red, orange, yellow, green, teal, blue, purple, pink, grey.", schema: || json!({"type": "object", "properties": {
        "name": {"type": "string"}, "kind": {"type": "string", "enum": ["manual", "smart", "folder"]}, "rules": rules_schema(),
        "track_ids": ids_schema("For manual crates: tracks to add."), "parent_id": {"type": "integer"}, "color": {"type": "string"}}, "required": ["name", "kind"]}) },
    ToolDef { name: "add_to_crate", tier: Tier::Act, description: "Add tracks to an existing manual crate (by ids, or every track matching filters).", schema: || json!({"type": "object", "properties": {"crate_id": {"type": "integer"}, "track_ids": ids_schema("Tracks to add."), "filters": rules_schema()}, "required": ["crate_id"]}) },
    ToolDef { name: "remove_from_crate", tier: Tier::Act, description: "Remove tracks from a crate (files are untouched).", schema: || json!({"type": "object", "properties": {"crate_id": {"type": "integer"}, "track_ids": ids_schema("Tracks to remove.")}, "required": ["crate_id", "track_ids"]}) },
    ToolDef { name: "apply_crate_template", tier: Tier::Act, description: "Create the crates of a cheat-sheet template (see crate_templates). Some templates need a genre.", schema: || json!({"type": "object", "properties": {"template_id": {"type": "string"}, "genre": {"type": "string"}}, "required": ["template_id"]}) },
    ToolDef { name: "update_tracks", tier: Tier::Act, description: "Set catalogue values on tracks (DJ Assistant only — never written to the files). Use null to clear a value. energy 1–10, rating 0–5, key in Camelot or musical notation, color one of the crate colours, clean_explicit 'clean'|'explicit'.", schema: || json!({"type": "object", "properties": {
        "track_ids": ids_schema("Tracks to change."),
        "values": {"type": "object", "properties": {"title": {}, "artist": {}, "album": {}, "genre": {}, "year": {}, "original_year": {}, "record_label": {}, "bpm": {}, "key": {}, "energy": {}, "rating": {}, "mood": {}, "color": {}, "notes": {}, "version_label": {}, "clean_explicit": {}}}},
        "required": ["track_ids", "values"]}) },
    ToolDef { name: "tag_tracks", tier: Tier::Act, description: "Add and/or remove catalogue tags (e.g. 'opener', 'sing-along') on tracks.", schema: || json!({"type": "object", "properties": {"track_ids": ids_schema("Tracks to tag."), "add": {"type": "array", "items": {"type": "string"}}, "remove": {"type": "array", "items": {"type": "string"}}}, "required": ["track_ids"]}) },
    ToolDef { name: "start_scan", tier: Tier::Act, description: "Scan all music folders for new and changed files (read-only).", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "start_analysis", tier: Tier::Act, description: "Analyse audio in the background (BPM, key, energy, loudness, intro/outro, cue ideas) for the given tracks, or for every track not analysed yet.", schema: || json!({"type": "object", "properties": {"track_ids": ids_schema("Optional: only these tracks."), "redo": {"type": "boolean", "description": "Re-analyse tracks that already have results."}}}) },
    ToolDef { name: "find_local_suggestions", tier: Tier::Act, description: "Generate metadata suggestions from file names, folder names and consistent spellings (they still need the DJ's review).", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "save_set", tier: Tier::Act, description: "Plan and save a set in Set Studio with these parameters.", schema: set_params_schema },
    ToolDef { name: "start_gig_mode", tier: Tier::Act, description: "Start gig mode (pauses background work), optionally with a saved set.", schema: || json!({"type": "object", "properties": {"name": {"type": "string"}, "set_id": {"type": "integer"}}}) },
    ToolDef { name: "end_gig_mode", tier: Tier::Act, description: "End the current gig and produce the recap.", schema: || json!({"type": "object", "properties": {}}) },
    ToolDef { name: "change_setting", tier: Tier::Act, description: "Change an app preference: theme (dark|light), key_notation (camelot|musical), premium_ui (true|false), motion (full|reduced), surface (glass|solid), scan_video (true|false), low_bitrate_kbps (number).", schema: || json!({"type": "object", "properties": {"setting": {"type": "string", "enum": ["theme", "key_notation", "premium_ui", "motion", "surface", "scan_video", "low_bitrate_kbps"]}, "value": {}}, "required": ["setting", "value"]}) },
];

fn set_params_schema() -> Value {
    json!({"type": "object", "properties": {
        "name": {"type": "string"},
        "duration_min": {"type": "integer", "minimum": 5, "maximum": 720},
        "event_type": {"type": "string", "description": "e.g. wedding, club, corporate, birthday, lounge"},
        "audience": {"type": "string"},
        "genres": {"type": "array", "items": {"type": "string"}},
        "curve": {"type": "string", "enum": ["journey", "warmup", "peak", "wedding", "lounge", "custom"]},
        "custom_curve": {"type": "array", "items": {"type": "number"}, "description": "Energy points 1–10 for a custom curve."},
        "clean_only": {"type": "boolean"},
        "bpm_min": {"type": "number"}, "bpm_max": {"type": "number"},
        "must_play": ids_schema("Track ids that must be in the set."),
        "exclude": ids_schema("Track ids to leave out.")},
        "required": ["duration_min"]})
}

fn find_tool(name: &str) -> Option<&'static ToolDef> {
    TOOLS.iter().find(|t| t.name == name)
}

pub fn tier_of(name: &str) -> Option<Tier> {
    find_tool(name).map(|t| t.tier)
}

/// Tool definitions in the Messages API format (stable order, so the prompt cache holds).
pub fn tool_specs() -> Vec<Value> {
    TOOLS
        .iter()
        .map(|t| {
            let mut s = (t.schema)();
            if let Some(o) = s.as_object_mut() {
                o.entry("properties").or_insert_with(|| json!({}));
            }
            let desc = match t.tier {
                Tier::Act => format!(
                    "{} [Needs the DJ's approval: shown as an action card.]",
                    t.description
                ),
                _ => t.description.to_string(),
            };
            json!({"name": t.name, "description": desc, "input_schema": s})
        })
        .collect()
}

// ------------------------------------------------------------------ helpers

fn compact_row(r: &Value) -> Value {
    let mut o = Map::new();
    for k in [
        "id",
        "artist",
        "title",
        "album",
        "genre",
        "year",
        "bpm",
        "key",
        "energy",
        "rating",
        "version",
        "clean_explicit",
        "quality",
        "format",
        "media_kind",
        "height",
        "tags",
        "status",
    ] {
        if let Some(v) = r.get(k).filter(|v| !v.is_null()) {
            if k == "tags" && v.as_array().map(|a| a.is_empty()).unwrap_or(true) {
                continue;
            }
            if k == "media_kind" && v == "audio" {
                continue;
            }
            if k == "status" && v == "ok" {
                continue;
            }
            o.insert(k.into(), v.clone());
        }
    }
    if let Some(ms) = r.get("duration_ms").and_then(|v| v.as_i64()) {
        o.insert(
            "duration".into(),
            json!(format!("{}:{:02}", ms / 60000, (ms / 1000) % 60)),
        );
    }
    if o.get("title").is_none() {
        if let Some(f) = r.get("file_name") {
            o.insert("file_name".into(), f.clone());
        }
    }
    Value::Object(o)
}

/// Remove anything that looks like a filesystem path before it reaches the model.
fn strip_paths(v: &mut Value) {
    match v {
        Value::Object(m) => {
            m.retain(|k, _| {
                !matches!(
                    k.as_str(),
                    "path"
                        | "rel_path"
                        | "root"
                        | "root_path"
                        | "db_path"
                        | "folder"
                        | "dest"
                        | "source_path"
                        | "backup_path"
                )
            });
            for (_, x) in m.iter_mut() {
                strip_paths(x);
            }
        }
        Value::Array(a) => a.iter_mut().for_each(strip_paths),
        Value::String(s) if looks_like_path(s) => *s = "[path hidden]".into(),
        _ => {}
    }
}

/// Windows ("C:\\Music\\…", "\\\\server\\…") or Unix-style absolute paths.
fn looks_like_path(s: &str) -> bool {
    let b = s.as_bytes();
    (b.len() > 3 && b[1] == b':' && (b[2] == b'\\' || b[2] == b'/'))
        || s.starts_with("\\\\")
        || (s.starts_with('/') && s.matches('/').count() > 2)
}

fn get<'a>(v: &'a Value, k: &str) -> Option<&'a Value> {
    v.get(k).filter(|x| !x.is_null())
}

fn ids(v: &Value, k: &str) -> Vec<i64> {
    get(v, k)
        .and_then(|a| a.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_i64()).collect())
        .unwrap_or_default()
}

fn set_params(input: &Value) -> Value {
    let mut p = input.clone();
    if let Some(o) = p.as_object_mut() {
        o.retain(|_, v| !v.is_null());
    }
    p
}

/// A one-line, human description of an Act tool call for the action card.
pub fn describe(app: &App, name: &str, input: &Value) -> String {
    let n = |k: &str| ids(input, k).len();
    let s = |k: &str| {
        get(input, k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let crate_name = |id: Option<i64>| -> String {
        id.and_then(|id| {
            app.dispatch("list_crates", json!({})).ok().and_then(|l| {
                l.as_array()?
                    .iter()
                    .find(|c| c["id"] == id)
                    .and_then(|c| c["name"].as_str().map(|x| x.to_string()))
            })
        })
        .map(|x| format!("“{x}”"))
        .unwrap_or_else(|| "the crate".into())
    };
    match name {
        "create_crate" => {
            let kind = s("kind");
            let extra = if kind == "smart" {
                let total = get(input, "rules")
                    .and_then(|r| {
                        app.dispatch("search", json!({"query": {"filters": r, "limit": 1}}))
                            .ok()
                    })
                    .and_then(|p| p["total"].as_i64());
                total
                    .map(|t| format!(" — {t} track{} match now", if t == 1 { "" } else { "s" }))
                    .unwrap_or_default()
            } else if n("track_ids") > 0 {
                format!(
                    " with {} track{}",
                    n("track_ids"),
                    if n("track_ids") == 1 { "" } else { "s" }
                )
            } else {
                String::new()
            };
            format!("Create {kind} crate “{}”{extra}", s("name"))
        }
        "add_to_crate" => {
            let what = if n("track_ids") > 0 {
                format!(
                    "{} track{}",
                    n("track_ids"),
                    if n("track_ids") == 1 { "" } else { "s" }
                )
            } else {
                "the matching tracks".into()
            };
            format!(
                "Add {what} to {}",
                crate_name(get(input, "crate_id").and_then(|v| v.as_i64()))
            )
        }
        "remove_from_crate" => format!(
            "Remove {} track(s) from {} (files untouched)",
            n("track_ids"),
            crate_name(get(input, "crate_id").and_then(|v| v.as_i64()))
        ),
        "apply_crate_template" => format!(
            "Create the crates of template “{}”{}",
            s("template_id"),
            if s("genre").is_empty() {
                String::new()
            } else {
                format!(" for {}", s("genre"))
            }
        ),
        "update_tracks" => {
            let vals = get(input, "values")
                .and_then(|v| v.as_object())
                .map(|o| {
                    o.iter()
                        .map(|(k, v)| {
                            format!(
                                "{k} → {}",
                                if v.is_null() {
                                    "cleared".into()
                                } else {
                                    v.to_string().trim_matches('"').to_string()
                                }
                            )
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            format!(
                "Set {vals} on {} track{} (catalogue only)",
                n("track_ids"),
                if n("track_ids") == 1 { "" } else { "s" }
            )
        }
        "tag_tracks" => {
            let add = get(input, "add").map(|v| v.to_string()).unwrap_or_default();
            let rem = get(input, "remove")
                .map(|v| v.to_string())
                .unwrap_or_default();
            format!(
                "Tags on {} track(s): {}{}",
                n("track_ids"),
                if add.is_empty() {
                    String::new()
                } else {
                    format!("add {add} ")
                },
                if rem.is_empty() {
                    String::new()
                } else {
                    format!("remove {rem}")
                }
            )
        }
        "start_scan" => "Scan your music folders (read-only)".into(),
        "start_analysis" => {
            if n("track_ids") > 0 {
                format!("Analyse {} track(s) in the background", n("track_ids"))
            } else {
                "Analyse all tracks that aren't analysed yet".into()
            }
        }
        "find_local_suggestions" => "Look for metadata suggestions in file and folder names".into(),
        "save_set" => format!(
            "Plan and save a {}-minute set{}",
            get(input, "duration_min")
                .and_then(|v| v.as_i64())
                .unwrap_or(60),
            if s("name").is_empty() {
                String::new()
            } else {
                format!(" “{}”", s("name"))
            }
        ),
        "start_gig_mode" => format!(
            "Start gig mode{} (background work pauses)",
            if s("name").is_empty() {
                String::new()
            } else {
                format!(" “{}”", s("name"))
            }
        ),
        "end_gig_mode" => "End the gig and make the recap".into(),
        "change_setting" => format!(
            "Change {} to {}",
            s("setting"),
            get(input, "value")
                .map(|v| v.to_string().trim_matches('"').to_string())
                .unwrap_or_default()
        ),
        other => other.replace('_', " "),
    }
}

/// Run one tool. Ui tools return a confirmation; the front end applies them.
pub fn run_tool(app: &App, name: &str, input: &Value) -> Result<Value> {
    let lim = |d: i64, max: i64| {
        get(input, "limit")
            .and_then(|v| v.as_i64())
            .unwrap_or(d)
            .clamp(1, max)
    };
    let out = match name {
        "library_overview" => {
            let st = app.dispatch("stats", json!({}))?;
            let videos = app.dispatch("search", json!({"query": {"filters": {"match": "all", "rules": [{"kind": "condition", "field": "media", "op": "equals", "value": "video"}]}, "limit": 1}}))?["total"].clone();
            let genres: Vec<Value> = app.dispatch("facet", json!({"field": "genre"}))?.as_array().cloned().unwrap_or_default().into_iter().take(15).collect();
            let decades: Vec<Value> = app.dispatch("facet", json!({"field": "decade"}))?.as_array().cloned().unwrap_or_default().into_iter().take(10).collect();
            let crates = app.dispatch("list_crates", json!({}))?.as_array().map(|a| a.len()).unwrap_or(0);
            json!({"stats": st, "videos": videos, "crates": crates, "top_genres": genres, "decades": decades})
        }
        "search_tracks" => {
            let page = app.dispatch("search", json!({"query": {"text": get(input, "text"), "filters": get(input, "filters"), "sort": get(input, "sort"), "desc": get(input, "desc").and_then(|v| v.as_bool()).unwrap_or(false), "limit": lim(25, 100)}}))?;
            let rows: Vec<Value> = page["rows"].as_array().map(|a| a.iter().map(compact_row).collect()).unwrap_or_default();
            json!({"total": page["total"], "shown": rows.len(), "tracks": rows})
        }
        "get_track" => {
            let mut d = app.dispatch("track_detail", json!({"id": get(input, "id").cloned().unwrap_or(Value::Null)}))?;
            if let Some(o) = d.as_object_mut() {
                o.remove("technical");
                if let Some(r) = o.get("row").cloned() {
                    o.insert("row".into(), compact_row(&r));
                }
                if let Some(a) = o.get_mut("analysis").and_then(|a| a.as_object_mut()) {
                    a.remove("waveform");
                    a.remove("fingerprint");
                }
            }
            d
        }
        "list_rule_fields" => app.dispatch("rule_fields", json!({}))?,
        "facet_values" => app.dispatch("facet", json!({"field": get(input, "field").cloned().unwrap_or(json!("genre"))}))?,
        "list_crates" => app.dispatch("list_crates", json!({}))?,
        "crate_tracks" => {
            let page = app.dispatch("search", json!({"query": {"crate_id": get(input, "crate_id"), "limit": lim(50, 200)}}))?;
            let rows: Vec<Value> = page["rows"].as_array().map(|a| a.iter().map(compact_row).collect()).unwrap_or_default();
            json!({"total": page["total"], "tracks": rows})
        }
        "crate_templates" => app.dispatch("crate_templates", json!({}))?,
        "library_health" => {
            let mut h = app.dispatch("health", json!({}))?;
            if let Some(o) = h.as_object_mut() {
                if let Some(items) = o.get_mut("items").and_then(|i| i.as_array_mut()) {
                    for it in items.iter_mut() {
                        if let Some(m) = it.as_object_mut() {
                            m.remove("filters");
                        }
                    }
                }
                if let Some(e) = o.get_mut("recent_errors").and_then(|e| e.as_array_mut()) {
                    e.truncate(10);
                }
            }
            h
        }
        "duplicates_summary" => {
            let g = app.dispatch("duplicates", json!({}))?;
            let all = g.as_array().cloned().unwrap_or_default();
            let n = lim(15, 50) as usize;
            json!({"groups": all.len(), "first": all.into_iter().take(n).collect::<Vec<_>>()})
        }
        "suggestions_summary" => {
            let s = app.dispatch("suggestions", json!({"status": "pending"}))?;
            let all = s.as_array().cloned().unwrap_or_default();
            json!({"pending": all.len(), "first": all.into_iter().take(lim(30, 100) as usize).collect::<Vec<_>>()})
        }
        "jobs_status" => json!({"jobs": app.dispatch("jobs", json!({}))?, "scan": app.dispatch("scan_status", json!({}))?, "analysis": app.dispatch("analysis_summary", json!({}))?}),
        "crate_fit" => app.dispatch("crate_fit", json!({"crate_id": get(input, "crate_id")}))?,
        "list_sets" => app.dispatch("list_sets", json!({}))?,
        "preview_set" => app.dispatch("plan_set", json!({"params": set_params(input)}))?,
        "gig_status" => app.dispatch("gig_current", json!({}))?,
        "get_settings" => {
            let mut s = app.dispatch("get_settings", json!({}))?;
            if let Some(o) = s.as_object_mut() {
                o.remove("privacy_acknowledged");
            }
            s
        }
        "show_tracks" | "open_view" => json!({"ok": true, "note": "The app is now showing it to the DJ."}),

        "create_crate" => {
            let kind = get(input, "kind").and_then(|v| v.as_str()).unwrap_or("manual");
            let c = app.dispatch("create_crate", json!({"input": {"name": get(input, "name"), "kind": kind, "color": get(input, "color"), "parent_id": get(input, "parent_id"), "rules": get(input, "rules")}}))?;
            let tids = ids(input, "track_ids");
            if kind == "manual" && !tids.is_empty() {
                if let Some(id) = c.get("id") {
                    app.dispatch("crate_add", json!({"crate_id": id, "ids": tids}))?;
                }
            }
            c
        }
        "add_to_crate" => {
            let cid = get(input, "crate_id").cloned().unwrap_or(Value::Null);
            let tids = ids(input, "track_ids");
            if !tids.is_empty() {
                app.dispatch("crate_add", json!({"crate_id": cid, "ids": tids}))?
            } else if let Some(f) = get(input, "filters") {
                app.dispatch("crate_add_query", json!({"crate_id": cid, "query": {"filters": f}}))?
            } else {
                return invalid("give track_ids or filters");
            }
        }
        "remove_from_crate" => app.dispatch("crate_remove", json!({"crate_id": get(input, "crate_id"), "ids": ids(input, "track_ids")}))?,
        "apply_crate_template" => app.dispatch("apply_template", json!({"id": get(input, "template_id"), "genre": get(input, "genre")}))?,
        "update_tracks" => {
            let tids = ids(input, "track_ids");
            if tids.is_empty() || tids.len() > 5000 {
                return invalid("choose between 1 and 5000 tracks");
            }
            let mut patch = get(input, "values").cloned().unwrap_or(json!({}));
            if let Some(k) = patch.get("key").and_then(|v| v.as_str()) {
                if let Some(c) = crate::analysis::normalize_key(k) {
                    patch["key"] = json!(c);
                }
            }
            app.dispatch("update_user_fields", json!({"ids": tids, "patch": patch}))?
        }
        "tag_tracks" => app.dispatch("set_tags", json!({"ids": ids(input, "track_ids"), "add": get(input, "add").cloned().unwrap_or(json!([])), "remove": get(input, "remove").cloned().unwrap_or(json!([]))}))?,
        "start_scan" => app.dispatch("start_scan", json!({}))?,
        "start_analysis" => {
            let t = ids(input, "track_ids");
            app.dispatch("start_analysis", json!({"ids": if t.is_empty() { Value::Null } else { json!(t) }, "force": get(input, "redo").and_then(|v| v.as_bool()).unwrap_or(false)}))?
        }
        "find_local_suggestions" => app.dispatch("generate_suggestions", json!({}))?,
        "save_set" => {
            let params = set_params(input);
            let plan = app.dispatch("plan_set", json!({"params": params}))?;
            let name = get(input, "name").and_then(|v| v.as_str()).map(|s| s.to_string()).unwrap_or_else(|| format!("{} min set", get(input, "duration_min").and_then(|v| v.as_i64()).unwrap_or(60)));
            let id = app.dispatch("save_set", json!({"id": null, "name": name, "plan": plan}))?;
            json!({"saved": id, "name": name, "slots": plan.get("slots").and_then(|s| s.as_array()).map(|a| a.len())})
        }
        "start_gig_mode" => app.dispatch("gig_start", json!({"name": get(input, "name"), "set_plan_id": get(input, "set_id")}))?,
        "end_gig_mode" => app.dispatch("gig_end", json!({}))?,
        "change_setting" => {
            let key = get(input, "setting").and_then(|v| v.as_str()).unwrap_or("");
            if !["theme", "key_notation", "premium_ui", "motion", "surface", "scan_video", "low_bitrate_kbps"].contains(&key) {
                return invalid("that setting can't be changed by the assistant");
            }
            app.dispatch("set_setting", json!({"key": key, "value": get(input, "value")}))?
        }
        _ => return invalid(format!("unknown tool '{name}'")),
    };
    Ok(out)
}

// ------------------------------------------------------------- conversation

#[derive(Debug, Clone, Default)]
pub struct Conversation {
    pub messages: Vec<Value>,
    /// Tool calls waiting for the DJ, with results already computed for the
    /// other calls of the same model turn.
    pub pending: Vec<(String, String, Value)>,
    pub ready_results: Vec<Value>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct PendingAction {
    pub id: String,
    pub tool: String,
    pub summary: String,
    pub input: Value,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Turn {
    pub conversation_id: String,
    pub text: String,
    /// Screen changes for the front end: {"type": "show_tracks"|"open_view", ...}.
    pub ui_actions: Vec<Value>,
    pub pending: Vec<PendingAction>,
    /// Actions run in this turn (after approval), with their outcome.
    pub done: Vec<Value>,
    /// Read tools used, for transparency ("Looked up: …").
    pub looked_up: Vec<String>,
    pub model: String,
    pub provider: String,
}

pub fn config(app: &App) -> Result<LlmConfig> {
    let conn = crate::api::lock(&app.conn);
    let provider = db::get_setting(&conn, "ai_provider")?.unwrap_or_else(|| "off".into());
    let model = if provider == "local" {
        db::get_setting(&conn, "ai_local_model")?.unwrap_or_else(|| DEFAULT_LOCAL_MODEL.into())
    } else {
        db::get_setting(&conn, "ai_model")?.unwrap_or_else(|| CLAUDE_MODELS[0].0.into())
    };
    let local_url =
        db::get_setting(&conn, "ai_local_url")?.unwrap_or_else(|| DEFAULT_LOCAL_URL.into());
    drop(conn);
    Ok(LlmConfig {
        api_key: if provider == "claude" {
            app.secrets.get("anthropic")
        } else {
            None
        },
        provider,
        model,
        local_url,
    })
}

pub fn status(app: &App) -> Result<Value> {
    let c = config(app)?;
    let (ready, reason) = match c.provider.as_str() {
        "claude" if c.api_key.is_none() => (
            false,
            Some("Add your Anthropic API key in Settings → AI assistant."),
        ),
        "claude" | "local" => (true, None),
        _ => (
            false,
            Some("The AI assistant is off. The built-in rule-based assistant answers instead."),
        ),
    };
    let sends = match c.provider.as_str() {
        "claude" => "Your messages to the assistant and the catalogue details its tools look up (titles, artists, genres, ratings and similar) are sent to Anthropic to answer. Never audio, file paths or personal documents.",
        "local" => "Nothing leaves this computer: the model runs locally (Ollama).",
        _ => "Nothing — the AI assistant is off.",
    };
    Ok(
        json!({"provider": c.provider, "model": c.model, "ready": ready, "reason": reason, "sends": sends,
        "local_url": c.local_url, "has_key": app.secrets.get("anthropic").is_some(), "claude_models": CLAUDE_MODELS.iter().map(|(id, label)| json!({"id": id, "label": label})).collect::<Vec<_>>(),
        "default_local_model": DEFAULT_LOCAL_MODEL}),
    )
}

/// A short, stable snapshot of the library for the first message of a conversation.
fn app_state(app: &App) -> String {
    let st = app.dispatch("stats", json!({})).unwrap_or(json!({}));
    let s = app.dispatch("get_settings", json!({})).unwrap_or(json!({}));
    let crates = app
        .dispatch("list_crates", json!({}))
        .ok()
        .and_then(|c| c.as_array().map(|a| a.len()))
        .unwrap_or(0);
    format!(
        "<app_state>tracks: {}, crates: {}, folders: {}, low bitrate: {}, missing: {}, offline: {}. Key notation: {}. Gig mode: {}. Theme: {}{}.</app_state>",
        st["tracks"], crates, st["roots"], st["low_bitrate"], st["missing"], st["offline"],
        s["key_notation"].as_str().unwrap_or("camelot"),
        if s["gig_mode"].as_bool().unwrap_or(false) { "on" } else { "off" },
        s["theme"].as_str().unwrap_or("dark"),
        if s["premium_ui"].as_bool().unwrap_or(false) { ", Premium UI on" } else { "" },
    )
}

fn new_id() -> String {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("c{n:x}")
}

fn result_block(id: &str, content: &Value, is_error: bool) -> Value {
    let mut c = content.clone();
    strip_paths(&mut c);
    let mut text = if let Some(s) = c.as_str() {
        s.to_string()
    } else {
        c.to_string()
    };
    if text.len() > MAX_RESULT_CHARS {
        let mut cut = MAX_RESULT_CHARS;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
        text.push_str("… [truncated — ask for fewer results or use filters]");
    }
    let mut b = json!({"type": "tool_result", "tool_use_id": id, "content": text});
    if is_error {
        b["is_error"] = json!(true);
    }
    b
}

/// Start or continue a conversation with a message from the DJ.
pub fn chat(app: &App, conversation_id: Option<String>, message: &str) -> Result<Turn> {
    let msg = message.trim();
    if msg.is_empty() || msg.len() > 8000 {
        return invalid("message must be 1–8000 characters");
    }
    let cfg = config(app)?;
    if cfg.provider == "off" {
        return invalid("the AI assistant is off");
    }
    let id = conversation_id
        .filter(|s| !s.is_empty())
        .unwrap_or_else(new_id);
    let mut conv = crate::api::lock(&app.agent).remove(&id).unwrap_or_default();
    let mut content = vec![];
    // A new message while actions wait means the DJ moved on: they are skipped.
    if !conv.pending.is_empty() {
        content.append(&mut conv.ready_results);
        for (tid, _, _) in conv.pending.drain(..) {
            content.push(result_block(
                &tid,
                &json!("The DJ did not run this action."),
                true,
            ));
        }
    }
    if conv.messages.is_empty() {
        content.push(json!({"type": "text", "text": app_state(app)}));
    }
    content.push(json!({"type": "text", "text": msg}));
    conv.messages
        .push(json!({"role": "user", "content": content}));
    let mut turn = Turn {
        conversation_id: id.clone(),
        ..Default::default()
    };
    let r = drive(app, &cfg, &mut conv, &mut turn);
    crate::api::lock(&app.agent).insert(id, conv);
    r.map(|_| turn)
}

/// Approve or decline the actions waiting in a conversation, then continue.
pub fn confirm(
    app: &App,
    conversation_id: &str,
    decisions: &HashMap<String, bool>,
) -> Result<Turn> {
    let cfg = config(app)?;
    let mut conv = crate::api::lock(&app.agent)
        .remove(conversation_id)
        .ok_or_else(|| Error::NotFound("conversation".into()))?;
    if conv.pending.is_empty() {
        crate::api::lock(&app.agent).insert(conversation_id.to_string(), conv);
        return invalid("there are no actions waiting");
    }
    let mut turn = Turn {
        conversation_id: conversation_id.to_string(),
        ..Default::default()
    };
    let mut results = std::mem::take(&mut conv.ready_results);
    for (tid, name, input) in std::mem::take(&mut conv.pending) {
        let summary = describe(app, &name, &input);
        if decisions.get(&tid).copied().unwrap_or(false) {
            match run_tool(app, &name, &input) {
                Ok(v) => {
                    turn.done
                        .push(json!({"tool": name, "summary": summary, "ok": true}));
                    results.push(result_block(&tid, &v, false));
                }
                Err(e) => {
                    turn.done.push(json!({"tool": name, "summary": summary, "ok": false, "error": e.to_string()}));
                    results.push(result_block(&tid, &json!(format!("Failed: {e}")), true));
                }
            }
        } else {
            turn.done
                .push(json!({"tool": name, "summary": summary, "ok": false, "skipped": true}));
            results.push(result_block(
                &tid,
                &json!("The DJ chose not to run this action."),
                true,
            ));
        }
    }
    conv.messages
        .push(json!({"role": "user", "content": results}));
    let r = drive(app, &cfg, &mut conv, &mut turn);
    crate::api::lock(&app.agent).insert(conversation_id.to_string(), conv);
    r.map(|_| turn)
}

fn drive(app: &App, cfg: &LlmConfig, conv: &mut Conversation, turn: &mut Turn) -> Result<()> {
    turn.provider = cfg.provider.clone();
    turn.model = cfg.model.clone();
    if cfg.provider == "claude" && cfg.api_key.is_none() {
        return invalid("add your Anthropic API key in Settings → AI assistant first");
    }
    let tools = tool_specs();
    let mut texts: Vec<String> = vec![];
    for step in 0..MAX_STEPS {
        let reply = app
            .online
            .llm_chat(cfg, GUIDE, &tools, &conv.messages)
            .map_err(|e| Error::Invalid(format!("The AI model could not be reached: {e}")))?;
        let blocks = reply
            .get("content")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default();
        if let Some(m) = reply.get("model").and_then(|m| m.as_str()) {
            turn.model = m.to_string();
        }
        conv.messages
            .push(json!({"role": "assistant", "content": blocks.clone()}));
        for b in &blocks {
            if b["type"] == "text" {
                if let Some(t) = b["text"].as_str().filter(|t| !t.trim().is_empty()) {
                    texts.push(t.trim().to_string());
                }
            }
        }
        let stop = reply
            .get("stop_reason")
            .and_then(|s| s.as_str())
            .unwrap_or("end_turn");
        if stop == "refusal" {
            texts.push("Sorry — I can't help with that request.".into());
            break;
        }
        let uses: Vec<(String, String, Value)> = blocks
            .iter()
            .filter(|b| b["type"] == "tool_use")
            .map(|b| {
                (
                    b["id"].as_str().unwrap_or_default().to_string(),
                    b["name"].as_str().unwrap_or_default().to_string(),
                    b["input"].clone(),
                )
            })
            .collect();
        if uses.is_empty() {
            if stop == "max_tokens" {
                texts.push("(My reply was cut short — ask me to continue.)".into());
            }
            break;
        }
        let mut results = vec![];
        let mut pending = vec![];
        for (tid, name, input) in uses {
            match tier_of(&name) {
                Some(Tier::Read) => {
                    turn.looked_up.push(name.replace('_', " "));
                    match run_tool(app, &name, &input) {
                        Ok(v) => results.push(result_block(&tid, &v, false)),
                        Err(e) => {
                            results.push(result_block(&tid, &json!(format!("Error: {e}")), true))
                        }
                    }
                }
                Some(Tier::Ui) => {
                    let mut a = input.clone();
                    if !a.is_object() {
                        a = json!({});
                    }
                    a["type"] = json!(name);
                    turn.ui_actions.push(a);
                    results.push(result_block(
                        &tid,
                        &json!({"ok": true, "note": "The app is now showing it to the DJ."}),
                        false,
                    ));
                }
                Some(Tier::Act) => {
                    turn.pending.push(PendingAction {
                        id: tid.clone(),
                        tool: name.clone(),
                        summary: describe(app, &name, &input),
                        input: input.clone(),
                    });
                    pending.push((tid, name, input));
                }
                None => results.push(result_block(
                    &tid,
                    &json!(format!("Unknown tool '{name}'.")),
                    true,
                )),
            }
        }
        if !pending.is_empty() {
            conv.pending = pending;
            conv.ready_results = results;
            break;
        }
        conv.messages
            .push(json!({"role": "user", "content": results}));
        if step + 1 == MAX_STEPS {
            texts.push(
                "(I stopped after several steps — tell me how you'd like to continue.)".into(),
            );
        }
    }
    turn.text = texts.join("\n\n");
    Ok(())
}

pub fn reset(app: &App, conversation_id: &str) {
    crate::api::lock(&app.agent).remove(conversation_id);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_hidden_from_the_model() {
        let mut v = json!({"path": "C:\\Music\\a.mp3", "row": {"title": "Intro", "note": "D:\\DJ\\x.flac", "unc": "\\\\nas\\music\\x.mp3", "unix": "/home/h/Music/x.mp3", "ratio": "3/4", "text": "a: b"}, "list": ["E:/Crates/y.mp3"]});
        strip_paths(&mut v);
        assert!(v.get("path").is_none());
        assert_eq!(v["row"]["note"], "[path hidden]");
        assert_eq!(v["row"]["unc"], "[path hidden]");
        assert_eq!(v["row"]["unix"], "[path hidden]");
        assert_eq!(v["list"][0], "[path hidden]");
        assert_eq!(v["row"]["ratio"], "3/4");
        assert_eq!(v["row"]["text"], "a: b");
        assert_eq!(v["row"]["title"], "Intro");
    }

    #[test]
    fn every_tool_has_a_tier_and_an_object_schema() {
        let specs = tool_specs();
        assert_eq!(specs.len(), TOOLS.len());
        let mut names = std::collections::HashSet::new();
        for s in &specs {
            assert!(
                names.insert(s["name"].as_str().unwrap().to_string()),
                "duplicate tool"
            );
            assert_eq!(s["input_schema"]["type"], "object");
            assert!(s["input_schema"]["properties"].is_object());
        }
        // Nothing that could change files exists as a tool.
        for s in &specs {
            let n = s["name"].as_str().unwrap();
            for bad in [
                "write_", "delete_", "move_", "rename_", "copy_", "rollback", "gigpack",
            ] {
                assert!(!n.starts_with(bad) && !n.contains("files"), "{n}");
            }
        }
        // Every catalogue-changing tool needs approval.
        for t in [
            "create_crate",
            "add_to_crate",
            "remove_from_crate",
            "update_tracks",
            "tag_tracks",
            "start_scan",
            "start_analysis",
            "save_set",
            "start_gig_mode",
            "end_gig_mode",
            "change_setting",
            "apply_crate_template",
            "find_local_suggestions",
        ] {
            assert_eq!(tier_of(t), Some(Tier::Act), "{t}");
        }
        assert!(GUIDE.contains("Camelot wheel") && GUIDE.contains("never written"));
    }
}
