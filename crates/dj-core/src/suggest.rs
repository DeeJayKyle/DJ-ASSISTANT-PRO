//! Metadata suggestions. Three kinds of value are always kept apart:
//! the file's own tags (tracks), the DJ's catalogue values (track_user) and
//! suggestions (this table). Accepting a suggestion only writes track_user.
use crate::db::now_ms;
use crate::error::{invalid, Error, Result};
use crate::library::{self, UserFieldsPatch};
use crate::online::{CatalogMatch, MbRecording, Online, Secrets};
use crate::text::{base_artist, base_title, fold};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::collections::HashMap;

pub const FIELDS: &[&str] = &[
    "title",
    "artist",
    "album",
    "genre",
    "year",
    "original_year",
    "bpm",
    "key",
    "version_label",
    "record_label",
];

#[allow(clippy::too_many_arguments)]
pub fn insert(
    conn: &Connection,
    track_id: i64,
    field: &str,
    current: Option<&str>,
    value: &str,
    source: &str,
    evidence: &str,
    confidence: f64,
) -> Result<()> {
    if !FIELDS.contains(&field) || value.trim().is_empty() {
        return Ok(());
    }
    if current
        .map(|c| fold(c.trim()) == fold(value.trim()))
        .unwrap_or(false)
    {
        return Ok(());
    }
    conn.execute(
        "INSERT INTO suggestions (track_id, field, current_value, suggested_value, source, evidence, confidence, status, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,'pending',?8)
         ON CONFLICT(track_id, field, suggested_value, source) DO UPDATE SET current_value=excluded.current_value, evidence=excluded.evidence, confidence=excluded.confidence",
        params![track_id, field, current, value.trim(), source, evidence, confidence.clamp(0.0, 1.0), now_ms()],
    )?;
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
pub struct Suggestion {
    pub id: i64,
    pub track_id: i64,
    pub track: String,
    pub field: String,
    pub current_value: Option<String>,
    pub suggested_value: String,
    pub source: String,
    pub evidence: Option<String>,
    pub confidence: Option<f64>,
    pub status: String,
    pub created_at: i64,
}

pub fn list(
    conn: &Connection,
    status: Option<&str>,
    track_id: Option<i64>,
    limit: i64,
) -> Result<Vec<Suggestion>> {
    let mut stmt = conn.prepare(
        "SELECT s.id, s.track_id, COALESCE(COALESCE(u.artist, t.artist) || ' — ', '') || COALESCE(u.title, t.title, t.file_name), s.field, s.current_value,
                s.suggested_value, s.source, s.evidence, s.confidence, s.status, s.created_at
         FROM suggestions s JOIN tracks t ON t.id=s.track_id LEFT JOIN track_user u ON u.track_id=t.id
         WHERE (?1 IS NULL OR s.status=?1) AND (?2 IS NULL OR s.track_id=?2)
         ORDER BY s.status='pending' DESC, s.confidence DESC, s.id LIMIT ?3",
    )?;
    let v = stmt
        .query_map(params![status, track_id, limit.clamp(1, 5000)], |r| {
            Ok(Suggestion {
                id: r.get(0)?,
                track_id: r.get(1)?,
                track: r.get(2)?,
                field: r.get(3)?,
                current_value: r.get(4)?,
                suggested_value: r.get(5)?,
                source: r.get(6)?,
                evidence: r.get(7)?,
                confidence: r.get(8)?,
                status: r.get(9)?,
                created_at: r.get(10)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(v)
}

pub fn counts(conn: &Connection) -> Result<serde_json::Value> {
    let mut stmt = conn.prepare("SELECT status, COUNT(*) FROM suggestions GROUP BY status")?;
    let mut m = serde_json::Map::new();
    for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
        let (k, v) = row?;
        m.insert(k, v.into());
    }
    Ok(serde_json::Value::Object(m))
}

/// Accept a suggestion (optionally with an edited value) into the catalogue.
pub fn accept(conn: &Connection, id: i64, edited: Option<&str>) -> Result<()> {
    let (track_id, field, value): (i64, String, String) = conn
        .query_row(
            "SELECT track_id, field, suggested_value FROM suggestions WHERE id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("suggestion".into()))?;
    let v = edited.map(|s| s.trim().to_string()).unwrap_or(value);
    if v.is_empty() {
        return invalid("value is empty");
    }
    let mut p = UserFieldsPatch::default();
    let num = |s: &str| {
        s.parse::<f64>()
            .map_err(|_| Error::Invalid(format!("'{s}' is not a number")))
    };
    match field.as_str() {
        "title" => p.title = Some(Some(v)),
        "artist" => p.artist = Some(Some(v)),
        "album" => p.album = Some(Some(v)),
        "genre" => p.genre = Some(Some(v)),
        "year" => p.year = Some(Some(num(&v)? as i64)),
        "original_year" => p.original_year = Some(Some(num(&v)? as i64)),
        "bpm" => p.bpm = Some(Some(num(&v)?)),
        "key" => p.key = Some(Some(v)),
        "version_label" => p.version_label = Some(Some(v)),
        "record_label" => p.record_label = Some(Some(v)),
        _ => return invalid("unknown field"),
    }
    library::update_user_fields(conn, &[track_id], &p)?;
    conn.execute(
        "UPDATE suggestions SET status='accepted', decided_at=?2 WHERE id=?1",
        params![id, now_ms()],
    )?;
    // Other pending suggestions for the same field are now superseded.
    conn.execute(
        "UPDATE suggestions SET status='rejected', decided_at=?3 WHERE track_id=?1 AND field=?2 AND status='pending' AND id<>?4",
        params![track_id, field, now_ms(), id],
    )?;
    Ok(())
}

pub fn reject(conn: &Connection, id: i64) -> Result<()> {
    let n = conn.execute(
        "UPDATE suggestions SET status='rejected', decided_at=?2 WHERE id=?1",
        params![id, now_ms()],
    )?;
    if n == 0 {
        return Err(Error::NotFound("suggestion".into()));
    }
    Ok(())
}

pub fn reset(conn: &Connection, id: i64) -> Result<()> {
    conn.execute(
        "UPDATE suggestions SET status='pending', decided_at=NULL WHERE id=?1",
        params![id],
    )?;
    Ok(())
}

fn strip_track_number(s: &str) -> &str {
    let t = s.trim_start();
    let digits = t.chars().take_while(|c| c.is_ascii_digit()).count();
    if (1..=3).contains(&digits) {
        let rest = &t[digits..];
        let rest = rest.trim_start_matches(['.', ')', '-', '_', ' ']);
        if !rest.is_empty() && rest.len() < t.len() {
            return rest;
        }
    }
    t
}

/// Parse "Artist - Title (Version)" style file names.
pub fn parse_filename(stem: &str) -> Option<(String, String)> {
    let cleaned = stem.replace('_', " ");
    let s = strip_track_number(&cleaned);
    for sep in [" - ", " – ", " — "] {
        if let Some((a, t)) = s.split_once(sep) {
            let (a, t) = (a.trim(), t.trim());
            if !a.is_empty() && !t.is_empty() {
                return Some((a.to_string(), t.to_string()));
            }
        }
    }
    None
}

pub(crate) fn year_in(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    for i in 0..b.len().saturating_sub(5) {
        if (b[i] == b'(' || b[i] == b'[')
            && b[i + 1..i + 5].iter().all(|c| c.is_ascii_digit())
            && (b[i + 5] == b')' || b[i + 5] == b']')
        {
            let y: i64 = s[i + 1..i + 5].parse().ok()?;
            if (1900..=2100).contains(&y) {
                return Some(y);
            }
        }
    }
    None
}

const KNOWN_GENRES: &[&str] = &[
    "afrobeats",
    "afrobeat",
    "afro house",
    "amapiano",
    "house",
    "deep house",
    "tech house",
    "techno",
    "hip hop",
    "hip-hop",
    "rap",
    "r&b",
    "rnb",
    "pop",
    "dancehall",
    "reggae",
    "reggaeton",
    "latin",
    "soca",
    "gospel",
    "jazz",
    "soul",
    "funk",
    "disco",
    "drum & bass",
    "dnb",
    "dubstep",
    "trap",
    "edm",
    "garage",
    "uk garage",
    "kwaito",
    "gqom",
    "bongo flava",
    "zouk",
    "kizomba",
    "rock",
    "country",
    "ambient",
    "lounge",
    "throwbacks",
    "open format",
];

/// Local, offline suggestions: file-name parsing, folder genres, years in
/// names and consistent spellings. Returns how many were created or updated.
pub fn generate_local(conn: &Connection) -> Result<usize> {
    let before: i64 = conn.query_row("SELECT COUNT(*) FROM suggestions", [], |r| r.get(0))?;
    struct Row {
        id: i64,
        title: Option<String>,
        artist: Option<String>,
        genre: Option<String>,
        year: Option<i64>,
        file_name: String,
        rel: String,
    }
    let mut stmt = conn.prepare(
        "SELECT t.id, COALESCE(u.title, t.title), COALESCE(u.artist, t.artist), COALESCE(u.genre, t.genre), COALESCE(u.year, t.year), t.file_name, t.rel_path
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok'",
    )?;
    let rows: Vec<Row> = stmt
        .query_map([], |r| {
            Ok(Row {
                id: r.get(0)?,
                title: r.get(1)?,
                artist: r.get(2)?,
                genre: r.get(3)?,
                year: r.get(4)?,
                file_name: r.get(5)?,
                rel: r.get(6)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?;

    // Most common spelling per folded artist / genre.
    let mut artist_forms: HashMap<String, HashMap<String, i64>> = HashMap::new();
    let mut genre_forms: HashMap<String, HashMap<String, i64>> = HashMap::new();
    for r in &rows {
        if let Some(a) = &r.artist {
            *artist_forms
                .entry(
                    fold(a.trim())
                        .split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" "),
                )
                .or_default()
                .entry(a.trim().to_string())
                .or_default() += 1;
        }
        if let Some(g) = &r.genre {
            let k: String = fold(g).chars().filter(|c| c.is_alphanumeric()).collect();
            *genre_forms
                .entry(k)
                .or_default()
                .entry(g.trim().to_string())
                .or_default() += 1;
        }
    }
    let best = |m: &HashMap<String, i64>| -> Option<(String, i64)> {
        m.iter()
            .max_by_key(|(k, v)| (**v, k.len() as i64))
            .map(|(k, v)| (k.clone(), *v))
    };

    for r in &rows {
        let stem = r
            .file_name
            .rsplit_once('.')
            .map(|x| x.0)
            .unwrap_or(&r.file_name);
        let parsed = parse_filename(stem);
        if let Some((a, t)) = &parsed {
            if r.artist.is_none() {
                insert(
                    conn,
                    r.id,
                    "artist",
                    None,
                    a,
                    "File name",
                    &format!("Parsed from the file name \"{}\".", r.file_name),
                    0.6,
                )?;
            }
            if r.title.is_none() {
                insert(
                    conn,
                    r.id,
                    "title",
                    None,
                    t,
                    "File name",
                    &format!("Parsed from the file name \"{}\".", r.file_name),
                    0.6,
                )?;
            }
        } else if r.title.is_none() {
            insert(
                conn,
                r.id,
                "title",
                None,
                strip_track_number(stem).trim(),
                "File name",
                "Taken from the file name.",
                0.4,
            )?;
        }
        if r.year.is_none() {
            if let Some(y) = year_in(&r.file_name).or_else(|| year_in(&r.rel)) {
                insert(
                    conn,
                    r.id,
                    "year",
                    None,
                    &y.to_string(),
                    "File name",
                    "A year in brackets appears in the file or folder name.",
                    0.45,
                )?;
            }
        }
        if r.genre.is_none() {
            let folders: Vec<&str> = r.rel.split(['/', '\\']).collect();
            for f in folders.iter().rev().skip(1) {
                let ff = fold(f.trim());
                if KNOWN_GENRES.contains(&ff.as_str()) {
                    insert(
                        conn,
                        r.id,
                        "genre",
                        None,
                        f.trim(),
                        "Folder name",
                        &format!("The file is in a folder called \"{}\".", f.trim()),
                        0.4,
                    )?;
                    break;
                }
            }
        }
        if let Some(a) = &r.artist {
            let k = fold(a.trim())
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            if let Some((b, n)) = artist_forms.get(&k).and_then(best) {
                if b != a.trim() && n >= 2 {
                    insert(
                        conn,
                        r.id,
                        "artist",
                        Some(a),
                        &b,
                        "Library consistency",
                        &format!("\"{b}\" is how this artist is written on {n} other tracks."),
                        0.55,
                    )?;
                }
            }
        }
        if let Some(g) = &r.genre {
            let k: String = fold(g).chars().filter(|c| c.is_alphanumeric()).collect();
            if let Some((b, n)) = genre_forms.get(&k).and_then(best) {
                if b != g.trim() && n >= 2 {
                    insert(
                        conn,
                        r.id,
                        "genre",
                        Some(g),
                        &b,
                        "Library consistency",
                        &format!("\"{b}\" is the spelling used on {n} other tracks."),
                        0.5,
                    )?;
                }
            }
        }
    }
    let after: i64 = conn.query_row("SELECT COUNT(*) FROM suggestions", [], |r| r.get(0))?;
    Ok((after - before).max(0) as usize)
}

fn year_of(date: &Option<String>) -> Option<i64> {
    date.as_deref()
        .and_then(|d| d.get(..4))
        .and_then(|y| y.parse().ok())
        .filter(|y: &i64| (1000..=9999).contains(y))
}

/// Pick the MusicBrainz result that best matches and record suggestions.
pub fn apply_musicbrainz(conn: &Connection, track_id: i64, recs: &[MbRecording]) -> Result<usize> {
    let (title, artist, album, genre, year, orig, dur): (Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>, Option<i64>, Option<i64>) = conn.query_row(
        "SELECT COALESCE(u.title,t.title), COALESCE(u.artist,t.artist), COALESCE(u.album,t.album), COALESCE(u.genre,t.genre), COALESCE(u.year,t.year), COALESCE(u.original_year,t.original_year), t.duration_ms
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?1",
        params![track_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
    )?;
    let want_t = title.as_deref().map(base_title).unwrap_or_default();
    let want_a = artist.as_deref().map(base_artist).unwrap_or_default();
    let mut n = 0;
    for r in recs.iter().filter(|r| r.score >= 80.0).take(3) {
        let same_work = base_title(&r.title) == want_t && base_artist(&r.artist) == want_a;
        let dur_note = match (dur, r.length_ms) {
            (Some(a), Some(b)) => {
                let d = (a - b).abs() / 1000;
                if d > 15 {
                    format!(" Length differs by {d} s, so this may be a different version.")
                } else {
                    format!(" Length matches within {d} s.")
                }
            }
            _ => String::new(),
        };
        let ev = |what: &str| {
            format!(
                "MusicBrainz recording \"{}\" by {}{} (search score {:.0}). {what}{dur_note}",
                r.title,
                r.artist,
                r.disambiguation
                    .as_deref()
                    .map(|d| format!(" [{d}]"))
                    .unwrap_or_default(),
                r.score
            )
        };
        let conf = (r.score / 100.0) * if same_work { 0.9 } else { 0.6 };
        if let Some(y) = year_of(&r.first_release_date) {
            insert(conn, track_id, "original_year", orig.map(|v| v.to_string()).as_deref(), &y.to_string(), "MusicBrainz", &ev("Earliest release date of this recording (original release year, not a reissue or remix year)."), conf)?;
            n += 1;
            if year.is_none() {
                insert(
                    conn,
                    track_id,
                    "year",
                    None,
                    &y.to_string(),
                    "MusicBrainz",
                    &ev("Your file has no year; this is the earliest release year."),
                    conf * 0.9,
                )?;
            }
        }
        if !same_work || title.is_none() {
            insert(
                conn,
                track_id,
                "title",
                title.as_deref(),
                &r.title,
                "MusicBrainz",
                &ev("Title as listed on MusicBrainz."),
                conf,
            )?;
            insert(
                conn,
                track_id,
                "artist",
                artist.as_deref(),
                &r.artist,
                "MusicBrainz",
                &ev("Artist credit as listed on MusicBrainz."),
                conf,
            )?;
            n += 2;
        }
        if let Some(rt) = &r.release_title {
            if album.is_none() {
                insert(
                    conn,
                    track_id,
                    "album",
                    None,
                    rt,
                    "MusicBrainz",
                    &ev("Release this recording appears on."),
                    conf * 0.8,
                )?;
                n += 1;
            }
        }
        if let Some(l) = &r.label {
            insert(
                conn,
                track_id,
                "record_label",
                None,
                l,
                "MusicBrainz",
                &ev("Label of that release."),
                conf * 0.8,
            )?;
            n += 1;
        }
        if genre.is_none() {
            if let Some(g) = r.tags.first() {
                insert(
                    conn,
                    track_id,
                    "genre",
                    None,
                    g,
                    "MusicBrainz",
                    &ev("Most-used community tag for this recording."),
                    conf * 0.6,
                )?;
                n += 1;
            }
        }
    }
    Ok(n)
}

pub fn service_enabled(conn: &Connection, svc: &str) -> Result<bool> {
    Ok(crate::db::get_setting(conn, &format!("svc_{svc}"))?
        .map(|v| v == "1")
        .unwrap_or(false))
}

pub fn require_service(conn: &Connection, svc: &str) -> Result<()> {
    if !service_enabled(conn, svc)? {
        return invalid(format!(
            "{svc} is turned off. Turn it on in Settings → Online services first."
        ));
    }
    Ok(())
}

/// Look up tracks on MusicBrainz (rate-limited to one request per second).
pub fn musicbrainz_lookup(
    conn: &Connection,
    online: &dyn Online,
    ids: &[i64],
    ctl: &crate::scanner::ScanControl,
    p: &crate::jobs::Progress,
) -> Result<()> {
    require_service(conn, "musicbrainz")?;
    crate::jobs::set_total(p, ids.len() as u64);
    for id in ids {
        if crate::jobs::wait_or_cancelled(ctl) {
            break;
        }
        let (a, t): (Option<String>, Option<String>) = conn.query_row(
            "SELECT COALESCE(u.artist,t.artist), COALESCE(u.title,t.title) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let (Some(a), Some(t)) = (a, t) else {
            crate::jobs::tick(p, false);
            continue;
        };
        let started = std::time::Instant::now();
        match online.musicbrainz_recordings(&a, &t) {
            Ok(recs) => {
                apply_musicbrainz(conn, *id, &recs)?;
                crate::jobs::tick(p, true);
            }
            Err(e) => {
                crate::jobs::message(p, e);
                crate::jobs::tick(p, false);
            }
        }
        let el = started.elapsed();
        if el < std::time::Duration::from_millis(1100) {
            std::thread::sleep(std::time::Duration::from_millis(1100) - el);
        }
    }
    Ok(())
}

/// The catalogue BPM for this file, corrected for the half/double-time confusion
/// that BPM detectors (and catalogues) make, and whether the audio analysis agrees.
/// Returns (bpm to suggest, agrees with the analysis).
pub fn catalog_bpm(catalog: f64, analysed: Option<f64>) -> Option<(f64, bool)> {
    if !(40.0..=250.0).contains(&catalog) {
        return None;
    }
    let tidy = |b: f64| {
        let r = b.round();
        if (b - r).abs() < 0.15 {
            r
        } else {
            (b * 100.0).round() / 100.0
        }
    };
    let Some(a) = analysed.filter(|a| *a > 0.0) else {
        return Some((tidy(catalog), false));
    };
    for f in [1.0, 2.0, 0.5] {
        let c = catalog * f;
        if (c - a).abs() / a <= 0.03 {
            // the audio says this tempo: take the catalogue's exact figure at the audio's octave
            return Some((tidy(c), true));
        }
    }
    Some((tidy(catalog), false))
}

fn norm_genre(g: &str) -> String {
    g.trim()
        .to_ascii_lowercase()
        .replace(['-', '/', '&'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Record suggestions from catalogue matches of the same recording (same title and
/// artist, length within 10 s). Values both catalogues agree on get high confidence,
/// so auto-prep can correct them; a single source only fills empty fields.
pub fn apply_catalog(conn: &Connection, track_id: i64, found: &[CatalogMatch]) -> Result<usize> {
    #[allow(clippy::type_complexity)]
    let (title, artist, genre, year, bpm, analysed, label, dur): (Option<String>, Option<String>, Option<String>, Option<i64>, Option<f64>, Option<f64>, Option<String>, Option<i64>) = conn.query_row(
        "SELECT COALESCE(u.title,t.title), COALESCE(u.artist,t.artist), COALESCE(u.genre,t.genre), COALESCE(u.year,t.year),
                COALESCE(u.bpm,t.bpm_tag,a.bpm), a.bpm, COALESCE(u.record_label,t.label), t.duration_ms
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
        params![track_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?)),
    )?;
    let (Some(title), Some(artist)) = (title, artist) else {
        return Ok(0);
    };
    let (want_t, want_a) = (base_title(&title), base_artist(&artist));
    // Best match per catalogue: the same recording, and the same length when known.
    let mut best: Vec<(&CatalogMatch, f64)> = vec![];
    // closest in length first, so a remix or radio edit of the same title loses to the real match
    let mut found: Vec<&CatalogMatch> = found.iter().collect();
    found.sort_by_key(|m| match (dur, m.duration_ms) {
        (Some(a), Some(b)) => (a - b).abs(),
        _ => i64::MAX / 2,
    });
    for m in found {
        if base_title(&m.title) != want_t || base_artist(&m.artist) != want_a {
            continue;
        }
        let fit = match (dur, m.duration_ms) {
            (Some(a), Some(b)) if (a - b).abs() > 10_000 => continue, // another version
            (Some(a), Some(b)) if (a - b).abs() <= 3_000 => 1.0,
            (Some(_), Some(_)) => 0.92,
            _ => 0.85,
        };
        if !best.iter().any(|(b, _)| b.source == m.source) {
            best.push((m, fit));
        }
    }
    if best.is_empty() {
        return Ok(0);
    }
    let sources = best
        .iter()
        .map(|(m, _)| m.source.as_str())
        .collect::<Vec<_>>()
        .join(" and ");
    let fit = best.iter().map(|(_, f)| *f).fold(0.0, f64::max);
    let mut n = 0;

    // BPM (Deezer lists it): checked against the audio analysis.
    if let Some((m, f)) = best.iter().find(|(m, _)| m.bpm.is_some_and(|b| b > 0.0)) {
        if let Some((value, agrees)) = catalog_bpm(m.bpm.unwrap_or(0.0), analysed) {
            if bpm.is_none_or(|b| (b - value).abs() > 0.4) {
                let ev = if agrees {
                    format!("{} lists \"{}\" by {} at {} BPM, and this file's audio analysis agrees ({:.1} BPM measured), so this is the exact tempo.", m.source, m.title, m.artist, m.bpm.unwrap_or(0.0), analysed.unwrap_or(0.0))
                } else if let Some(a) = analysed {
                    format!("{} lists {} BPM, but the audio analysis measured {a:.1} BPM. Check by ear before accepting.", m.source, m.bpm.unwrap_or(0.0))
                } else {
                    format!(
                        "{} lists \"{}\" by {} at {} BPM. The file hasn't been analysed yet.",
                        m.source,
                        m.title,
                        m.artist,
                        m.bpm.unwrap_or(0.0)
                    )
                };
                let conf = if agrees {
                    0.93
                } else if analysed.is_some() {
                    0.45
                } else {
                    0.7
                } * f;
                insert(
                    conn,
                    track_id,
                    "bpm",
                    bpm.map(|b| format!("{b}")).as_deref(),
                    &format!("{value}"),
                    m.source.as_str(),
                    &ev,
                    conf,
                )?;
                n += 1;
            }
        }
    }

    // Release year: the earliest the catalogues list (reissues and compilations are later).
    let years: Vec<(i64, &str)> = best
        .iter()
        .filter_map(|(m, _)| year_of(&m.release_date).map(|y| (y, m.source.as_str())))
        .collect();
    if let Some(&(y, src)) = years.iter().min_by_key(|(y, _)| *y) {
        let agree = years.len() >= 2 && years.iter().all(|(v, _)| *v == y);
        if year != Some(y) {
            let ev = if agree {
                format!("{sources} both list this recording as released in {y}.")
            } else {
                format!("{src} lists this recording as released in {y}; other sources may differ (reissues and compilations show later years).")
            };
            let conf = if agree { 0.9 } else { 0.62 } * fit;
            insert(
                conn,
                track_id,
                "year",
                year.map(|v| v.to_string()).as_deref(),
                &y.to_string(),
                if agree { "Deezer + Apple Music" } else { src },
                &ev,
                conf,
            )?;
            n += 1;
        }
    }

    // Genre: Apple Music's is the more specific; agreement makes it certain.
    let apple = best
        .iter()
        .find(|(m, _)| m.source == "Apple Music")
        .and_then(|(m, _)| m.genres.first());
    let deezer: Vec<&String> = best
        .iter()
        .filter(|(m, _)| m.source == "Deezer")
        .filter_map(|(m, _)| m.genres.first()) // the primary genre; the rest is a long list
        .collect();
    let pick = apple.or(deezer.first().copied());
    if let Some(g) = pick.filter(|g| {
        !g.trim().is_empty() && !["music", "other", "unknown"].contains(&norm_genre(g).as_str())
    }) {
        let agree = apple.is_some() && deezer.iter().any(|d| norm_genre(d) == norm_genre(g));
        if genre
            .as_deref()
            .is_none_or(|cur| norm_genre(cur) != norm_genre(g))
        {
            let ev = if agree {
                format!("Apple Music and Deezer both file this recording under {g}.")
            } else {
                format!(
                    "{} files this recording under {g}.",
                    if apple.is_some() {
                        "Apple Music"
                    } else {
                        "Deezer"
                    }
                )
            };
            // Catalogue genres are broad ("Pop"), so a genre the DJ already has is
            // only ever suggested for review, never replaced automatically.
            let conf = if genre.is_some() {
                0.7
            } else if agree {
                0.88
            } else {
                0.6
            } * fit;
            insert(
                conn,
                track_id,
                "genre",
                genre.as_deref(),
                g,
                if agree {
                    "Deezer + Apple Music"
                } else if apple.is_some() {
                    "Apple Music"
                } else {
                    "Deezer"
                },
                &ev,
                conf,
            )?;
            n += 1;
        }
    }

    // Record label (Deezer): fills an empty field only.
    if label.is_none() {
        if let Some((m, f)) = best
            .iter()
            .find(|(m, _)| m.label.as_deref().is_some_and(|l| !l.trim().is_empty()))
        {
            let l = m.label.as_deref().unwrap_or_default();
            insert(
                conn,
                track_id,
                "record_label",
                None,
                l,
                m.source.as_str(),
                &format!("{} lists the label of this release as {l}.", m.source),
                0.7 * f,
            )?;
            n += 1;
        }
    }
    Ok(n)
}

/// Look tracks up in the Deezer and Apple Music catalogues and record suggestions.
pub fn catalog_lookup(
    conn: &Connection,
    online: &dyn Online,
    ids: &[i64],
    ctl: &crate::scanner::ScanControl,
    p: &crate::jobs::Progress,
) -> Result<usize> {
    require_service(conn, "catalogs")?;
    crate::jobs::set_total(p, ids.len() as u64);
    let mut n = 0;
    for id in ids {
        if crate::jobs::wait_or_cancelled(ctl) {
            break;
        }
        let (a, t): (Option<String>, Option<String>) = conn.query_row(
            "SELECT COALESCE(u.artist,t.artist), COALESCE(u.title,t.title) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let (Some(a), Some(t)) = (a, t) else {
            crate::jobs::tick(p, false);
            continue;
        };
        match online.catalog_lookup(&a, &t) {
            Ok(found) => {
                n += apply_catalog(conn, *id, &found)?;
                conn.execute(
                    "INSERT INTO catalog_checked(track_id, checked_at) VALUES (?1, ?2)
                     ON CONFLICT(track_id) DO UPDATE SET checked_at=excluded.checked_at",
                    params![id, now_ms()],
                )?;
                crate::jobs::tick(p, true);
            }
            Err(e) => {
                crate::jobs::message(p, e);
                crate::jobs::tick(p, false);
            }
        }
    }
    Ok(n)
}

/// Fingerprint lookup. The UI must have asked the DJ before calling this.
pub fn acoustid_lookup(
    conn: &Connection,
    online: &dyn Online,
    secrets: &dyn Secrets,
    ids: &[i64],
    ctl: &crate::scanner::ScanControl,
    p: &crate::jobs::Progress,
) -> Result<()> {
    require_service(conn, "acoustid")?;
    let key = secrets.get("acoustid").ok_or_else(|| {
        Error::Invalid("Add your AcoustID application key in Settings first.".into())
    })?;
    crate::jobs::set_total(p, ids.len() as u64);
    for id in ids {
        if crate::jobs::wait_or_cancelled(ctl) {
            break;
        }
        let fp: Option<(String, i64)> = conn
            .query_row("SELECT fingerprint_encoded, duration_ms FROM analysis WHERE track_id=?1 AND fingerprint_encoded IS NOT NULL", params![id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        let Some((fp, dur)) = fp else {
            crate::jobs::message(p, "Some tracks have not been analysed yet; analyse them first to create a fingerprint.");
            crate::jobs::tick(p, false);
            continue;
        };
        let started = std::time::Instant::now();
        match online.acoustid_lookup(&key, (dur / 1000) as u32, &fp) {
            Ok(matches) => {
                let (title, artist): (Option<String>, Option<String>) =
                    conn.query_row("SELECT COALESCE(u.title,t.title), COALESCE(u.artist,t.artist) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?1", params![id], |r| Ok((r.get(0)?, r.get(1)?)))?;
                for m in matches.iter().filter(|m| m.score >= 0.5).take(2) {
                    let ev = format!(
                        "Audio fingerprint matched AcoustID recording {} with score {:.2}. A fingerprint match is a candidate, not proof of the exact version or release.",
                        m.recording_mbid, m.score
                    );
                    if let Some(t) = &m.title {
                        insert(
                            conn,
                            *id,
                            "title",
                            title.as_deref(),
                            t,
                            "AcoustID",
                            &ev,
                            m.score * 0.8,
                        )?;
                    }
                    if let Some(a) = &m.artist {
                        insert(
                            conn,
                            *id,
                            "artist",
                            artist.as_deref(),
                            a,
                            "AcoustID",
                            &ev,
                            m.score * 0.8,
                        )?;
                    }
                    if let Some(y) = m.first_year {
                        insert(
                            conn,
                            *id,
                            "original_year",
                            None,
                            &y.to_string(),
                            "AcoustID",
                            &ev,
                            m.score * 0.6,
                        )?;
                    }
                }
                crate::jobs::tick(p, true);
            }
            Err(e) => {
                crate::jobs::message(p, e);
                crate::jobs::tick(p, false);
            }
        }
        let el = started.elapsed();
        if el < std::time::Duration::from_millis(350) {
            std::thread::sleep(std::time::Duration::from_millis(350) - el);
        }
    }
    Ok(())
}

/// Accept the best pending suggestion per track and field at or above `min` confidence.
pub fn accept_bulk(conn: &Connection, min: f64, source: Option<&str>) -> Result<usize> {
    let list = list(conn, Some("pending"), None, 50_000)?;
    let mut n = 0;
    for s in list.iter().filter(|s| {
        s.confidence.unwrap_or(0.0) >= min && source.map(|x| x == s.source).unwrap_or(true)
    }) {
        let still: bool = conn.query_row(
            "SELECT status='pending' FROM suggestions WHERE id=?1",
            params![s.id],
            |r| r.get(0),
        )?;
        if still && accept(conn, s.id, None).is_ok() {
            n += 1;
        }
    }
    Ok(n)
}

/// The fields auto-prep may fill in the catalogue.
const AUTO_FIELDS: &[&str] = &[
    "bpm",
    "title",
    "artist",
    "album",
    "genre",
    "year",
    "original_year",
    "record_label",
    "version_label",
];

/// Recommended fixes: fill empty fields from the best suggestion at or above
/// `min_fill`; replace an existing value only at or above `min_replace`.
/// Suggestions are taken best-first, so only the strongest one per track and
/// field is applied (the others are marked superseded by `accept`).
pub fn accept_recommended(conn: &Connection, min_fill: f64, min_replace: f64) -> Result<usize> {
    let list = list(conn, Some("pending"), None, 50_000)?;
    let mut n = 0;
    for s in list
        .iter()
        .filter(|s| AUTO_FIELDS.contains(&s.field.as_str()))
    {
        let c = s.confidence.unwrap_or(0.0);
        let empty = s
            .current_value
            .as_deref()
            .map(|v| v.trim().is_empty())
            .unwrap_or(true);
        if c < if empty { min_fill } else { min_replace } {
            continue;
        }
        let still: bool = conn.query_row(
            "SELECT status='pending' FROM suggestions WHERE id=?1",
            params![s.id],
            |r| r.get(0),
        )?;
        if still && accept(conn, s.id, None).is_ok() {
            n += 1;
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn catalogue_bpm_is_checked_against_the_audio() {
        // agrees: the catalogue's exact figure is used
        assert_eq!(catalog_bpm(124.0, Some(123.7)), Some((124.0, true)));
        // the analysis found half time: the catalogue tempo at the audio's octave is kept
        assert_eq!(catalog_bpm(128.0, Some(64.1)), Some((64.0, true)));
        // and double time
        assert_eq!(catalog_bpm(87.0, Some(174.2)), Some((174.0, true)));
        // disagreement is flagged, not trusted
        assert_eq!(catalog_bpm(140.0, Some(124.0)), Some((140.0, false)));
        assert_eq!(catalog_bpm(122.46, None), Some((122.46, false)));
        assert_eq!(catalog_bpm(0.0, Some(120.0)), None);
    }
    #[test]
    fn parses_file_names() {
        assert_eq!(
            parse_filename("01 - Wizkid - Essence"),
            Some(("Wizkid".into(), "Essence".into()))
        );
        assert_eq!(
            parse_filename("03. Rema - Calm Down (Extended)"),
            Some(("Rema".into(), "Calm Down (Extended)".into()))
        );
        assert_eq!(
            parse_filename("Fik_Fameica - Darling"),
            Some(("Fik Fameica".into(), "Darling".into()))
        );
        assert_eq!(parse_filename("untagged recording"), None);
        assert_eq!(year_in("Darling (2019).mp3"), Some(2019));
        assert_eq!(year_in("Darling 2019.mp3"), None);
    }
}
