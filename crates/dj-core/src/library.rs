//! Library queries and catalogue-only edits. Nothing here touches music files.
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use crate::paths;
use crate::rules::{self, RuleSet};
use crate::text::{fold, like_escape};
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct Root {
    pub id: i64,
    pub path: String,
    pub label: Option<String>,
    pub status: String,
    pub added_at: i64,
    pub last_scan_at: Option<i64>,
    pub last_scan_status: Option<String>,
    pub track_count: i64,
}

pub fn list_roots(conn: &Connection) -> Result<Vec<Root>> {
    let mut stmt = conn.prepare(
        "SELECT r.id, r.path, r.label, r.status, r.added_at, r.last_scan_at, r.last_scan_status,
                (SELECT COUNT(*) FROM tracks t WHERE t.root_id=r.id AND t.presence='present')
         FROM library_roots r ORDER BY r.path",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Root {
                id: r.get(0)?,
                path: r.get(1)?,
                label: r.get(2)?,
                status: r.get(3)?,
                added_at: r.get(4)?,
                last_scan_at: r.get(5)?,
                last_scan_status: r.get(6)?,
                track_count: r.get(7)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// Add a folder to the library. Does not scan. Rejects nested roots so the
/// same file is never catalogued twice.
pub fn add_root(conn: &Connection, path: &str) -> Result<Root> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return invalid("folder path is empty");
    }
    let p = std::path::Path::new(trimmed);
    if !p.is_absolute() {
        return invalid("please choose a full folder path (for example D:\\Music)");
    }
    let md =
        std::fs::metadata(p).map_err(|e| Error::Invalid(format!("cannot open folder: {e}")))?;
    if !md.is_dir() {
        return invalid("that path is a file, not a folder");
    }
    let key = paths::path_key_with(trimmed, paths::CASE_INSENSITIVE);
    for r in list_roots(conn)? {
        let rk = paths::path_key_with(&r.path, paths::CASE_INSENSITIVE);
        if rk == key {
            return invalid("this folder is already in your library");
        }
        if paths::key_is_within(&key, &rk) {
            return invalid(format!(
                "this folder is inside an existing library folder ({})",
                r.path
            ));
        }
        if paths::key_is_within(&rk, &key) {
            return invalid(format!(
                "this folder contains an existing library folder ({}); remove that one first",
                r.path
            ));
        }
    }
    let label = p
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .filter(|s| !s.is_empty());
    conn.execute(
        "INSERT INTO library_roots(path, path_key, label, status, added_at) VALUES (?1, ?2, ?3, 'online', ?4)",
        params![trimmed, key, label, now_ms()],
    )?;
    let id = conn.last_insert_rowid();
    list_roots(conn)?
        .into_iter()
        .find(|r| r.id == id)
        .ok_or_else(|| Error::NotFound("root".into()))
}

/// Remove a folder from the catalogue (and its catalogue rows). Files on disk
/// are never touched.
pub fn remove_root(conn: &Connection, id: i64) -> Result<usize> {
    let tx = conn.unchecked_transaction()?;
    let n = tx.execute("DELETE FROM tracks WHERE root_id=?1", params![id])?;
    tx.execute("DELETE FROM library_roots WHERE id=?1", params![id])?;
    tx.commit()?;
    Ok(n)
}

#[derive(Debug, Clone, Serialize)]
pub struct TrackRow {
    pub id: i64,
    pub uid: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub year: Option<i64>,
    pub bpm: Option<f64>,
    pub key: Option<String>,
    pub energy: Option<i64>,
    pub rating: Option<i64>,
    pub mood: Option<String>,
    pub color: Option<String>,
    pub version: Option<String>,
    pub clean_explicit: Option<String>,
    pub duration_ms: Option<i64>,
    pub bitrate_kbps: Option<i64>,
    pub format: Option<String>,
    pub lossless: Option<bool>,
    pub quality: String,
    pub status: String,
    pub file_name: String,
    pub path: String,
    pub file_size: i64,
    pub tags: Vec<String>,
    pub bpm_source: Option<String>,
    pub key_source: Option<String>,
    pub energy_source: Option<String>,
    pub analysis: Option<String>,
    pub original_year: Option<i64>,
}

