//! File organiser (opt-in): rename files and folders, move files into a
//! folder layout, and remove corrupt or unwanted files — restorably.
//!
//! Follows the rules for file-changing features:
//! * only when "Allow changes to music files" is on in Settings;
//! * every change is previewed first and applied only with explicit approval;
//! * conflicts (target exists, two files to the same name) block that item;
//! * a source that changed since the preview is skipped;
//! * every change is logged and can be undone; removed files go to a
//!   "Removed files" area in the app's data folder and can be restored until
//!   the DJ empties it.
//!
//! Renaming or moving a file breaks Serato's link to it (Serato stores full
//! paths), so the preview always says so.
use crate::db::now_ms;
use crate::error::{invalid, Error, Result};
use crate::paths;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const SERATO_WARNING: &str = "Renaming or moving files breaks Serato's links to them: Serato's crates, cue points and beatgrids for these tracks will show them as missing until Serato is pointed at the new location (Serato: Files → Relocate lost files). Analysis and crates inside DJ Assistant follow the files automatically.";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Op {
    /// "rename" (same folder), "move" (into another folder), "folder_rename" or "remove".
    pub op: String,
    pub track_id: Option<i64>,
    pub from: String,
    pub to: String,
    /// Size and modified time at preview, to detect changes before applying.
    pub size: Option<u64>,
    pub mtime: Option<i64>,
    /// Why this item can't be applied (shown in the preview; such items are skipped).
    pub blocked: Option<String>,
    /// Number of tracks affected (folder renames).
    pub tracks: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Plan {
    pub ops: Vec<Op>,
    pub ready: usize,
    pub blocked: usize,
    pub warning: Option<String>,
}

fn require_enabled(conn: &Connection) -> Result<()> {
    if !crate::safe_write::enabled(conn)? {
        return invalid("Changes to music files are turned off. Turn on \"Allow changes to music files\" in Settings → Safety first (and keep a backup of your music).");
    }
    Ok(())
}

fn stamp(p: &Path) -> (Option<u64>, Option<i64>) {
    match std::fs::metadata(p) {
        Ok(m) => (
            Some(m.len()),
            m.modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64),
        ),
        Err(_) => (None, None),
    }
}

/// Make text safe as a Windows file or folder name.
pub fn sanitize(name: &str) -> String {
    let mut s: String = name
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => ' ',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s = s.trim_end_matches(['.', ' ']).trim().to_string();
    let upper = s.to_ascii_uppercase();
    let reserved = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3",
    ];
    let s = if reserved.contains(&upper.as_str()) {
        format!("{s}_")
    } else {
        s
    };
    s.chars().take(180).collect::<String>().trim().to_string()
}

struct TrackInfo {
    id: i64,
    path: String,
    root: Option<String>,
    fields: std::collections::HashMap<&'static str, String>,
}

fn track_info(conn: &Connection, id: i64) -> Result<TrackInfo> {
    conn.query_row(
        "SELECT t.id, t.path, r.path, COALESCE(u.artist, t.artist), COALESCE(u.title, t.title), COALESCE(u.album, t.album), COALESCE(u.genre, t.genre),
                COALESCE(u.year, t.year), COALESCE(u.bpm, t.bpm_tag, a.bpm), keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)), COALESCE(u.version_label, t.version_hint), t.presence
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?1",
        params![id],
        |r| {
            let mut f = std::collections::HashMap::new();
            let mut put = |k: &'static str, v: Option<String>| {
                if let Some(v) = v.map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
                    f.insert(k, v);
                }
            };
            put("artist", r.get(3)?);
            put("title", r.get(4)?);
            put("album", r.get(5)?);
            put("genre", r.get(6)?);
            put("year", r.get::<_, Option<i64>>(7)?.map(|y| y.to_string()));
            put("bpm", r.get::<_, Option<f64>>(8)?.map(|b| format!("{}", b.round() as i64)));
            put("key", r.get(9)?);
            put("version", r.get(10)?);
            let presence: String = r.get(11)?;
            if presence != "present" {
                f.insert("_missing", "1".into());
            }
            Ok(TrackInfo { id: r.get(0)?, path: r.get(1)?, root: r.get(2)?, fields: f })
        },
    )
    .optional()?
    .ok_or_else(|| Error::NotFound("track".into()))
}

