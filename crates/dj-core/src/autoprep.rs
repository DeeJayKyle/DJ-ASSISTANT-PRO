//! Auto-prep: what happens by itself after new music is scanned.
//!
//! 1. Audio analysis of tracks not analysed yet (BPM, key, energy, loudness,
//!    intro/outro, cue ideas). Its values fill the library straight away as
//!    estimates; the DJ's own values and the file's tags still win.
//! 2. Local suggestions from file names, folders, albums and artists
//!    (title, artist, genre, year, version labels…).
//! 3. MusicBrainz lookups for tracks still missing details — only when the DJ
//!    has switched MusicBrainz on.
//! 4. High-confidence suggestions are accepted into the catalogue.
//!
//! Everything lands in DJ Assistant's catalogue only. Writing the fixes into
//! the music files is a separate, previewed step the DJ approves.
use crate::db;
use crate::error::Result;
use crate::jobs::{message, Progress};
use crate::online::Online;
use crate::scanner::ScanControl;
use rusqlite::Connection;
use serde_json::json;
use std::path::Path;

pub fn enabled(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "auto_prep")?
        .map(|v| v == "1")
        .unwrap_or(true))
}

/// Minimum confidence for a suggestion to be applied automatically.
pub fn min_confidence(conn: &Connection) -> Result<f64> {
    Ok(db::get_setting(conn, "auto_fix_min")?
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|v| (0.5..=1.0).contains(v))
        .unwrap_or(0.85))
}

fn missing_counts(conn: &Connection) -> Result<serde_json::Value> {
    let h = crate::health::health(conn)?;
    let get = |id: &str| {
        h.items
            .iter()
            .find(|i| i.id == id)
            .map(|i| i.count)
            .unwrap_or(0)
    };
    Ok(
        json!({"missing_core": get("missing_core"), "missing_genre": get("missing_genre"), "missing_year": get("missing_year"),
        "missing_album": get("missing_album"), "missing_bpm": get("missing_bpm"), "missing_key": get("missing_key")}),
    )
}

pub fn run(db_path: &Path, online: &dyn Online, ctl: &ScanControl, p: &Progress) -> Result<()> {
    let conn = db::open(db_path)?;
    let before = missing_counts(&conn)?;
    let pending_analysis = crate::analysis_store::pending_ids(&conn, None, false)?.len();

    message(p, format!("Analysing {pending_analysis} track(s)…"));
    if pending_analysis > 0 {
        crate::analysis_store::run_job(db_path, None, false, ctl, p)?;
    }
    if crate::jobs::wait_or_cancelled(ctl) {
        return Ok(());
    }

    message(
        p,
        "Looking for fixes in file names, folders, albums and artists…",
    );
    let created = crate::suggest::generate_local(&conn)?;

    let mut looked_up = 0usize;
    if crate::suggest::service_enabled(&conn, "musicbrainz")? {
        let ids: Vec<i64> = conn
            .prepare(
                "SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id
                 WHERE t.presence='present' AND t.read_status='ok' AND t.media_kind='audio'
                   AND COALESCE(u.artist, t.artist) IS NOT NULL AND COALESCE(u.title, t.title) IS NOT NULL
                   AND (COALESCE(u.year, t.year) IS NULL OR COALESCE(u.genre, t.genre) IS NULL)
                 ORDER BY t.first_seen_at DESC LIMIT 200",
            )?
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?;
        if !ids.is_empty() {
            message(
                p,
                format!(
                    "Looking up {} track(s) on MusicBrainz (one per second)…",
                    ids.len()
                ),
            );
            looked_up = ids.len();
            crate::suggest::musicbrainz_lookup(&conn, online, &ids, ctl, p)?;
        }
    }

    let min = min_confidence(&conn)?;
    message(p, "Applying recommended fixes to your catalogue…");
    // Fill gaps from the best evidence; replace existing values only when very sure.
    let applied = crate::suggest::accept_recommended(&conn, 0.35, min)?;
    let after = missing_counts(&conn)?;
    let to_review: i64 = conn.query_row(
        "SELECT COUNT(*) FROM suggestions WHERE status='pending'",
        [],
        |r| r.get(0),
    )?;
    let summary = json!({
        "analysed": pending_analysis, "suggestions_found": created, "musicbrainz_lookups": looked_up,
        "fixes_applied": applied, "min_confidence": min, "left_to_review": to_review,
        "missing_before": before, "missing_after": after,
    });
    message(
        p,
        format!("Done: analysed {pending_analysis}, applied {applied} fix(es); {to_review} suggestion(s) left for you to review."),
    );
    crate::jobs::lock(p).result = Some(summary);
    Ok(())
}