const ROW_COLS: &str = "t.id, t.uid, COALESCE(u.title, t.title), COALESCE(u.artist, t.artist), COALESCE(u.album, t.album), COALESCE(u.genre, t.genre), COALESCE(u.year, t.year),
  COALESCE(u.bpm, t.bpm_tag, a.bpm), keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)), COALESCE(u.energy, a.energy), u.rating, u.mood, u.color,
  COALESCE(u.version_label, t.version_hint), COALESCE(u.clean_explicit, t.clean_hint), t.duration_ms, t.bitrate_kbps,
  t.format, t.lossless, QUALITY_EXPR, STATUS_EXPR, t.file_name, t.path, t.file_size,
  (SELECT GROUP_CONCAT(g.name, char(31)) FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id),
  CASE WHEN u.bpm IS NOT NULL THEN 'you' WHEN t.bpm_tag IS NOT NULL THEN 'tag' WHEN a.bpm IS NOT NULL THEN 'analysis' END,
  CASE WHEN u.musical_key IS NOT NULL THEN 'you' WHEN t.key_tag IS NOT NULL THEN 'tag' WHEN a.camelot IS NOT NULL THEN 'analysis' END,
  CASE WHEN u.energy IS NOT NULL THEN 'you' WHEN a.energy IS NOT NULL THEN 'analysis' END,
  a.status, COALESCE(u.original_year, t.original_year)";

pub const FROM: &str = "FROM tracks t LEFT JOIN track_user u ON u.track_id = t.id LEFT JOIN library_roots r ON r.id = t.root_id LEFT JOIN analysis a ON a.track_id = t.id";

fn row_cols(low: u32) -> String {
    let q = format!(
        "(CASE WHEN t.lossless=1 THEN 'lossless' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < {low} THEN 'low_bitrate' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL THEN 'lossy' ELSE 'unknown' END)"
    );
    let s = "(CASE WHEN t.presence='missing' THEN 'missing' WHEN r.status='offline' THEN 'offline' WHEN t.read_status<>'ok' THEN t.read_status ELSE 'ok' END)";
    ROW_COLS
        .replace("QUALITY_EXPR", &q)
        .replace("STATUS_EXPR", s)
}

