//! Library health summary. Each category maps to a rule set so the UI can
//! open the matching tracks in the normal library view.
use crate::error::Result;
use crate::library::{self, TrackQuery};
use crate::rules::{MatchMode, RuleNode, RuleSet};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Serialize)]
pub struct HealthItem {
    pub id: String,
    pub label: String,
    pub explanation: String,
    pub count: i64,
    pub filters: RuleSet,
    pub include_missing: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanErrorRow {
    pub path: String,
    pub kind: String,
    pub message: String,
    pub at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Health {
    pub items: Vec<HealthItem>,
    pub last_scan: Option<serde_json::Value>,
    pub recent_errors: Vec<ScanErrorRow>,
    pub low_bitrate_threshold_kbps: u32,
}

fn cond(field: &str, op: &str, value: serde_json::Value) -> RuleNode {
    RuleNode::Condition {
        field: field.into(),
        op: op.into(),
        value,
    }
}

pub fn categories(low: u32) -> Vec<(String, String, String, RuleSet, bool)> {
    let all = |rules| RuleSet {
        match_mode: MatchMode::All,
        rules,
        exclude: vec![],
    };
    let any = |rules| RuleSet {
        match_mode: MatchMode::Any,
        rules,
        exclude: vec![],
    };
    vec![
        ("missing_core".into(), "Missing title or artist".into(), "The file has no title or artist tag. Values shown as unknown are not guessed.".into(),
            all(vec![cond("status", "equals", json!("ok")), RuleNode::Group { match_mode: MatchMode::Any, rules: vec![cond("title", "is_empty", json!(null)), cond("artist", "is_empty", json!(null))] }]), false),
        ("missing_genre".into(), "Missing genre".into(), "No genre in the file tag and none set in your catalogue.".into(),
            all(vec![cond("status", "equals", json!("ok")), cond("genre", "is_empty", json!(null))]), false),
        ("missing_year".into(), "Missing year".into(), "No year in the file tag and none set in your catalogue.".into(),
            all(vec![cond("status", "equals", json!("ok")), cond("year", "is_empty", json!(null))]), false),
        ("low_bitrate".into(), format!("Low bitrate (lossy, under {low} kbps)"),
            format!("Lossy files whose reported average bitrate is below {low} kbps. Lossless and unknown-bitrate files are not counted. Bitrate alone does not prove audio quality: a file may have been transcoded from a worse source."),
            all(vec![cond("quality", "equals", json!("low_bitrate"))]), false),
        ("unknown_bitrate".into(), "Unknown quality".into(), "Bitrate or codec could not be determined. Not flagged as low quality.".into(),
            all(vec![cond("quality", "equals", json!("unknown")), cond("status", "equals", json!("ok"))]), false),
        ("read_errors".into(), "Unreadable or corrupt".into(), "Files that could not be opened or parsed. They were not modified.".into(),
            all(vec![cond("status", "equals", json!("error"))]), false),
        ("unsupported".into(), "Unsupported formats".into(), "Music files in formats this version cannot read (for example WMA).".into(),
            all(vec![cond("status", "equals", json!("unsupported"))]), false),
        ("offline".into(), "On offline drives".into(), "Tracks in folders that were not available at the last scan. They are kept, not deleted.".into(),
            all(vec![cond("status", "equals", json!("offline"))]), false),
        ("missing".into(), "Missing files".into(), "Files that were not found during the last completed scan of an available folder. Catalogue entries are kept so nothing is lost.".into(),
            any(vec![cond("status", "equals", json!("missing"))]), true),
    ]
}

pub fn health(conn: &Connection) -> Result<Health> {
    let low = crate::db::low_bitrate_threshold(conn)?;
    let mut items = Vec::new();
    for (id, label, explanation, filters, include_missing) in categories(low) {
        let page = library::search(
            conn,
            &TrackQuery {
                filters: Some(filters.clone()),
                include_missing,
                limit: Some(1),
                ..Default::default()
            },
        )?;
        items.push(HealthItem {
            id,
            label,
            explanation,
            count: page.total,
            filters,
            include_missing,
        });
    }
    let last_scan = conn
        .query_row(
            "SELECT id, started_at, finished_at, status, files_seen, tracks_added, tracks_updated, tracks_unchanged, tracks_missing, error_count, message FROM scans ORDER BY id DESC LIMIT 1",
            [],
            |r| {
                Ok(json!({"id": r.get::<_, i64>(0)?, "started_at": r.get::<_, i64>(1)?, "finished_at": r.get::<_, Option<i64>>(2)?,
                    "status": r.get::<_, String>(3)?, "files_seen": r.get::<_, i64>(4)?, "added": r.get::<_, i64>(5)?, "updated": r.get::<_, i64>(6)?,
                    "unchanged": r.get::<_, i64>(7)?, "missing": r.get::<_, i64>(8)?, "errors": r.get::<_, i64>(9)?, "message": r.get::<_, Option<String>>(10)?}))
            },
        )
        .ok();
    let mut stmt = conn.prepare(
        "SELECT path, kind, message, at FROM scan_errors WHERE scan_id=(SELECT MAX(id) FROM scans) ORDER BY id LIMIT 500",
    )?;
    let recent_errors = stmt
        .query_map(params![], |r| {
            Ok(ScanErrorRow {
                path: r.get(0)?,
                kind: r.get(1)?,
                message: r.get(2)?,
                at: r.get(3)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(Health {
        items,
        last_scan,
        recent_errors,
        low_bitrate_threshold_kbps: low,
    })
}
