//! Discovery and recommendations. Every recommendation carries its reason,
//! source and date. Listening similarity is never presented as proof that two
//! tracks mix well; tempo/key compatibility is reported separately.
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use crate::library::TrackQuery;
use crate::online::{Online, Secrets};
use crate::profile::{self, bpm_distance, Tp};
use crate::text::{base_artist, base_title, detect_version_labels, fold};

/// Version labels of a title ("" when none). Two recordings only count as the
/// same if their labels match (Live, Remix, Clean… are different versions).
pub fn version_of(title: &str) -> String {
    detect_version_labels(title).unwrap_or_default()
}

fn tp_version(t: &Tp) -> String {
    t.version.clone().unwrap_or_else(|| version_of(&t.title))
}
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Serialize)]
pub struct Recommendation {
    pub track_id: i64,
    pub track: String,
    pub score: f64,
    pub reasons: Vec<String>,
    pub source: String,
}

pub fn learning_enabled(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "learning_enabled")?
        .map(|v| v == "1")
        .unwrap_or(true))
}

/// What the app has learned: preference weights per genre and artist from
/// ratings, play counts and explicit likes/dislikes. Fully inspectable.
pub fn preferences(conn: &Connection) -> Result<Value> {
    let tps = profile::load(conn)?;
    let mut genre: HashMap<String, (f64, i64)> = HashMap::new();
    let mut artist: HashMap<String, (f64, i64)> = HashMap::new();
    for t in &tps {
        let w = t.rating.map(|r| (r as f64 - 3.0) / 2.0).unwrap_or(0.0)
            + (t.plays.min(10) as f64) * 0.1;
        if w == 0.0 {
            continue;
        }
        if let Some(g) = &t.genre {
            let e = genre.entry(g.clone()).or_default();
            e.0 += w;
            e.1 += 1;
        }
        if !t.artist.is_empty() {
            let e = artist.entry(t.artist.clone()).or_default();
            e.0 += w;
            e.1 += 1;
        }
    }
    let mut stmt = conn
        .prepare("SELECT subject_kind, subject, value, at FROM pref_feedback ORDER BY at DESC")?;
    let feedback: Vec<Value> = stmt
        .query_map([], |r| Ok(json!({"kind": r.get::<_, String>(0)?, "subject": r.get::<_, String>(1)?, "value": r.get::<_, i64>(2)?, "at": r.get::<_, i64>(3)?})))?
        .collect::<std::result::Result<_, _>>()?;
    let top = |m: HashMap<String, (f64, i64)>| {
        let mut v: Vec<(String, f64, i64)> = m
            .into_iter()
            .map(|(k, (w, n))| (k, w / n as f64, n))
            .collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        v.into_iter()
            .take(15)
            .map(|(k, w, n)| json!({"name": k, "weight": (w * 100.0).round() / 100.0, "tracks": n}))
            .collect::<Vec<_>>()
    };
    Ok(json!({
        "enabled": learning_enabled(conn)?,
        "explanation": "Weights come from your star ratings (above or below 3★), how often tracks were played (gig mode and imported history) and the likes/dislikes you gave recommendations. Nothing else is used — personal files never are.",
        "genres": top(genre),
        "artists": top(artist),
        "feedback": feedback,
    }))
}

pub fn feedback(conn: &Connection, kind: &str, subject: &str, value: i64) -> Result<()> {
    if !["genre", "artist", "track"].contains(&kind) || ![-1, 1, 0].contains(&value) {
        return invalid("bad feedback");
    }
    if value == 0 {
        conn.execute(
            "DELETE FROM pref_feedback WHERE subject_kind=?1 AND subject=?2",
            params![kind, subject],
        )?;
    } else {
        conn.execute(
            "INSERT INTO pref_feedback(subject_kind, subject, value, at) VALUES (?1,?2,?3,?4) ON CONFLICT(subject_kind, subject) DO UPDATE SET value=excluded.value, at=excluded.at",
            params![kind, subject, value, now_ms()],
        )?;
    }
    Ok(())
}