fn map_row(r: &Row) -> rusqlite::Result<TrackRow> {
    let tags: Option<String> = r.get(24)?;
    Ok(TrackRow {
        id: r.get(0)?,
        uid: r.get(1)?,
        title: r.get(2)?,
        artist: r.get(3)?,
        album: r.get(4)?,
        genre: r.get(5)?,
        year: r.get(6)?,
        bpm: r.get(7)?,
        key: r.get(8)?,
        energy: r.get(9)?,
        rating: r.get(10)?,
        mood: r.get(11)?,
        color: r.get(12)?,
        version: r.get(13)?,
        clean_explicit: r.get(14)?,
        duration_ms: r.get(15)?,
        bitrate_kbps: r.get(16)?,
        format: r.get(17)?,
        lossless: r.get::<_, Option<i64>>(18)?.map(|v| v == 1),
        quality: r.get(19)?,
        status: r.get(20)?,
        file_name: r.get(21)?,
        path: r.get(22)?,
        file_size: r.get(23)?,
        tags: tags
            .map(|s| s.split('\u{1f}').map(|x| x.to_string()).collect())
            .unwrap_or_default(),
        bpm_source: r.get(25)?,
        key_source: r.get(26)?,
        energy_source: r.get(27)?,
        analysis: r.get(28)?,
        original_year: r.get(29)?,
    })
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct TrackQuery {
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub filters: Option<RuleSet>,
    #[serde(default)]
    pub crate_id: Option<i64>,
    #[serde(default)]
    pub root_id: Option<i64>,
    #[serde(default)]
    pub include_missing: bool,
    #[serde(default)]
    pub sort: Option<String>,
    #[serde(default)]
    pub desc: bool,
    #[serde(default)]
    pub offset: Option<i64>,
    #[serde(default)]
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TrackPage {
    pub total: i64,
    pub offset: i64,
    pub rows: Vec<TrackRow>,
}

fn sort_expr(s: &str) -> Option<&'static str> {
    Some(match s {
        "title" => "fold(COALESCE(u.title, t.title))",
        "artist" => "fold(COALESCE(u.artist, t.artist))",
        "album" => "fold(COALESCE(u.album, t.album))",
        "genre" => "fold(COALESCE(u.genre, t.genre))",
        "year" => "COALESCE(u.year, t.year)",
        "bpm" => "COALESCE(u.bpm, t.bpm_tag, a.bpm)",
        "key" => "keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))",
        "energy" => "COALESCE(u.energy, a.energy)",
        "loudness" => "a.loudness_lufs",
        "rating" => "u.rating",
        "duration" => "t.duration_ms",
        "bitrate" => "t.bitrate_kbps",
        "format" => "t.format",
        "added" => "t.first_seen_at",
        "path" => "fold(t.path)",
        "size" => "t.file_size",
        _ => return None,
    })
}

/// Build the WHERE clause for a query. Returns (sql, params).
pub fn where_clause(conn: &Connection, q: &TrackQuery) -> Result<(String, Vec<Value>)> {
    let low = db::low_bitrate_threshold(conn)?;
    let mut parts: Vec<String> = Vec::new();
    let mut params: Vec<Value> = Vec::new();
    if !q.include_missing {
        parts.push("t.presence = 'present'".into());
    }
    if let Some(root) = q.root_id {
        params.push(Value::Integer(root));
        parts.push(format!("t.root_id = ?{}", params.len()));
    }
    if let Some(text) = q.text.as_deref() {
        let tokens: Vec<String> = text
            .split_whitespace()
            .take(12)
            .map(fold)
            .filter(|s| !s.is_empty())
            .collect();
        for tok in tokens {
            params.push(Value::Text(format!("%{}%", like_escape(&tok))));
            let p = params.len();
            parts.push(format!(
                "(t.search_text LIKE ?{p} ESCAPE '\\' OR fold(COALESCE(u.genre,'') || ' ' || COALESCE(u.mood,'') || ' ' || COALESCE(u.notes,'') || ' ' || COALESCE(u.version_label,'') || ' ' || COALESCE(u.title,'') || ' ' || COALESCE(u.artist,'') || ' ' || COALESCE(u.album,'')) LIKE ?{p} ESCAPE '\\'
                  OR EXISTS (SELECT 1 FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id AND g.name_fold LIKE ?{p} ESCAPE '\\'))"
            ));
        }
    }
    if let Some(cid) = q.crate_id {
        let (frag, mut ps) = crate::crates::membership_sql(conn, cid, low, params.len())?;
        parts.push(frag);
        params.append(&mut ps);
    }
    if let Some(f) = &q.filters {
        let c = rules::compile(f, low, params.len())?;
        parts.push(c.sql);
        params.extend(c.params);
    }
    let sql = if parts.is_empty() {
        "1=1".into()
    } else {
        parts.join(" AND ")
    };
    Ok((sql, params))
}

