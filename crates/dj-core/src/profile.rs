//! A compact, in-memory view of each playable track used by discovery and the
//! set planner. Values are the effective ones (catalogue > tag > analysis).
use crate::error::Result;
use crate::text::fold;
use rusqlite::Connection;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Tp {
    pub id: i64,
    pub artist: String,
    pub title: String,
    pub genre: Option<String>,
    pub year: Option<i64>,
    pub bpm: Option<f64>,
    pub key: Option<String>,
    pub energy: Option<i64>,
    pub rating: Option<i64>,
    pub duration_ms: Option<i64>,
    pub clean: Option<String>,
    pub version: Option<String>,
    pub tags: Vec<String>,
    pub plays: i64,
    pub work_key: Option<String>,
}

impl Tp {
    pub fn genre_fold(&self) -> String {
        self.genre.as_deref().map(fold).unwrap_or_default()
    }
    pub fn label(&self) -> String {
        format!("{} — {}", self.artist, self.title)
    }
}

pub fn load(conn: &Connection) -> Result<Vec<Tp>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, COALESCE(u.artist, t.artist, ''), COALESCE(u.title, t.title, t.file_name), COALESCE(u.genre, t.genre), COALESCE(u.year, t.year),
                COALESCE(u.bpm, t.bpm_tag, a.bpm), keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)), COALESCE(u.energy, a.energy), u.rating, t.duration_ms,
                COALESCE(u.clean_explicit, t.clean_hint), COALESCE(u.version_label, t.version_hint),
                (SELECT GROUP_CONCAT(g.name_fold, char(31)) FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id),
                (SELECT COUNT(*) FROM play_history ph WHERE ph.track_id=t.id) + (SELECT COUNT(*) FROM gig_events ge WHERE ge.track_id=t.id AND ge.kind='played'),
                t.work_key
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id LEFT JOIN library_roots r ON r.id=t.root_id
         WHERE t.presence='present' AND t.read_status='ok'",
    )?;
    let v = stmt
        .query_map([], |r| {
            let tags: Option<String> = r.get(12)?;
            Ok(Tp {
                id: r.get(0)?,
                artist: r.get(1)?,
                title: r.get(2)?,
                genre: r.get(3)?,
                year: r.get(4)?,
                bpm: r.get(5)?,
                key: r.get(6)?,
                energy: r.get(7)?,
                rating: r.get(8)?,
                duration_ms: r.get(9)?,
                clean: r.get(10)?,
                version: r.get(11)?,
                tags: tags
                    .map(|s| s.split('\u{1f}').map(|x| x.to_string()).collect())
                    .unwrap_or_default(),
                plays: r.get(13)?,
                work_key: r.get(14)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(v)
}

/// Tempo distance allowing half/double time. Returns relative difference.
pub fn bpm_distance(a: f64, b: f64) -> f64 {
    [1.0, 2.0, 0.5]
        .iter()
        .map(|m| ((a * m - b) / b).abs())
        .fold(f64::INFINITY, f64::min)
}
