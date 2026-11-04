//! Optional folder watching. New or changed music files in online library
//! folders are noted (never touched) so the DJ can scan them, with a
//! suggestion for where they might be organised. Paused in gig mode.
use crate::db::{self, now_ms};
use crate::error::Result;
use crate::metadata::{classify_extension, ExtKind};
use notify::{EventKind, RecursiveMode, Watcher};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct FolderWatcher {
    _inner: notify::RecommendedWatcher,
    pub roots: Vec<String>,
}

pub fn enabled(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "watch_enabled")?
        .map(|v| v == "1")
        .unwrap_or(false))
}

/// Start watching every online library root. Events are written to the
/// catalogue's watch_events table through a separate connection.
pub fn start(db_path: &Path, conn: &Connection) -> Result<Option<FolderWatcher>> {
    let roots: Vec<(i64, String)> = conn
        .prepare("SELECT id, path FROM library_roots WHERE status<>'offline'")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?;
    if roots.is_empty() {
        return Ok(None);
    }
    let db_path: PathBuf = db_path.to_path_buf();
    let wconn = Mutex::new(db::open(&db_path)?);
    let root_list = roots.clone();
    let handler = move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if !matches!(ev.kind, EventKind::Create(_) | EventKind::Modify(_)) {
            return;
        }
        let Ok(c) = wconn.lock() else { return };
        if db::get_setting(&c, "gig_mode").ok().flatten().as_deref() == Some("1") {
            return;
        }
        for p in ev.paths {
            let ext = p
                .extension()
                .map(|e| e.to_string_lossy().to_ascii_lowercase())
                .unwrap_or_default();
            if classify_extension(&ext) == ExtKind::Other || !p.is_file() {
                continue;
            }
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if name.starts_with('.') || name.contains(".djassistant-") {
                continue;
            }
            let ps = p.to_string_lossy().to_string();
            let root_id = root_list
                .iter()
                .find(|(_, r)| ps.starts_with(r.as_str()))
                .map(|(id, _)| *id);
            let known: bool = c
                .query_row(
                    "SELECT 1 FROM tracks WHERE path=?1",
                    params![ps],
                    |_| Ok(()),
                )
                .is_ok();
            let kind = if known { "changed" } else { "new" };
            let _ = c.execute(
                "INSERT INTO watch_events(root_id, path, kind, at) VALUES (?1,?2,?3,?4) ON CONFLICT(path) DO UPDATE SET at=excluded.at",
                params![root_id, ps, kind, now_ms()],
            );
        }
    };
    let mut w = notify::recommended_watcher(handler).map_err(|e| {
        crate::error::Error::Invalid(format!("folder watching is not available: {e}"))
    })?;
    let mut watched = vec![];
    for (_, r) in &roots {
        if w.watch(Path::new(r), RecursiveMode::Recursive).is_ok() {
            watched.push(r.clone());
        }
    }
    Ok(Some(FolderWatcher {
        _inner: w,
        roots: watched,
    }))
}

/// Pending files with an organisation suggestion based on their tags.
pub fn pending(conn: &Connection) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT w.id, w.root_id, w.path, w.kind, w.at, r.path FROM watch_events w LEFT JOIN library_roots r ON r.id=w.root_id ORDER BY w.at DESC LIMIT 300")?;
    let rows: Vec<(i64, Option<i64>, String, String, i64, Option<String>)> = stmt
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut out = vec![];
    for (id, root_id, path, kind, at, root) in rows {
        let meta = crate::metadata::read_audio_meta(Path::new(&path)).ok();
        let suggestion = meta.as_ref().and_then(|m| {
            let genre = m.genre.clone().unwrap_or_else(|| "Unsorted".into());
            let artist = m.artist.clone()?;
            Some(format!(
                "{}{}{}{}{}",
                root.clone().unwrap_or_default(),
                std::path::MAIN_SEPARATOR,
                genre,
                std::path::MAIN_SEPARATOR,
                artist
            ))
        });
        out.push(json!({"id": id, "root_id": root_id, "path": path, "kind": kind, "at": at,
            "artist": meta.as_ref().and_then(|m| m.artist.clone()), "title": meta.as_ref().and_then(|m| m.title.clone()), "genre": meta.as_ref().and_then(|m| m.genre.clone()),
            "suggested_folder": suggestion, "note": "Suggestion only. DJ Assistant does not move files; moving them would break Serato's links to them."}));
    }
    Ok(out)
}

pub fn clear(conn: &Connection, root_id: Option<i64>) -> Result<usize> {
    Ok(match root_id {
        Some(r) => conn.execute("DELETE FROM watch_events WHERE root_id=?1", params![r])?,
        None => conn.execute("DELETE FROM watch_events", [])?,
    })
}