pub fn search(conn: &Connection, q: &TrackQuery) -> Result<TrackPage> {
    let low = db::low_bitrate_threshold(conn)?;
    let (w, params) = where_clause(conn, q)?;
    let total: i64 = conn.query_row(
        &format!("SELECT COUNT(*) {FROM} WHERE {w}"),
        params_from_iter(params.iter()),
        |r| r.get(0),
    )?;
    let limit = q.limit.unwrap_or(200).clamp(1, 2000);
    let offset = q.offset.unwrap_or(0).max(0);
    let order = match q.sort.as_deref().map(sort_expr) {
        Some(Some(e)) => format!(
            "{e} IS NULL, {e} {}, t.id",
            if q.desc { "DESC" } else { "ASC" }
        ),
        Some(None) => return invalid("unknown sort column"),
        None => "fold(COALESCE(u.artist, t.artist)) IS NULL, fold(COALESCE(u.artist, t.artist)), fold(COALESCE(u.title, t.title)), t.id".into(),
    };
    let sql = format!(
        "SELECT {} {FROM} WHERE {w} ORDER BY {order} LIMIT {limit} OFFSET {offset}",
        row_cols(low)
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt
        .query_map(params_from_iter(params.iter()), map_row)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(TrackPage {
        total,
        offset,
        rows,
    })
}

pub fn track_ids(conn: &Connection, q: &TrackQuery, max: i64) -> Result<Vec<i64>> {
    let (w, params) = where_clause(conn, q)?;
    let mut stmt = conn.prepare(&format!(
        "SELECT t.id {FROM} WHERE {w} LIMIT {}",
        max.clamp(1, 100_000)
    ))?;
    let ids = stmt
        .query_map(params_from_iter(params.iter()), |r| r.get(0))?
        .collect::<std::result::Result<Vec<i64>, _>>()?;
    Ok(ids)
}

/// Full detail for one track: original file values, catalogue values and
/// technical properties are returned separately so the UI never blurs them.
#[derive(Debug, Clone, Serialize)]
pub struct TrackDetail {
    pub row: TrackRow,
    pub file: serde_json::Value,
    pub mine: serde_json::Value,
    pub technical: serde_json::Value,
    pub crates: Vec<(i64, String)>,
    pub read_error: Option<String>,
    pub analysis: Option<serde_json::Value>,
    pub plays: i64,
}

pub fn track_detail(conn: &Connection, id: i64) -> Result<TrackDetail> {
    let low = db::low_bitrate_threshold(conn)?;
    let row = conn
        .query_row(
            &format!("SELECT {} {FROM} WHERE t.id=?1", row_cols(low)),
            params![id],
            map_row,
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("track".into()))?;
    let (file, technical, read_error) = conn.query_row(
        "SELECT title, artist, album, album_artist, genre, year, date_text, original_year, track_no, disc_no, composer, label, comment, isrc, bpm_tag, key_tag, version_hint, clean_hint,
                format, codec, lossless, duration_ms, bitrate_kbps, sample_rate, bit_depth, channels, file_size, file_mtime, path, extension, first_seen_at, last_seen_at, content_hash, read_status, read_error, presence
         FROM tracks WHERE id=?1",
        params![id],
        |r| {
            let file = serde_json::json!({
                "title": r.get::<_, Option<String>>(0)?, "artist": r.get::<_, Option<String>>(1)?, "album": r.get::<_, Option<String>>(2)?,
                "album_artist": r.get::<_, Option<String>>(3)?, "genre": r.get::<_, Option<String>>(4)?, "year": r.get::<_, Option<i64>>(5)?,
                "date": r.get::<_, Option<String>>(6)?, "original_year": r.get::<_, Option<i64>>(7)?, "track_no": r.get::<_, Option<i64>>(8)?,
                "disc_no": r.get::<_, Option<i64>>(9)?, "composer": r.get::<_, Option<String>>(10)?, "label": r.get::<_, Option<String>>(11)?,
                "comment": r.get::<_, Option<String>>(12)?, "isrc": r.get::<_, Option<String>>(13)?, "bpm": r.get::<_, Option<f64>>(14)?,
                "key": r.get::<_, Option<String>>(15)?, "version_hint": r.get::<_, Option<String>>(16)?, "clean_hint": r.get::<_, Option<String>>(17)?,
            });
            let technical = serde_json::json!({
                "format": r.get::<_, Option<String>>(18)?, "codec": r.get::<_, Option<String>>(19)?, "lossless": r.get::<_, Option<i64>>(20)?.map(|v| v == 1),
                "duration_ms": r.get::<_, Option<i64>>(21)?, "bitrate_kbps": r.get::<_, Option<i64>>(22)?, "sample_rate": r.get::<_, Option<i64>>(23)?,
                "bit_depth": r.get::<_, Option<i64>>(24)?, "channels": r.get::<_, Option<i64>>(25)?, "file_size": r.get::<_, i64>(26)?,
                "file_mtime": r.get::<_, Option<i64>>(27)?, "path": r.get::<_, String>(28)?, "extension": r.get::<_, String>(29)?,
                "first_seen_at": r.get::<_, i64>(30)?, "last_seen_at": r.get::<_, i64>(31)?, "content_hash": r.get::<_, Option<String>>(32)?,
                "read_status": r.get::<_, String>(33)?, "presence": r.get::<_, String>(35)?, "low_bitrate_threshold_kbps": low,
            });
            Ok((file, technical, r.get::<_, Option<String>>(34)?))
        },
    )?;
    let mine = conn
        .query_row(
            "SELECT genre, year, bpm, musical_key, energy, rating, mood, color, notes, version_label, clean_explicit, updated_at, title, artist, album, original_year, record_label FROM track_user WHERE track_id=?1",
            params![id],
            |r| {
                Ok(serde_json::json!({
                    "genre": r.get::<_, Option<String>>(0)?, "year": r.get::<_, Option<i64>>(1)?, "bpm": r.get::<_, Option<f64>>(2)?,
                    "key": r.get::<_, Option<String>>(3)?, "energy": r.get::<_, Option<i64>>(4)?, "rating": r.get::<_, Option<i64>>(5)?,
                    "mood": r.get::<_, Option<String>>(6)?, "color": r.get::<_, Option<String>>(7)?, "notes": r.get::<_, Option<String>>(8)?,
                    "version_label": r.get::<_, Option<String>>(9)?, "clean_explicit": r.get::<_, Option<String>>(10)?, "updated_at": r.get::<_, i64>(11)?,
                    "title": r.get::<_, Option<String>>(12)?, "artist": r.get::<_, Option<String>>(13)?, "album": r.get::<_, Option<String>>(14)?,
                    "original_year": r.get::<_, Option<i64>>(15)?, "record_label": r.get::<_, Option<String>>(16)?,
                }))
            },
        )
        .optional()?
        .unwrap_or(serde_json::json!({}));
    let mut stmt = conn.prepare("SELECT c.id, c.name FROM crate_tracks ct JOIN crates c ON c.id=ct.crate_id WHERE ct.track_id=?1 AND ct.mode='include' ORDER BY c.name")?;
    let crates = stmt
        .query_map(params![id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let analysis = crate::analysis_store::get(conn, id)?;
    let plays: i64 = conn.query_row(
        "SELECT (SELECT COUNT(*) FROM play_history WHERE track_id=?1) + (SELECT COUNT(*) FROM gig_events WHERE track_id=?1 AND kind='played')",
        params![id],
        |r| r.get(0),
    )?;
    Ok(TrackDetail {
        row,
        file,
        mine,
        technical,
        crates,
        read_error,
        analysis,
        plays,
    })
}

/// Catalogue-only edits. `None` in a field leaves it unchanged; JSON null clears it.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct UserFieldsPatch {
    #[serde(default, with = "patch")]
    pub genre: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub year: Option<Option<i64>>,
    #[serde(default, with = "patch")]
    pub bpm: Option<Option<f64>>,
    #[serde(default, with = "patch")]
    pub key: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub energy: Option<Option<i64>>,
    #[serde(default, with = "patch")]
    pub rating: Option<Option<i64>>,
    #[serde(default, with = "patch")]
    pub mood: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub color: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub notes: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub version_label: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub clean_explicit: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub title: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub artist: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub album: Option<Option<String>>,
    #[serde(default, with = "patch")]
    pub original_year: Option<Option<i64>>,
    #[serde(default, with = "patch")]
    pub record_label: Option<Option<String>>,
}

mod patch {
    use serde::{Deserialize, Deserializer};
    pub fn deserialize<'de, D, T>(d: D) -> Result<Option<Option<T>>, D::Error>
    where
        D: Deserializer<'de>,
        T: Deserialize<'de>,
    {
        Ok(Some(Option::<T>::deserialize(d)?))
    }
}

pub const COLORS: &[&str] = &[
    "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "grey",
];

fn norm_text(v: &Option<String>, max: usize) -> Result<Option<String>> {
    match v {
        None => Ok(None),
        Some(s) => {
            let t = s.trim();
            if t.is_empty() {
                Ok(None)
            } else if t.chars().count() > max {
                invalid(format!("value is too long (max {max} characters)"))
            } else {
                Ok(Some(t.to_string()))
            }
        }
    }
}

pub fn update_user_fields(conn: &Connection, ids: &[i64], p: &UserFieldsPatch) -> Result<usize> {
    if ids.is_empty() || ids.len() > 100_000 {
        return invalid("select between 1 and 100000 tracks");
    }
    // Validate first so nothing is written on invalid input.
    if let Some(Some(e)) = p.energy {
        if !(1..=10).contains(&e) {
            return invalid("energy must be 1–10");
        }
    }
    if let Some(Some(r)) = p.rating {
        if !(0..=5).contains(&r) {
            return invalid("rating must be 0–5");
        }
    }
    if let Some(Some(y)) = p.year {
        if !(1000..=9999).contains(&y) {
            return invalid("year must be four digits");
        }
    }
    if let Some(Some(b)) = p.bpm {
        if !(b > 0.0 && b < 1000.0) {
            return invalid("BPM must be between 0 and 1000");
        }
    }
    if let Some(Some(c)) = &p.color {
        if !COLORS.contains(&c.as_str()) {
            return invalid("unknown colour");
        }
    }
    if let Some(Some(c)) = &p.clean_explicit {
        if c != "clean" && c != "explicit" {
            return invalid("clean/explicit must be 'clean' or 'explicit'");
        }
    }
    let genre = p.genre.as_ref().map(|v| norm_text(v, 120)).transpose()?;
    let key = p.key.as_ref().map(|v| norm_text(v, 12)).transpose()?;
    let mood = p.mood.as_ref().map(|v| norm_text(v, 80)).transpose()?;
    let notes = p.notes.as_ref().map(|v| norm_text(v, 4000)).transpose()?;
    let ver = p
        .version_label
        .as_ref()
        .map(|v| norm_text(v, 80))
        .transpose()?;
    if let Some(Some(y)) = p.original_year {
        if !(1000..=9999).contains(&y) {
            return invalid("original year must be four digits");
        }
    }
    let title = p.title.as_ref().map(|v| norm_text(v, 300)).transpose()?;
    let artist = p.artist.as_ref().map(|v| norm_text(v, 300)).transpose()?;
    let album = p.album.as_ref().map(|v| norm_text(v, 300)).transpose()?;
    let rlabel = p
        .record_label
        .as_ref()
        .map(|v| norm_text(v, 200))
        .transpose()?;

    let tx = conn.unchecked_transaction()?;
    let now = now_ms();
    let mut n = 0;
    {
        let mut ensure = tx.prepare_cached("INSERT OR IGNORE INTO track_user(track_id, updated_at) SELECT id, ?2 FROM tracks WHERE id=?1")?;
        for id in ids {
            ensure.execute(params![id, now])?;
        }
        macro_rules! set {
            ($col:literal, $val:expr) => {
                if let Some(v) = $val {
                    let mut st = tx.prepare_cached(concat!(
                        "UPDATE track_user SET ",
                        $col,
                        "=?1, updated_at=?2 WHERE track_id=?3"
                    ))?;
                    for id in ids {
                        n += st.execute(params![v, now, id])?;
                    }
                }
            };
        }
        set!("genre", &genre);
        set!("year", &p.year);
        set!("bpm", &p.bpm);
        set!("musical_key", &key);
        set!("energy", &p.energy);
        set!("rating", &p.rating);
        set!("mood", &mood);
        set!("color", &p.color);
        set!("notes", &notes);
        set!("version_label", &ver);
        set!("clean_explicit", &p.clean_explicit);
        set!("title", &title);
        set!("artist", &artist);
        set!("album", &album);
        set!("original_year", &p.original_year);
        set!("record_label", &rlabel);
    }
    tx.commit()?;
    Ok(n)
}

pub fn list_tags(conn: &Connection) -> Result<Vec<(String, i64)>> {
    let mut stmt = conn.prepare("SELECT g.name, COUNT(tt.track_id) FROM tags g LEFT JOIN track_tags tt ON tt.tag_id=g.id GROUP BY g.id ORDER BY g.name_fold")?;
    let v = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(v)
}

pub fn set_tags(conn: &Connection, ids: &[i64], add: &[String], remove: &[String]) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    for name in add {
        let n = name.trim();
        if n.is_empty() {
            continue;
        }
        if n.chars().count() > 60 {
            return invalid("tag is too long (max 60 characters)");
        }
        tx.execute(
            "INSERT OR IGNORE INTO tags(name, name_fold) VALUES (?1, ?2)",
            params![n, fold(n)],
        )?;
        let tag_id: i64 = tx.query_row(
            "SELECT id FROM tags WHERE name_fold=?1",
            params![fold(n)],
            |r| r.get(0),
        )?;
        let mut st = tx.prepare_cached("INSERT OR IGNORE INTO track_tags(track_id, tag_id) SELECT id, ?2 FROM tracks WHERE id=?1")?;
        for id in ids {
            st.execute(params![id, tag_id])?;
        }
    }
    for name in remove {
        let mut st = tx.prepare_cached("DELETE FROM track_tags WHERE track_id=?1 AND tag_id=(SELECT id FROM tags WHERE name_fold=?2)")?;
        for id in ids {
            st.execute(params![id, fold(name.trim())])?;
        }
    }
    tx.execute(
        "DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM track_tags)",
        [],
    )?;
    tx.commit()?;
    Ok(())
}

/// Distinct values for a facet, with counts (used by filter dropdowns).
pub fn facet(conn: &Connection, field: &str, limit: i64) -> Result<Vec<(String, i64)>> {
    let expr = match field {
        "genre" => "COALESCE(u.genre, t.genre)",
        "artist" => "COALESCE(u.artist, t.artist)",
        "format" => "t.format",
        "key" => "keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))",
        "mood" => "u.mood",
        "label" => "COALESCE(u.record_label, t.label)",
        "decade" => "CAST((COALESCE(u.year, t.year)/10)*10 AS TEXT)",
        "version" => "COALESCE(u.version_label, t.version_hint)",
        _ => return invalid("unknown facet"),
    };
    let sql = format!("SELECT {expr} AS v, COUNT(*) {FROM} WHERE t.presence='present' AND v IS NOT NULL AND v <> '' GROUP BY fold(v) ORDER BY COUNT(*) DESC LIMIT ?1");
    let mut stmt = conn.prepare(&sql)?;
    let v = stmt
        .query_map(params![limit.clamp(1, 1000)], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(v)
}

#[derive(Debug, Clone, Serialize)]
pub struct Stats {
    pub tracks: i64,
    pub missing: i64,
    pub offline: i64,
    pub errors: i64,
    pub unsupported: i64,
    pub low_bitrate: i64,
    pub lossless: i64,
    pub total_bytes: i64,
    pub total_duration_ms: i64,
    pub roots: i64,
    pub crates: i64,
}

pub fn stats(conn: &Connection) -> Result<Stats> {
    let low = db::low_bitrate_threshold(conn)?;
    let s = conn.query_row(
        &format!(
            "SELECT
              SUM(t.presence='present'),
              SUM(t.presence='missing'),
              SUM(t.presence='present' AND r.status='offline'),
              SUM(t.presence='present' AND t.read_status='error'),
              SUM(t.presence='present' AND t.read_status='unsupported'),
              SUM(t.presence='present' AND t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < {low}),
              SUM(t.presence='present' AND t.lossless=1),
              SUM(CASE WHEN t.presence='present' THEN t.file_size ELSE 0 END),
              SUM(CASE WHEN t.presence='present' THEN COALESCE(t.duration_ms,0) ELSE 0 END)
             FROM tracks t LEFT JOIN library_roots r ON r.id=t.root_id"
        ),
        [],
        |r| {
            Ok(Stats {
                tracks: r.get::<_, Option<i64>>(0)?.unwrap_or(0),
                missing: r.get::<_, Option<i64>>(1)?.unwrap_or(0),
                offline: r.get::<_, Option<i64>>(2)?.unwrap_or(0),
                errors: r.get::<_, Option<i64>>(3)?.unwrap_or(0),
                unsupported: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
                low_bitrate: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                lossless: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
                total_bytes: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
                total_duration_ms: r.get::<_, Option<i64>>(8)?.unwrap_or(0),
                roots: 0,
                crates: 0,
            })
        },
    )?;
    let roots: i64 = conn.query_row("SELECT COUNT(*) FROM library_roots", [], |r| r.get(0))?;
    let crates: i64 = conn.query_row("SELECT COUNT(*) FROM crates", [], |r| r.get(0))?;
    Ok(Stats { roots, crates, ..s })
}