pub fn reset_learning(conn: &Connection) -> Result<usize> {
    Ok(conn.execute("DELETE FROM pref_feedback", [])?)
}

fn feedback_map(conn: &Connection) -> Result<HashMap<(String, String), i64>> {
    if !learning_enabled(conn)? {
        return Ok(HashMap::new());
    }
    let mut stmt = conn.prepare("SELECT subject_kind, subject, value FROM pref_feedback")?;
    let m = stmt
        .query_map([], |r| {
            Ok((
                (r.get::<_, String>(0)?, fold(&r.get::<_, String>(1)?)),
                r.get::<_, i64>(2)?,
            ))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(m)
}

struct CrateProfile {
    ids: HashSet<i64>,
    genres: HashMap<String, usize>,
    artists: HashMap<String, usize>,
    bpm: Option<(f64, f64)>,
    energy: Option<(f64, f64)>,
    years: Option<(i64, i64)>,
    keys: HashSet<String>,
    n: usize,
}

fn crate_members(conn: &Connection, crate_id: i64) -> Result<HashSet<i64>> {
    Ok(crate::library::track_ids(
        conn,
        &TrackQuery {
            crate_id: Some(crate_id),
            ..Default::default()
        },
        100_000,
    )?
    .into_iter()
    .collect())
}

fn profile_of(members: &[&Tp]) -> CrateProfile {
    let mut p = CrateProfile {
        ids: HashSet::new(),
        genres: HashMap::new(),
        artists: HashMap::new(),
        bpm: None,
        energy: None,
        years: None,
        keys: HashSet::new(),
        n: members.len(),
    };
    let mut bpms = vec![];
    let mut energies = vec![];
    let mut years = vec![];
    for t in members {
        p.ids.insert(t.id);
        if t.genre.is_some() {
            *p.genres.entry(t.genre_fold()).or_default() += 1;
        }
        if !t.artist.is_empty() {
            *p.artists.entry(base_artist(&t.artist)).or_default() += 1;
        }
        if let Some(b) = t.bpm {
            bpms.push(b);
        }
        if let Some(e) = t.energy {
            energies.push(e as f64);
        }
        if let Some(y) = t.year {
            years.push(y);
        }
        if let Some(k) = &t.key {
            p.keys.insert(k.to_uppercase());
        }
    }
    let mean_sd = |v: &[f64]| -> Option<(f64, f64)> {
        if v.is_empty() {
            return None;
        }
        let m = v.iter().sum::<f64>() / v.len() as f64;
        let sd = (v.iter().map(|x| (x - m).powi(2)).sum::<f64>() / v.len() as f64).sqrt();
        Some((m, sd))
    };
    p.bpm = mean_sd(&bpms);
    p.energy = mean_sd(&energies);
    if !years.is_empty() {
        p.years = Some((*years.iter().min().unwrap(), *years.iter().max().unwrap()));
    }
    p
}

/// Tracks in the library (not in the crate) that fit the crate's profile.
pub fn crate_fit(conn: &Connection, crate_id: i64, limit: usize) -> Result<Vec<Recommendation>> {
    let tps = profile::load(conn)?;
    let ids = crate_members(conn, crate_id)?;
    if ids.is_empty() {
        return invalid(
            "this crate is empty; add a few tracks first so there is something to compare with",
        );
    }
    let members: Vec<&Tp> = tps.iter().filter(|t| ids.contains(&t.id)).collect();
    let p = profile_of(&members);
    let fb = feedback_map(conn)?;
    let mut recs = vec![];
    for t in tps.iter().filter(|t| !p.ids.contains(&t.id)) {
        let mut score = 0.0;
        let mut reasons = vec![];
        if let Some(n) = p.genres.get(&t.genre_fold()) {
            let share = *n as f64 / p.n as f64;
            score += 3.0 * share;
            reasons.push(format!(
                "Genre {} ({:.0}% of the crate)",
                t.genre.as_deref().unwrap_or(""),
                share * 100.0
            ));
        }
        if let Some(n) = p.artists.get(&base_artist(&t.artist)) {
            score += 1.5;
            reasons.push(format!(
                "Artist {} already has {n} track(s) in the crate",
                t.artist
            ));
        }
        if let (Some((m, sd)), Some(b)) = (p.bpm, t.bpm) {
            let tol = (sd / m).max(0.04);
            if bpm_distance(b, m) <= tol {
                score += 1.5;
                reasons.push(format!(
                    "BPM {b:.0} is in the crate's range (around {m:.0})"
                ));
            }
        }
        if let (Some((m, sd)), Some(e)) = (p.energy, t.energy) {
            if (e as f64 - m).abs() <= sd.max(1.0) {
                score += 1.0;
                reasons.push(format!("Energy {e} matches the crate (around {m:.0})"));
            }
        }
        if let (Some((lo, hi)), Some(y)) = (p.years, t.year) {
            if y >= lo - 1 && y <= hi + 1 {
                score += 0.7;
                reasons.push(format!("Year {y} is within {lo}–{hi}"));
            }
        }
        if let Some(r) = t.rating {
            score += (r as f64 - 3.0) * 0.3;
        }
        if let Some(v) = fb.get(&("artist".into(), fold(&t.artist))) {
            score += *v as f64;
            reasons.push(if *v > 0 {
                "You liked this artist".into()
            } else {
                "You marked this artist as not for you".into()
            });
        }
        if let Some(g) = &t.genre {
            if let Some(v) = fb.get(&("genre".into(), fold(g))) {
                score += *v as f64 * 0.8;
            }
        }
        if score >= 2.5 && reasons.len() >= 2 {
            recs.push(Recommendation {
                track_id: t.id,
                track: t.label(),
                score: (score * 100.0).round() / 100.0,
                reasons,
                source: "Your library".into(),
            });
        }
    }
    recs.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    recs.truncate(limit);
    Ok(recs)
}

/// Gaps: artists you collect who are thin in the crate, and how the crate's
/// genres and decades compare with the whole library.
pub fn gaps(conn: &Connection, crate_id: i64) -> Result<Value> {
    let tps = profile::load(conn)?;
    let ids = crate_members(conn, crate_id)?;
    let members: Vec<&Tp> = tps.iter().filter(|t| ids.contains(&t.id)).collect();
    let mut by_artist: HashMap<String, (String, usize, usize)> = HashMap::new();
    for t in &tps {
        if t.artist.is_empty() {
            continue;
        }
        let e = by_artist
            .entry(base_artist(&t.artist))
            .or_insert((t.artist.clone(), 0, 0));
        e.1 += 1;
        if ids.contains(&t.id) {
            e.2 += 1;
        }
    }
    let mut artists: Vec<Value> = by_artist
        .values()
        .filter(|(_, total, inc)| *inc > 0 && total > inc)
        .map(|(name, total, inc)| json!({"artist": name, "in_crate": inc, "in_library": total, "reason": format!("{inc} of your {total} {name} tracks are in this crate")}))
        .collect();
    artists.sort_by_key(|v| {
        -(v["in_library"].as_i64().unwrap_or(0) - v["in_crate"].as_i64().unwrap_or(0))
    });
    artists.truncate(20);
    let decade_counts = |set: &[&Tp]| {
        let mut m: HashMap<i64, usize> = HashMap::new();
        for t in set {
            if let Some(y) = t.year {
                *m.entry(y / 10 * 10).or_default() += 1;
            }
        }
        m
    };
    let all: Vec<&Tp> = tps.iter().collect();
    let (lib_dec, crate_dec) = (decade_counts(&all), decade_counts(&members));
    let mut decades: Vec<Value> = lib_dec.iter().map(|(d, n)| json!({"decade": d, "library": n, "crate": crate_dec.get(d).copied().unwrap_or(0)})).collect();
    decades.sort_by_key(|v| v["decade"].as_i64());
    let no_energy = members.iter().filter(|t| t.energy.is_none()).count();
    let no_bpm = members.iter().filter(|t| t.bpm.is_none()).count();
    Ok(
        json!({"artists": artists, "decades": decades, "missing_energy": no_energy, "missing_bpm": no_bpm, "size": members.len()}),
    )
}

/// Most-played tracks with fresher alternatives that share genre, tempo and energy.
pub fn overplayed(conn: &Connection, limit: usize) -> Result<Vec<Value>> {
    let tps = profile::load(conn)?;
    let mut played: Vec<&Tp> = tps.iter().filter(|t| t.plays >= 2).collect();
    played.sort_by_key(|t| -t.plays);
    played.truncate(limit);
    let mut out = vec![];
    for t in played {
        let mut alts: Vec<(f64, &Tp)> = tps
            .iter()
            .filter(|o| o.id != t.id && o.plays < t.plays / 2 + 1 && o.work_key != t.work_key)
            .filter_map(|o| {
                let mut s = 0.0;
                if o.genre_fold() == t.genre_fold() && o.genre.is_some() {
                    s += 2.0;
                }
                if let (Some(a), Some(b)) = (o.bpm, t.bpm) {
                    if bpm_distance(a, b) < 0.04 {
                        s += 1.5;
                    }
                }
                if let (Some(a), Some(b)) = (o.energy, t.energy) {
                    if (a - b).abs() <= 1 {
                        s += 1.0;
                    }
                }
                if s >= 3.0 {
                    Some((s, o))
                } else {
                    None
                }
            })
            .collect();
        alts.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        out.push(json!({
            "track_id": t.id, "track": t.label(), "plays": t.plays,
            "alternatives": alts.iter().take(5).map(|(s, o)| json!({"track_id": o.id, "track": o.label(), "plays": o.plays, "score": s})).collect::<Vec<_>>()
        }));
    }
    Ok(out)
}

/// Parse one tracklist line into (artist, title); "ID - ID" and blanks are unknown.
pub fn parse_tracklist_line(line: &str) -> Option<(String, String)> {
    let mut s = line.trim();
    // strip leading numbering / timestamps like "01.", "1)", "[00:12:30]", "12:30"
    loop {
        let t = s.trim_start();
        let n = t
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == ':' || *c == '[' || *c == ']')
            .count();
        if n > 0 && t[..n].chars().any(|c| c.is_ascii_digit()) {
            s = t[n..].trim_start_matches(['.', ')', '-', ' ', '\t']);
            continue;
        }
        break;
    }
    let s = s.split(" [").next().unwrap_or(s).trim();
    for sep in [" - ", " – ", " — "] {
        if let Some((a, t)) = s.split_once(sep) {
            return Some((a.trim().to_string(), t.trim().to_string()));
        }
    }
    None
}

/// Match a pasted tracklist against the library. Unknown entries (ID - ID,
/// unparseable lines) are kept, never dropped.
pub fn match_tracklist(conn: &Connection, text: &str) -> Result<Value> {
    if text.len() > 200_000 {
        return invalid("tracklist is too long");
    }
    let tps = profile::load(conn)?;
    let mut exact: HashMap<String, Vec<&Tp>> = HashMap::new();
    let mut by_title: HashMap<String, Vec<&Tp>> = HashMap::new();
    for t in &tps {
        exact
            .entry(format!(
                "{}|{}",
                base_artist(&t.artist),
                base_title(&t.title)
            ))
            .or_default()
            .push(t);
        by_title.entry(base_title(&t.title)).or_default().push(t);
    }
    let mut lines = vec![];
    let (mut owned, mut possible, mut missing, mut unknown) = (0, 0, 0, 0);
    for (i, raw) in text.lines().enumerate() {
        if raw.trim().is_empty() {
            continue;
        }
        let parsed = parse_tracklist_line(raw);
        let entry = match &parsed {
            Some((a, t)) if fold(a) == "id" || fold(t) == "id" || fold(t) == "id?" => {
                unknown += 1;
                json!({"line": i + 1, "text": raw.trim(), "status": "unknown", "note": "Unidentified track (ID) — kept as unknown."})
            }
            Some((a, t)) => {
                let k = format!("{}|{}", base_artist(a), base_title(t));
                let want = version_of(t);
                let cands = exact.get(&k).cloned().unwrap_or_default();
                if let Some(m) = cands.iter().find(|m| tp_version(m) == want) {
                    owned += 1;
                    json!({"line": i + 1, "text": raw.trim(), "artist": a, "title": t, "status": "owned", "track_id": m.id, "match": m.label()})
                } else if let Some(m) = cands.first() {
                    possible += 1;
                    let v = tp_version(m);
                    json!({"line": i + 1, "text": raw.trim(), "artist": a, "title": t, "status": "possibly_owned", "track_id": m.id, "match": m.label(),
                        "note": format!("You have a different version ({}). Versions are not treated as the same track.", if v.is_empty() { "original" } else { v.as_str() })})
                } else if let Some(c) = by_title.get(&base_title(t)).and_then(|v| {
                    v.iter().find(|m| {
                        fold(&m.artist).contains(&base_artist(a))
                            || base_artist(a).contains(&base_artist(&m.artist))
                    })
                }) {
                    possible += 1;
                    json!({"line": i + 1, "text": raw.trim(), "artist": a, "title": t, "status": "possibly_owned", "track_id": c.id, "match": c.label(), "note": "Same title, similar artist credit — check it is the same version."})
                } else {
                    missing += 1;
                    json!({"line": i + 1, "text": raw.trim(), "artist": a, "title": t, "status": "missing"})
                }
            }
            None => {
                unknown += 1;
                json!({"line": i + 1, "text": raw.trim(), "status": "unknown", "note": "Could not read artist and title from this line."})
            }
        };
        lines.push(entry);
    }
    Ok(
        json!({"lines": lines, "owned": owned, "possibly_owned": possible, "missing": missing, "unknown": unknown,
        "note": "Not every track in a DJ mix can be identified; unknown entries are kept as they are."}),
    )
}

fn ownership(tps: &[Tp], artist: &str, title: Option<&str>) -> (String, Option<i64>) {
    let a = base_artist(artist);
    match title {
        Some(t) => {
            let bt = base_title(t);
            let want = version_of(t);
            if let Some(m) = tps.iter().find(|x| {
                base_artist(&x.artist) == a && base_title(&x.title) == bt && tp_version(x) == want
            }) {
                return ("owned".into(), Some(m.id));
            }
            if let Some(m) = tps
                .iter()
                .find(|x| base_artist(&x.artist) == a && base_title(&x.title) == bt)
            {
                return ("possibly_owned".into(), Some(m.id));
            }
            if let Some(m) = tps
                .iter()
                .find(|x| base_title(&x.title) == bt && fold(&x.artist).contains(&a))
            {
                return ("possibly_owned".into(), Some(m.id));
            }
            ("missing".into(), None)
        }
        None => match tps.iter().find(|x| base_artist(&x.artist) == a) {
            Some(m) => ("owned".into(), Some(m.id)),
            None => ("missing".into(), None),
        },
    }
}

fn store_item(
    conn: &Connection,
    source: &str,
    kind: &str,
    artist: &str,
    title: Option<&str>,
    detail: &str,
    reason: &str,
    url: Option<&str>,
    released: Option<&str>,
    own: &(String, Option<i64>),
) -> Result<()> {
    conn.execute(
        "INSERT INTO discovery (source, kind, artist, title, detail, reason, url, released, fetched_at, owned_track_id, ownership)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
         ON CONFLICT(source, kind, artist, title) DO UPDATE SET detail=excluded.detail, reason=excluded.reason, fetched_at=excluded.fetched_at,
           owned_track_id=excluded.owned_track_id, ownership=excluded.ownership, released=excluded.released",
        params![source, kind, artist, title.unwrap_or(""), detail, reason, url, released, now_ms(), own.1, own.0],
    )?;
    Ok(())
}

/// Last.fm similar artists/tracks for a crate's most common artists.
pub fn lastfm_for_crate(
    conn: &Connection,
    online: &dyn Online,
    secrets: &dyn Secrets,
    crate_id: i64,
) -> Result<usize> {
    crate::suggest::require_service(conn, "lastfm")?;
    let key = secrets
        .get("lastfm")
        .ok_or_else(|| Error::Invalid("Add your Last.fm API key in Settings first.".into()))?;
    let tps = profile::load(conn)?;
    let ids = crate_members(conn, crate_id)?;
    let mut counts: HashMap<String, (String, usize)> = HashMap::new();
    for t in tps
        .iter()
        .filter(|t| ids.contains(&t.id) && !t.artist.is_empty())
    {
        counts
            .entry(base_artist(&t.artist))
            .or_insert((t.artist.clone(), 0))
            .1 += 1;
    }
    let mut top: Vec<(String, usize)> = counts.into_values().collect();
    top.sort_by_key(|x| std::cmp::Reverse(x.1));
    let mut n = 0;
    for (artist, _) in top.into_iter().take(5) {
        let sims = online
            .lastfm_similar_artists(&key, &artist)
            .map_err(Error::Invalid)?;
        for s in sims.iter().take(12) {
            let own = ownership(&tps, &s.artist, None);
            store_item(conn, "Last.fm", "artist", &s.artist, None, &format!("Similarity {:.0}%", s.score * 100.0), &format!("Similar to {artist} on Last.fm (listening similarity, not a mixing guarantee)."), s.url.as_deref(), None, &own)?;
            n += 1;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    Ok(n)
}

pub fn lastfm_for_track(
    conn: &Connection,
    online: &dyn Online,
    secrets: &dyn Secrets,
    track_id: i64,
) -> Result<usize> {
    crate::suggest::require_service(conn, "lastfm")?;
    let key = secrets
        .get("lastfm")
        .ok_or_else(|| Error::Invalid("Add your Last.fm API key in Settings first.".into()))?;
    let tps = profile::load(conn)?;
    let t = tps
        .iter()
        .find(|t| t.id == track_id)
        .ok_or_else(|| Error::NotFound("track".into()))?;
    let sims = online
        .lastfm_similar_tracks(&key, &t.artist, &base_title(&t.title))
        .map_err(Error::Invalid)?;
    for s in &sims {
        let own = ownership(&tps, &s.artist, s.title.as_deref());
        store_item(
            conn,
            "Last.fm",
            "track",
            &s.artist,
            s.title.as_deref(),
            &format!("Similarity {:.0}%", s.score * 100.0),
            &format!("Listeners of {} also play this (Last.fm).", t.label()),
            s.url.as_deref(),
            None,
            &own,
        )?;
    }
    Ok(sims.len())
}

pub fn follow(conn: &Connection, kind: &str, name: &str) -> Result<()> {
    let n = name.trim();
    if n.is_empty() || n.len() > 200 || !["artist", "label"].contains(&kind) {
        return invalid("enter an artist name");
    }
    conn.execute(
        "INSERT OR IGNORE INTO followed(kind, name, added_at) VALUES (?1,?2,?3)",
        params![kind, n, now_ms()],
    )?;
    Ok(())
}

pub fn unfollow(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("DELETE FROM followed WHERE id=?1", params![id])?;
    Ok(())
}

pub fn followed(conn: &Connection) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT id, kind, name, added_at FROM followed ORDER BY name")?;
    let v = stmt
        .query_map([], |r| Ok(json!({"id": r.get::<_, i64>(0)?, "kind": r.get::<_, String>(1)?, "name": r.get::<_, String>(2)?, "added_at": r.get::<_, i64>(3)?})))?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

/// New releases (last 365 days) for followed artists, from MusicBrainz.
pub fn refresh_releases(conn: &Connection, online: &dyn Online) -> Result<usize> {
    crate::suggest::require_service(conn, "musicbrainz")?;
    let tps = profile::load(conn)?;
    let names: Vec<String> = followed(conn)?
        .iter()
        .filter(|f| f["kind"] == "artist")
        .filter_map(|f| f["name"].as_str().map(|s| s.to_string()))
        .collect();
    let mut n = 0;
    for a in names {
        let rels = online
            .musicbrainz_artist_releases(&a)
            .map_err(Error::Invalid)?;
        for r in rels {
            let own = ownership(&tps, &r.artist, Some(&r.title));
            store_item(
                conn,
                "MusicBrainz",
                "release",
                &r.artist,
                Some(&r.title),
                &r.kind,
                &format!(
                    "New {} from {a}, an artist you follow.",
                    r.kind.to_lowercase()
                ),
                r.url.as_deref(),
                r.date.as_deref(),
                &own,
            )?;
            n += 1;
        }
        std::thread::sleep(std::time::Duration::from_millis(1100));
    }
    Ok(n)
}

pub fn items(conn: &Connection, status: Option<&str>) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare(
        "SELECT id, source, kind, artist, title, detail, reason, url, released, fetched_at, owned_track_id, ownership, status FROM discovery
         WHERE (?1 IS NULL AND status<>'dismissed') OR status=?1 ORDER BY fetched_at DESC, id LIMIT 500",
    )?;
    let v = stmt
        .query_map(params![status], |r| {
            Ok(json!({"id": r.get::<_, i64>(0)?, "source": r.get::<_, String>(1)?, "kind": r.get::<_, String>(2)?, "artist": r.get::<_, Option<String>>(3)?,
                "title": r.get::<_, Option<String>>(4)?, "detail": r.get::<_, Option<String>>(5)?, "reason": r.get::<_, Option<String>>(6)?,
                "url": r.get::<_, Option<String>>(7)?, "released": r.get::<_, Option<String>>(8)?, "fetched_at": r.get::<_, i64>(9)?,
                "owned_track_id": r.get::<_, Option<i64>>(10)?, "ownership": r.get::<_, String>(11)?, "status": r.get::<_, String>(12)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn set_item_status(conn: &Connection, id: i64, status: &str) -> Result<()> {
    if !["new", "wishlist", "dismissed"].contains(&status) {
        return invalid("bad status");
    }
    conn.execute(
        "UPDATE discovery SET status=?2 WHERE id=?1",
        params![id, status],
    )?;
    Ok(())
}

/// Search links for buying or previewing music from legitimate stores.
/// (Links only: nothing is downloaded or ripped.)
pub fn store_links(artist: &str, title: &str) -> Vec<Value> {
    let q = format!("{artist} {title}");
    let enc: String = q
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect();
    [
        (
            "Beatport",
            format!("https://www.beatport.com/search?q={enc}"),
        ),
        ("Bandcamp", format!("https://bandcamp.com/search?q={enc}")),
        (
            "Traxsource",
            format!("https://www.traxsource.com/search?term={enc}"),
        ),
        (
            "Juno Download",
            format!("https://www.junodownload.com/search/?q%5Ball%5D%5B%5D={enc}"),
        ),
        (
            "Apple Music / iTunes",
            format!("https://music.apple.com/search?term={enc}"),
        ),
        (
            "Amazon Music",
            format!("https://www.amazon.com/s?k={enc}&i=digital-music"),
        ),
        (
            "YouTube (preview only)",
            format!("https://www.youtube.com/results?search_query={enc}"),
        ),
    ]
    .into_iter()
    .map(|(n, u)| json!({"store": n, "url": u}))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_tracklist_lines() {
        assert_eq!(
            parse_tracklist_line("01. Wizkid - Essence"),
            Some(("Wizkid".into(), "Essence".into()))
        );
        assert_eq!(
            parse_tracklist_line("[00:12:30] Rema – Calm Down [Mavin]"),
            Some(("Rema".into(), "Calm Down".into()))
        );
        assert_eq!(
            parse_tracklist_line("12:30 ID - ID"),
            Some(("ID".into(), "ID".into()))
        );
        assert_eq!(parse_tracklist_line("Intro"), None);
    }
    #[test]
    fn store_links_are_encoded() {
        let l = store_links("Beyoncé", "Déjà Vu");
        assert!(l[0]["url"]
            .as_str()
            .unwrap()
            .contains("Beyonc%C3%A9+D%C3%A9j%C3%A0+Vu"));
    }
}