/// Fill a template like "{artist} - {title}". Returns Err(missing field) if a
/// token has no value.
pub fn render(
    template: &str,
    t: &std::collections::HashMap<&'static str, String>,
) -> std::result::Result<String, String> {
    let mut out = String::new();
    let mut rest = template;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let Some(j) = rest[i..].find('}') else {
            return Err("unclosed {".into());
        };
        let key = &rest[i + 1..i + j];
        match t.get(key) {
            Some(v) => out.push_str(v),
            None => return Err(format!("no {key}")),
        }
        rest = &rest[i + j + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

const TOKENS: &[&str] = &[
    "artist", "title", "album", "genre", "year", "bpm", "key", "version",
];

fn check_template(t: &str) -> Result<()> {
    let mut rest = t;
    while let Some(i) = rest.find('{') {
        let j = rest[i..]
            .find('}')
            .ok_or_else(|| Error::Invalid("template has an unclosed {".into()))?;
        let key = &rest[i + 1..i + j];
        if !TOKENS.contains(&key) {
            return invalid(format!(
                "unknown field {{{key}}} — use {}",
                TOKENS
                    .iter()
                    .map(|k| format!("{{{k}}}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
        rest = &rest[i + j + 1..];
    }
    if t.trim().is_empty() || t.len() > 200 {
        return invalid("the template is empty or too long");
    }
    Ok(())
}

fn finish(mut ops: Vec<Op>, warn: bool) -> Plan {
    // Two items aiming at the same target block each other.
    let mut count: std::collections::HashMap<String, usize> = Default::default();
    for o in ops
        .iter()
        .filter(|o| o.blocked.is_none() && o.op != "remove")
    {
        *count.entry(paths::path_key_with(&o.to, true)).or_default() += 1;
    }
    for o in ops.iter_mut() {
        if o.blocked.is_none()
            && o.op != "remove"
            && count
                .get(&paths::path_key_with(&o.to, true))
                .copied()
                .unwrap_or(0)
                > 1
        {
            o.blocked = Some("Another file in this plan would get the same name.".into());
        }
    }
    let ready = ops.iter().filter(|o| o.blocked.is_none()).count();
    Plan {
        blocked: ops.len() - ready,
        ready,
        ops,
        warning: warn.then(|| SERATO_WARNING.to_string()),
    }
}

fn target_exists(to: &Path, from: &Path) -> bool {
    // A case-only rename on Windows targets the same file: allowed.
    to.exists()
        && paths::path_key_with(&to.to_string_lossy(), true)
            != paths::path_key_with(&from.to_string_lossy(), true)
}

/// Rename files in place, e.g. "{artist} - {title}".
pub fn preview_rename(conn: &Connection, ids: &[i64], template: &str) -> Result<Plan> {
    require_enabled(conn)?;
    check_template(template)?;
    let mut ops = vec![];
    for &id in ids {
        let t = track_info(conn, id)?;
        let from = PathBuf::from(&t.path);
        let ext = from
            .extension()
            .map(|e| format!(".{}", e.to_string_lossy()))
            .unwrap_or_default();
        let (size, mtime) = stamp(&from);
        let mut op = Op {
            op: "rename".into(),
            track_id: Some(t.id),
            from: t.path.clone(),
            to: t.path.clone(),
            size,
            mtime,
            blocked: None,
            tracks: 1,
        };
        if t.fields.contains_key("_missing") || size.is_none() {
            op.blocked = Some("The file isn't available.".into());
        } else {
            match render(template, &t.fields) {
                Err(m) => op.blocked = Some(format!("Can't name it: {m}.")),
                Ok(name) => {
                    let name = sanitize(&name);
                    if name.is_empty() {
                        op.blocked = Some("The new name would be empty.".into());
                    } else {
                        let to = from.with_file_name(format!("{name}{ext}"));
                        op.to = to.to_string_lossy().to_string();
                        if op.to == op.from {
                            continue; // already named this way
                        }
                        if target_exists(&to, &from) {
                            op.blocked = Some("A file with that name already exists.".into());
                        }
                    }
                }
            }
        }
        ops.push(op);
    }
    Ok(finish(ops, true))
}

/// Move files into folders under their library folder, e.g. "{genre}/{artist}".
pub fn preview_move(conn: &Connection, ids: &[i64], folder_template: &str) -> Result<Plan> {
    require_enabled(conn)?;
    check_template(folder_template)?;
    let mut ops = vec![];
    for &id in ids {
        let t = track_info(conn, id)?;
        let from = PathBuf::from(&t.path);
        let (size, mtime) = stamp(&from);
        let mut op = Op {
            op: "move".into(),
            track_id: Some(t.id),
            from: t.path.clone(),
            to: t.path.clone(),
            size,
            mtime,
            blocked: None,
            tracks: 1,
        };
        if t.fields.contains_key("_missing") || size.is_none() {
            op.blocked = Some("The file isn't available.".into());
        } else if let Some(root) = &t.root {
            match render(folder_template, &t.fields) {
                Err(m) => op.blocked = Some(format!("Can't place it: {m}.")),
                Ok(rel) => {
                    let mut dir = PathBuf::from(root);
                    for part in rel.split(['/', '\\']) {
                        let part = sanitize(part);
                        if !part.is_empty() && part != "." && part != ".." {
                            dir.push(part);
                        }
                    }
                    let to = dir.join(from.file_name().unwrap_or_default());
                    op.to = to.to_string_lossy().to_string();
                    if op.to == op.from {
                        continue;
                    }
                    if target_exists(&to, &from) {
                        op.blocked =
                            Some("A file with that name is already in that folder.".into());
                    }
                }
            }
        } else {
            op.blocked = Some("The track isn't in a library folder.".into());
        }
        ops.push(op);
    }
    Ok(finish(ops, true))
}

/// Rename one folder inside a library folder.
pub fn preview_folder_rename(conn: &Connection, folder: &str, new_name: &str) -> Result<Plan> {
    require_enabled(conn)?;
    let from = PathBuf::from(folder);
    let name = sanitize(new_name);
    if name.is_empty() {
        return invalid("type a new folder name");
    }
    let roots: Vec<String> = conn
        .prepare("SELECT path FROM library_roots")?
        .query_map([], |r| r.get(0))?
        .collect::<std::result::Result<_, _>>()?;
    let key = paths::path_key_with(folder, true);
    let inside = roots.iter().any(|r| {
        let rk = paths::path_key_with(r, true);
        key.len() > rk.len() && key.starts_with(&rk)
    });
    if !inside {
        return invalid(
            "only folders inside your music folders can be renamed (not a music folder itself)",
        );
    }
    let to = from.with_file_name(&name);
    let prefix = format!("{}{}", from.to_string_lossy(), std::path::MAIN_SEPARATOR);
    let tracks: i64 = conn.query_row(
        "SELECT COUNT(*) FROM tracks WHERE substr(path, 1, length(?1)) = ?1",
        params![prefix],
        |r| r.get(0),
    )?;
    let mut op = Op {
        op: "folder_rename".into(),
        track_id: None,
        from: folder.to_string(),
        to: to.to_string_lossy().to_string(),
        size: None,
        mtime: None,
        blocked: None,
        tracks,
    };
    if !from.is_dir() {
        op.blocked = Some("The folder isn't available.".into());
    } else if target_exists(&to, &from) {
        op.blocked = Some("A folder with that name already exists here.".into());
    }
    Ok(finish(vec![op], true))
}

/// Tracks that look broken: unreadable/corrupt, or empty files.
pub fn bad_files(conn: &Connection) -> Result<Vec<i64>> {
    Ok(conn
        .prepare("SELECT id FROM tracks WHERE presence='present' AND removed_at IS NULL AND (read_status='error' OR file_size=0) ORDER BY path")?
        .query_map([], |r| r.get(0))?
        .collect::<std::result::Result<_, _>>()?)
}

/// Remove files (moved to the restorable "Removed files" area).
pub fn preview_remove(conn: &Connection, data_dir: &Path, ids: &[i64]) -> Result<Plan> {
    require_enabled(conn)?;
    let _ = data_dir;
    let mut ops = vec![];
    for &id in ids {
        let (path, rel): (String, String) = conn
            .query_row(
                "SELECT path, rel_path FROM tracks WHERE id=?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound("track".into()))?;
        let from = PathBuf::from(&path);
        let (size, mtime) = stamp(&from);
        let mut op = Op {
            op: "remove".into(),
            track_id: Some(id),
            from: path.clone(),
            to: String::new(),
            size,
            mtime,
            blocked: None,
            tracks: 1,
        };
        // For removals `to` holds the path inside the library folder; the file
        // goes to "Removed files/<batch>/<that path>" when applied.
        op.to = rel;
        if size.is_none() {
            op.blocked = Some("The file isn't available.".into());
        }
        ops.push(op);
    }
    Ok(finish(ops, false))
}

pub fn removed_area(data_dir: &Path) -> PathBuf {
    data_dir.join("Removed files")
}

fn move_file(from: &Path, to: &Path) -> std::result::Result<(), String> {
    if let Some(parent) = to.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("couldn't create {}: {e}", parent.display()))?;
    }
    match std::fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(_) => {
            // Different drive: copy, verify the copy byte-for-byte by hash, then delete the original.
            std::fs::copy(from, to).map_err(|e| format!("copy failed: {e}"))?;
            let a = crate::scanner::hash_file(from, None).map_err(|e| e.to_string())?;
            let b = crate::scanner::hash_file(to, None).map_err(|e| e.to_string())?;
            if a.is_none() || a != b {
                let _ = std::fs::remove_file(to);
                return Err("the copy didn't verify; the original was left in place".into());
            }
            std::fs::remove_file(from)
                .map_err(|e| format!("couldn't remove the original (is it open in Serato?): {e}"))
        }
    }
}

fn update_track_path(conn: &Connection, id: i64, new_path: &str) -> Result<()> {
    let p = Path::new(new_path);
    let rel: String = conn.query_row(
        "SELECT r.path FROM tracks t LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?1",
        params![id],
        |r| {
            let root: Option<String> = r.get(0)?;
            Ok(root
                .as_deref()
                .and_then(|root| p.strip_prefix(root).ok())
                .map(|x| x.to_string_lossy().to_string())
                .unwrap_or_else(|| {
                    p.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string()
                }))
        },
    )?;
    conn.execute(
        "UPDATE tracks SET path=?2, path_key=?3, rel_path=?4, file_name=?5 WHERE id=?1",
        params![
            id,
            new_path,
            paths::path_key_with(new_path, paths::CASE_INSENSITIVE),
            rel,
            p.file_name().unwrap_or_default().to_string_lossy()
        ],
    )?;
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
pub struct Applied {
    pub batch: String,
    pub done: usize,
    pub skipped: Vec<(String, String)>,
}

/// Apply a previewed plan. Each item is re-checked; problems skip that item only.
pub fn apply(conn: &Connection, data_dir: &Path, plan: &[Op]) -> Result<Applied> {
    require_enabled(conn)?;
    let batch = format!("{}", now_ms());
    let mut done = 0;
    let mut skipped = vec![];
    for o in plan {
        if let Some(b) = &o.blocked {
            skipped.push((o.from.clone(), b.clone()));
            continue;
        }
        let from = PathBuf::from(&o.from);
        if o.op != "folder_rename" && stamp(&from) != (o.size, o.mtime) {
            skipped.push((
                o.from.clone(),
                "The file changed or moved since the preview; preview again.".into(),
            ));
            continue;
        }
        let to = if o.op == "remove" {
            // Only plain path components: never escape the "Removed files" area.
            let rel = PathBuf::from(&o.to)
                .components()
                .filter(|c| matches!(c, std::path::Component::Normal(_)))
                .collect::<PathBuf>();
            removed_area(data_dir).join(&batch).join(rel)
        } else {
            PathBuf::from(&o.to)
        };
        if target_exists(&to, &from) {
            skipped.push((
                o.from.clone(),
                "Something already exists at the new location.".into(),
            ));
            continue;
        }
        let r = if o.op == "folder_rename" {
            std::fs::rename(&from, &to)
                .map_err(|e| format!("couldn't rename the folder (is a file in it open?): {e}"))
        } else {
            move_file(&from, &to)
        };
        let to_s = to.to_string_lossy().to_string();
        match r {
            Ok(()) => {
                match o.op.as_str() {
                    "folder_rename" => {
                        let old = format!("{}{}", o.from, std::path::MAIN_SEPARATOR);
                        let new = format!("{}{}", to_s, std::path::MAIN_SEPARATOR);
                        let ids: Vec<(i64, String)> = conn
                            .prepare("SELECT id, path FROM tracks WHERE substr(path, 1, length(?1)) = ?1")?
                            .query_map(params![old], |r| Ok((r.get(0)?, r.get(1)?)))?
                            .collect::<std::result::Result<_, _>>()?;
                        for (id, p) in ids {
                            update_track_path(conn, id, &format!("{new}{}", &p[old.len()..]))?;
                        }
                    }
                    "remove" => {
                        conn.execute(
                            "UPDATE tracks SET presence='missing', removed_at=?2 WHERE id=?1",
                            params![o.track_id, now_ms()],
                        )?;
                    }
                    _ => {
                        if let Some(id) = o.track_id {
                            update_track_path(conn, id, &to_s)?;
                        }
                    }
                }
                conn.execute(
                    "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, at) VALUES (?1,?2,?3,?4,?5,'done',?6)",
                    params![batch, o.op, o.track_id, o.from, to_s, now_ms()],
                )?;
                done += 1;
            }
            Err(e) => {
                conn.execute(
                    "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, error, at) VALUES (?1,?2,?3,?4,?5,'failed',?6,?7)",
                    params![batch, o.op, o.track_id, o.from, to_s, e, now_ms()],
                )?;
                skipped.push((o.from.clone(), e));
            }
        }
    }
    Ok(Applied {
        batch,
        done,
        skipped,
    })
}

/// Undo a batch (or one operation): move everything back, newest first.
pub fn undo(conn: &Connection, batch: Option<&str>, op_id: Option<i64>) -> Result<usize> {
    let rows: Vec<(i64, String, Option<i64>, String, String)> = conn
        .prepare("SELECT id, op, track_id, from_path, to_path FROM file_ops WHERE status='done' AND ((?1 IS NOT NULL AND batch=?1) OR id=?2) ORDER BY id DESC")?
        .query_map(params![batch, op_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
        .collect::<std::result::Result<_, _>>()?;
    if rows.is_empty() {
        return invalid("nothing to undo");
    }
    let mut n = 0;
    for (id, op, track_id, from, to) in rows {
        let (src, dst) = (PathBuf::from(&to), PathBuf::from(&from));
        if dst.exists() && op != "folder_rename" {
            return invalid(format!("can't undo: something already exists at {from}"));
        }
        let r = if op == "folder_rename" {
            std::fs::rename(&src, &dst).map_err(|e| e.to_string())
        } else {
            move_file(&src, &dst)
        };
        r.map_err(|e| Error::Invalid(format!("couldn't move {to} back: {e}")))?;
        match op.as_str() {
            "folder_rename" => {
                let old = format!("{}{}", to, std::path::MAIN_SEPARATOR);
                let new = format!("{}{}", from, std::path::MAIN_SEPARATOR);
                let ids: Vec<(i64, String)> = conn
                    .prepare("SELECT id, path FROM tracks WHERE substr(path, 1, length(?1)) = ?1")?
                    .query_map(params![old], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<std::result::Result<_, _>>()?;
                for (tid, p) in ids {
                    update_track_path(conn, tid, &format!("{new}{}", &p[old.len()..]))?;
                }
            }
            "remove" => {
                conn.execute(
                    "UPDATE tracks SET presence='present', removed_at=NULL WHERE id=?1",
                    params![track_id],
                )?;
            }
            _ => {
                if let Some(t) = track_id {
                    update_track_path(conn, t, &from)?;
                }
            }
        }
        conn.execute(
            "UPDATE file_ops SET status='undone' WHERE id=?1",
            params![id],
        )?;
        n += 1;
    }
    Ok(n)
}

pub fn history(conn: &Connection, limit: i64) -> Result<Vec<serde_json::Value>> {
    Ok(conn
        .prepare("SELECT id, batch, op, track_id, from_path, to_path, status, error, at FROM file_ops ORDER BY id DESC LIMIT ?1")?
        .query_map(params![limit], |r| {
            Ok(serde_json::json!({"id": r.get::<_, i64>(0)?, "batch": r.get::<_, String>(1)?, "op": r.get::<_, String>(2)?, "track_id": r.get::<_, Option<i64>>(3)?,
                "from": r.get::<_, String>(4)?, "to": r.get::<_, String>(5)?, "status": r.get::<_, String>(6)?, "error": r.get::<_, Option<String>>(7)?, "at": r.get::<_, i64>(8)?}))
        })?
        .collect::<std::result::Result<_, _>>()?)
}

/// Size and count of files in the "Removed files" area.
pub fn removed_summary(conn: &Connection) -> Result<serde_json::Value> {
    let (n, bytes): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(t.file_size),0) FROM file_ops f LEFT JOIN tracks t ON t.id=f.track_id WHERE f.op='remove' AND f.status='done'",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok(serde_json::json!({"files": n, "bytes": bytes}))
}

/// Permanently delete everything in the "Removed files" area. Explicit and final.
pub fn empty_removed(conn: &Connection, data_dir: &Path) -> Result<usize> {
    require_enabled(conn)?;
    let rows: Vec<(i64, Option<i64>, String)> = conn
        .prepare("SELECT id, track_id, to_path FROM file_ops WHERE op='remove' AND status='done'")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let area = removed_area(data_dir);
    let mut n = 0;
    for (id, track_id, to) in rows {
        let p = PathBuf::from(&to);
        // Only ever delete inside our own "Removed files" area.
        if !p.starts_with(&area) {
            continue;
        }
        if p.exists() {
            std::fs::remove_file(&p)
                .map_err(|e| Error::Invalid(format!("couldn't delete {to}: {e}")))?;
        }
        conn.execute(
            "UPDATE file_ops SET status='purged' WHERE id=?1",
            params![id],
        )?;
        if let Some(t) = track_id {
            conn.execute(
                "DELETE FROM tracks WHERE id=?1 AND removed_at IS NOT NULL",
                params![t],
            )?;
        }
        n += 1;
    }
    // Tidy up empty batch folders.
    if let Ok(rd) = std::fs::read_dir(&area) {
        for e in rd.flatten() {
            let _ = remove_empty_dirs(&e.path());
        }
    }
    Ok(n)
}

fn remove_empty_dirs(p: &Path) -> std::io::Result<()> {
    if p.is_dir() {
        for e in std::fs::read_dir(p)?.flatten() {
            remove_empty_dirs(&e.path())?;
        }
        let _ = std::fs::remove_dir(p);
    }
    Ok(())
}

/// Keep one of a set of duplicates: crates, tags and your ratings move to the
/// kept track, then the others are removed (restorably).
pub fn preview_replace(
    conn: &Connection,
    data_dir: &Path,
    keep: i64,
    others: &[i64],
) -> Result<Plan> {
    if others.contains(&keep) || others.is_empty() {
        return invalid("choose the track to keep and at least one other to replace");
    }
    track_info(conn, keep)?;
    preview_remove(conn, data_dir, others)
}

pub fn merge_into(conn: &Connection, keep: i64, others: &[i64]) -> Result<()> {
    for &o in others {
        conn.execute("INSERT OR IGNORE INTO crate_tracks(crate_id, track_id, mode, position, added_at) SELECT crate_id, ?1, mode, position, added_at FROM crate_tracks WHERE track_id=?2", params![keep, o])?;
        conn.execute("INSERT OR IGNORE INTO track_tags(track_id, tag_id) SELECT ?1, tag_id FROM track_tags WHERE track_id=?2", params![keep, o])?;
        conn.execute(
            "INSERT OR IGNORE INTO track_user(track_id) VALUES (?1)",
            params![keep],
        )?;
        // Fill the kept track's empty catalogue values from the replaced one.
        for col in [
            "genre",
            "year",
            "bpm",
            "musical_key",
            "energy",
            "rating",
            "mood",
            "color",
            "notes",
            "version_label",
            "clean_explicit",
            "title",
            "artist",
            "album",
            "original_year",
            "record_label",
        ] {
            conn.execute(
                &format!("UPDATE track_user SET {col} = (SELECT {col} FROM track_user WHERE track_id=?2) WHERE track_id=?1 AND {col} IS NULL"),
                params![keep, o],
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_are_safe_on_windows() {
        assert_eq!(sanitize("AC/DC: Back <In> Black?"), "AC DC Back In Black");
        assert_eq!(sanitize("  trailing dots... "), "trailing dots");
        assert_eq!(sanitize("CON"), "CON_");
        assert_eq!(sanitize("a\u{0}b"), "a b");
        let mut f = std::collections::HashMap::new();
        f.insert("artist", "Lagos Lights".to_string());
        f.insert("title", "Sunrise Groove".to_string());
        assert_eq!(
            render("{artist} - {title}", &f).unwrap(),
            "Lagos Lights - Sunrise Groove"
        );
        assert_eq!(render("{genre}/{artist}", &f).unwrap_err(), "no genre");
        assert!(check_template("{artist} - {nope}").is_err());
    }
}
