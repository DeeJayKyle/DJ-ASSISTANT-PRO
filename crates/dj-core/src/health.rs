//! Library health summary. Each category maps to a rule set so the UI can
//! open the matching tracks in the normal library view.
use crate::error::Result;
use crate::library::{self, TrackQuery};
use crate::rules::{MatchMode, RuleNode, RuleSet};
use crate::text::fold;
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::json;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize)]
pub struct HealthItem {
    pub id: String,
    pub label: String,
    pub explanation: String,
    pub count: i64,
    pub filters: RuleSet,
    pub include_missing: bool,
    /// Catalogue fields the DJ can fill in from the Fix list (empty = review only).
    pub fix_fields: Vec<&'static str>,
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
        ("missing_album".into(), "Missing album".into(), "No album in the file tag and none set in your catalogue.".into(),
            all(vec![cond("status", "equals", json!("ok")), cond("album", "is_empty", json!(null))]), false),
        ("missing_bpm".into(), "Missing BPM".into(), "No BPM in the file tag, your catalogue or analysis. Run analysis or type it in.".into(),
            all(vec![cond("status", "equals", json!("ok")), cond("bpm", "is_empty", json!(null))]), false),
        ("missing_key".into(), "Missing key".into(), "No key in the file tag, your catalogue or analysis. Run analysis or type it in.".into(),
            all(vec![cond("status", "equals", json!("ok")), cond("key", "is_empty", json!(null))]), false),
        ("low_bitrate".into(), format!("Low bitrate (lossy, under {low} kbps)"),
            format!("Lossy files whose reported average bitrate is below {low} kbps. Lossless and unknown-bitrate files are not counted. Bitrate alone does not prove audio quality: a file may have been transcoded from a worse source."),
            all(vec![cond("quality", "equals", json!("low_bitrate"))]), false),
        ("unknown_bitrate".into(), "Unknown quality".into(), "Bitrate or codec could not be determined. Not flagged as low quality.".into(),
            all(vec![cond("quality", "equals", json!("unknown")), cond("status", "equals", json!("ok"))]), false),
        ("read_errors".into(), "Unreadable or corrupt".into(), "Files that could not be opened or parsed. They were not modified.".into(),
            all(vec![cond("status", "equals", json!("error"))]), false),
        ("unsupported".into(), "Unsupported formats".into(), "Music or video files in formats this version cannot read (for example WMA or WMV).".into(),
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
        let fields = fix_fields(&id).to_vec();
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
            fix_fields: fields,
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

/// Which catalogue fields each health category can fix.
pub fn fix_fields(category: &str) -> &'static [&'static str] {
    match category {
        "missing_core" => &["artist", "title"],
        "missing_genre" => &["genre"],
        "missing_year" => &["year"],
        "missing_album" => &["album"],
        "missing_bpm" => &["bpm"],
        "missing_key" => &["key"],
        _ => &[],
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Hint {
    pub field: String,
    pub value: String,
    pub source: String,
    pub evidence: String,
    /// Set when the hint is a stored suggestion (accept it by id).
    pub suggestion_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FixRow {
    pub track: library::TrackRow,
    pub folder: String,
    pub hints: Vec<Hint>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FixList {
    pub category: String,
    pub label: String,
    pub fields: Vec<&'static str>,
    pub total: i64,
    pub rows: Vec<FixRow>,
}

fn majority(m: &HashMap<String, HashMap<String, i64>>, k: &str) -> Option<(String, i64)> {
    m.get(k)?
        .iter()
        .max_by(|a, b| a.1.cmp(b.1).then_with(|| b.0.cmp(a.0)))
        .map(|(v, n)| (v.clone(), *n))
}

/// Tracks in a health category with local, evidence-based hints for each
/// missing field. Nothing is written: the DJ chooses what to save, and saving
/// only changes DJ Assistant's catalogue, never the files.
pub fn fix_list(conn: &Connection, category: &str, limit: i64, offset: i64) -> Result<FixList> {
    let low = crate::db::low_bitrate_threshold(conn)?;
    let Some((id, label, _, filters, include_missing)) =
        categories(low).into_iter().find(|c| c.0 == category)
    else {
        return crate::error::invalid("unknown health category");
    };
    let fields = fix_fields(&id).to_vec();
    if fields.is_empty() {
        return crate::error::invalid("this category is reviewed in the library, not fixed here");
    }
    let page = library::search(
        conn,
        &TrackQuery {
            filters: Some(filters),
            include_missing,
            limit: Some(limit.clamp(1, 500)),
            offset: Some(offset.max(0)),
            sort: Some("path".into()),
            ..Default::default()
        },
    )?;

    // Library-wide evidence: spellings of known genres, and genre/year/artist by album.
    let mut genre_forms: HashMap<String, HashMap<String, i64>> = HashMap::new();
    let mut by_album_genre: HashMap<String, HashMap<String, i64>> = HashMap::new();
    let mut by_album_year: HashMap<String, HashMap<String, i64>> = HashMap::new();
    let mut by_album_artist: HashMap<String, HashMap<String, i64>> = HashMap::new();
    let mut by_artist_genre: HashMap<String, HashMap<String, i64>> = HashMap::new();
    {
        let mut st = conn.prepare(
            "SELECT COALESCE(u.genre, t.genre), COALESCE(u.year, t.year), COALESCE(u.album, t.album), COALESCE(u.artist, t.artist)
             FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok'",
        )?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let g: Option<String> = r.get(0)?;
            let y: Option<i64> = r.get(1)?;
            let al: Option<String> = r.get(2)?;
            let ar: Option<String> = r.get(3)?;
            let g = g.filter(|x| !x.trim().is_empty());
            if let Some(g) = &g {
                *genre_forms
                    .entry(fold(g))
                    .or_default()
                    .entry(g.trim().to_string())
                    .or_default() += 1;
            }
            if let Some(al) = al.as_deref().map(fold).filter(|x| !x.is_empty()) {
                if let Some(g) = &g {
                    *by_album_genre
                        .entry(al.clone())
                        .or_default()
                        .entry(g.trim().to_string())
                        .or_default() += 1;
                }
                if let Some(y) = y {
                    *by_album_year
                        .entry(al.clone())
                        .or_default()
                        .entry(y.to_string())
                        .or_default() += 1;
                }
                if let Some(a) = ar.as_deref().filter(|x| !x.trim().is_empty()) {
                    *by_album_artist
                        .entry(al)
                        .or_default()
                        .entry(a.trim().to_string())
                        .or_default() += 1;
                }
            }
            if let (Some(a), Some(g)) = (ar.as_deref().filter(|x| !x.trim().is_empty()), &g) {
                *by_artist_genre
                    .entry(fold(a))
                    .or_default()
                    .entry(g.trim().to_string())
                    .or_default() += 1;
            }
        }
    }

    let mut rows = Vec::with_capacity(page.rows.len());
    for t in page.rows {
        let rel: String = conn
            .query_row(
                "SELECT rel_path FROM tracks WHERE id=?1",
                params![t.id],
                |r| r.get(0),
            )
            .unwrap_or_default();
        let rel_norm = rel.replace('\\', "/");
        let parts: Vec<&str> = rel_norm.split('/').collect();
        let folders: Vec<&str> = parts[..parts.len().saturating_sub(1)].to_vec();
        let folder = folders.join("/");
        let stem = std::path::Path::new(&t.file_name)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let mut hints: Vec<Hint> = vec![];
        // Stored suggestions first (local rules or online lookups the DJ ran).
        let mut st = conn.prepare(
            "SELECT id, field, suggested_value, source, COALESCE(evidence,'') FROM suggestions WHERE track_id=?1 AND status='pending' ORDER BY confidence DESC, id",
        )?;
        let stored: Vec<(i64, String, String, String, String)> = st
            .query_map(params![t.id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
            })?
            .collect::<std::result::Result<_, _>>()?;
        let album = t.album.as_deref().map(fold).filter(|x| !x.is_empty());
        let artist_f = t.artist.as_deref().map(fold).filter(|x| !x.is_empty());
        for f in &fields {
            for (sid, sf, v, src, ev) in stored.iter().filter(|s| s.1 == *f) {
                add_hint(&mut hints, sf, v.clone(), src, ev.clone());
                if let Some(h) = hints.last_mut().filter(|h| {
                    h.suggestion_id.is_none() && h.field == *sf && fold(&h.value) == fold(v)
                }) {
                    h.suggestion_id = Some(*sid);
                }
            }
            match *f {
                "artist" | "title" => {
                    if let Some((a, ti)) = crate::suggest::parse_filename(&stem) {
                        if *f == "artist" && t.artist.as_deref().unwrap_or("").trim().is_empty() {
                            add_hint(
                                &mut hints,
                                "artist",
                                a,
                                "file name",
                                format!("File name \"{}\"", t.file_name),
                            );
                        }
                        if *f == "title" && t.title.as_deref().unwrap_or("").trim().is_empty() {
                            add_hint(
                                &mut hints,
                                "title",
                                ti,
                                "file name",
                                format!("File name \"{}\"", t.file_name),
                            );
                        }
                    } else if *f == "title"
                        && t.title.as_deref().unwrap_or("").trim().is_empty()
                        && !stem.trim().is_empty()
                    {
                        add_hint(
                            &mut hints,
                            "title",
                            stem.replace('_', " "),
                            "file name",
                            "The file name without its extension".into(),
                        );
                    }
                    if *f == "artist" {
                        if let Some((a, n)) = album
                            .as_deref()
                            .and_then(|al| majority(&by_album_artist, al))
                        {
                            add_hint(
                                &mut hints,
                                "artist",
                                a,
                                "same album",
                                format!("{n} other track(s) on this album"),
                            );
                        }
                    }
                }
                "genre" => {
                    for dir in folders.iter().rev() {
                        if let Some((g, n)) = majority(&genre_forms, &fold(dir)) {
                            add_hint(
                                &mut hints,
                                "genre",
                                g,
                                "folder name",
                                format!("In folder \"{dir}\"; {n} track(s) already use this genre"),
                            );
                        }
                    }
                    if let Some((g, n)) = album
                        .as_deref()
                        .and_then(|al| majority(&by_album_genre, al))
                    {
                        add_hint(
                            &mut hints,
                            "genre",
                            g,
                            "same album",
                            format!("{n} other track(s) on this album"),
                        );
                    }
                    if let Some((g, n)) = artist_f
                        .as_deref()
                        .and_then(|a| majority(&by_artist_genre, a))
                    {
                        add_hint(
                            &mut hints,
                            "genre",
                            g,
                            "same artist",
                            format!("{n} other track(s) by this artist"),
                        );
                    }
                }
                "year" => {
                    if let Some(y) = crate::suggest::year_in(&stem) {
                        add_hint(
                            &mut hints,
                            "year",
                            y.to_string(),
                            "file name",
                            format!("\"({y})\" in the file name"),
                        );
                    }
                    for dir in folders.iter().rev() {
                        if let Some(y) = crate::suggest::year_in(dir) {
                            add_hint(
                                &mut hints,
                                "year",
                                y.to_string(),
                                "folder name",
                                format!("\"({y})\" in folder \"{dir}\""),
                            );
                        }
                    }
                    if let Some(y) = t.original_year {
                        add_hint(
                            &mut hints,
                            "year",
                            y.to_string(),
                            "original year tag",
                            "The file's original-year tag".into(),
                        );
                    }
                    if let Some((y, n)) =
                        album.as_deref().and_then(|al| majority(&by_album_year, al))
                    {
                        add_hint(
                            &mut hints,
                            "year",
                            y,
                            "same album",
                            format!("{n} other track(s) on this album"),
                        );
                    }
                }
                _ => {}
            }
        }
        rows.push(FixRow {
            track: t,
            folder,
            hints,
        });
    }
    Ok(FixList {
        category: id,
        label,
        fields,
        total: page.total,
        rows,
    })
}

fn add_hint(hints: &mut Vec<Hint>, field: &str, value: String, source: &str, evidence: String) {
    let value = value.trim().to_string();
    if value.is_empty()
        || hints
            .iter()
            .any(|h| h.field == field && fold(&h.value) == fold(&value))
    {
        return;
    }
    hints.push(Hint {
        field: field.into(),
        value,
        source: source.into(),
        evidence,
        suggestion_id: None,
    });
}
