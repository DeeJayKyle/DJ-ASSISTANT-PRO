//! Personal files (opt-in, separate from music). Indexes only folders the
//! user adds; reads files without changing them; never feeds music
//! recommendations.
use crate::db::{self, now_ms};
use crate::error::{invalid, Result};
use crate::jobs::{self, Progress};
use crate::paths;
use crate::scanner::{hash_file, ScanControl};
use crate::text::{fold, like_escape};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;
use walkdir::WalkDir;

const TEXT_EXT: &[&str] = &[
    "txt", "md", "csv", "tsv", "json", "xml", "html", "htm", "log", "ini", "yaml", "yml", "srt",
    "cue", "m3u", "m3u8", "nfo",
];
const MAX_TEXT: usize = 200_000;

pub fn enabled(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "docs_enabled")?
        .map(|v| v == "1")
        .unwrap_or(false))
}

fn require(conn: &Connection) -> Result<()> {
    if !enabled(conn)? {
        return invalid("The personal files module is turned off. Turn it on in Settings first.");
    }
    Ok(())
}

pub fn roots(conn: &Connection) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT r.id, r.path, r.status, r.last_scan_at, (SELECT COUNT(*) FROM documents d WHERE d.root_id=r.id AND d.presence='present') FROM doc_roots r ORDER BY r.path")?;
    let v = stmt
        .query_map([], |r| Ok(json!({"id": r.get::<_, i64>(0)?, "path": r.get::<_, String>(1)?, "status": r.get::<_, String>(2)?, "last_scan_at": r.get::<_, Option<i64>>(3)?, "count": r.get::<_, i64>(4)?})))?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn add_root(conn: &Connection, path: &str) -> Result<()> {
    require(conn)?;
    let p = Path::new(path.trim());
    if !p.is_absolute() || !p.is_dir() {
        return invalid("choose an existing folder");
    }
    let key = paths::path_key_with(path.trim(), paths::CASE_INSENSITIVE);
    for r in crate::library::list_roots(conn)? {
        if paths::key_is_within(
            &key,
            &paths::path_key_with(&r.path, paths::CASE_INSENSITIVE),
        ) {
            return invalid(
                "that folder is inside your music library; personal files are kept separate",
            );
        }
    }
    conn.execute("INSERT OR IGNORE INTO doc_roots(path, path_key, status, added_at) VALUES (?1,?2,'unknown',?3)", params![path.trim(), key, now_ms()])?;
    Ok(())
}

pub fn remove_root(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("DELETE FROM doc_roots WHERE id=?1", params![id])?;
    Ok(())
}

fn docx_text(path: &Path) -> std::result::Result<String, &'static str> {
    let f = std::fs::File::open(path).map_err(|_| "unreadable")?;
    let mut z = zip::ZipArchive::new(f).map_err(|_| "unreadable")?;
    let mut xml = String::new();
    let name = if z.by_name("word/document.xml").is_ok() {
        "word/document.xml"
    } else if z.by_name("content.xml").is_ok() {
        "content.xml"
    } else {
        return Err("not_supported");
    };
    let entry = z.by_name(name).map_err(|_| "unreadable")?;
    if entry.encrypted() {
        return Err("encrypted");
    }
    entry
        .take(4_000_000)
        .read_to_string(&mut xml)
        .map_err(|_| "unreadable")?;
    let mut out = String::new();
    let mut in_tag = false;
    for c in xml.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
        if out.len() > MAX_TEXT {
            break;
        }
    }
    Ok(out.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// Read a document's text where supported. Returns (status, text).
pub fn extract(path: &Path, ext: &str, size: u64) -> (String, Option<String>) {
    if TEXT_EXT.contains(&ext) {
        if size > 20_000_000 {
            return ("too_large".into(), None);
        }
        let mut buf = vec![];
        match std::fs::File::open(path).and_then(|f| f.take(MAX_TEXT as u64).read_to_end(&mut buf))
        {
            Ok(_) => (
                "indexed".into(),
                Some(String::from_utf8_lossy(&buf).to_string()),
            ),
            Err(_) => ("unreadable".into(), None),
        }
    } else if ["docx", "odt"].contains(&ext) {
        // Encrypted Office files are not zip archives but OLE containers.
        let mut magic = [0u8; 8];
        let ole = std::fs::File::open(path)
            .and_then(|mut f| f.read_exact(&mut magic))
            .is_ok()
            && magic == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
        if ole {
            return ("encrypted".into(), None);
        }
        match docx_text(path) {
            Ok(t) => ("indexed".into(), Some(t)),
            Err(e) => (e.into(), None),
        }
    } else if ext == "pdf" {
        let mut head = [0u8; 2048];
        let n = std::fs::File::open(path)
            .and_then(|mut f| f.read(&mut head))
            .unwrap_or(0);
        if String::from_utf8_lossy(&head[..n]).contains("/Encrypt") {
            ("encrypted".into(), None)
        } else {
            ("name_only".into(), None)
        }
    } else if ext == "zip" {
        match std::fs::File::open(path)
            .ok()
            .and_then(|f| zip::ZipArchive::new(f).ok())
        {
            Some(mut z) => {
                let enc = (0..z.len().min(50))
                    .any(|i| z.by_index_raw(i).map(|e| e.encrypted()).unwrap_or(false));
                (if enc { "encrypted" } else { "name_only" }.into(), None)
            }
            None => ("unreadable".into(), None),
        }
    } else {
        ("name_only".into(), None)
    }
}

pub fn scan(db_path: &Path, ctl: &ScanControl, p: &Progress) -> Result<()> {
    let conn = db::open(db_path)?;
    require(&conn)?;
    let roots: Vec<(i64, String)> = conn
        .prepare("SELECT id, path FROM doc_roots")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let scan_start = now_ms();
    for (rid, rpath) in roots {
        let root = Path::new(&rpath);
        if !root.is_dir() {
            conn.execute(
                "UPDATE doc_roots SET status='offline' WHERE id=?1",
                params![rid],
            )?;
            continue;
        }
        conn.execute(
            "UPDATE doc_roots SET status='online' WHERE id=?1",
            params![rid],
        )?;
        for e in WalkDir::new(root)
            .follow_links(false)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            if jobs::wait_or_cancelled(ctl) {
                return Ok(());
            }
            if !e.file_type().is_file() {
                continue;
            }
            let path = e.path();
            let Some(ps) = path.to_str() else { continue };
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with("~$") || name.starts_with("._") {
                continue;
            }
            let ext = path
                .extension()
                .map(|x| x.to_string_lossy().to_ascii_lowercase())
                .unwrap_or_default();
            let md = match e.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            let mtime = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64);
            let key = paths::path_key_with(ps, paths::CASE_INSENSITIVE);
            let unchanged: bool = conn
                .query_row(
                    "SELECT 1 FROM documents WHERE path_key=?1 AND size=?2 AND mtime IS ?3",
                    params![key, md.len() as i64, mtime],
                    |_| Ok(()),
                )
                .is_ok();
            if unchanged {
                conn.execute(
                    "UPDATE documents SET presence='present', last_seen_at=?2 WHERE path_key=?1",
                    params![key, now_ms()],
                )?;
                jobs::tick(p, true);
                continue;
            }
            let (status, text) = extract(path, &ext, md.len());
            let folder = path
                .parent()
                .and_then(|x| x.strip_prefix(root).ok())
                .map(|x| x.to_string_lossy().to_string())
                .unwrap_or_default();
            let search = fold(&format!(
                "{name} {folder} {}",
                text.as_deref().unwrap_or("")
            ));
            conn.execute(
                "INSERT INTO documents(root_id, path, path_key, name, folder, ext, size, mtime, content_status, content, search_text, hash, presence, last_seen_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,NULL,'present',?12)
                 ON CONFLICT(path_key) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, content_status=excluded.content_status, content=excluded.content,
                   search_text=excluded.search_text, hash=NULL, presence='present', last_seen_at=excluded.last_seen_at",
                params![rid, ps, key, name, folder, ext, md.len() as i64, mtime, status, text, search, now_ms()],
            )?;
            jobs::tick(p, status != "unreadable");
        }
        conn.execute(
            "UPDATE documents SET presence='missing' WHERE root_id=?1 AND last_seen_at < ?2",
            params![rid, scan_start],
        )?;
        conn.execute(
            "UPDATE doc_roots SET last_scan_at=?2 WHERE id=?1",
            params![rid, now_ms()],
        )?;
    }
    // Hash same-size files to confirm duplicates.
    let cands: Vec<(i64, String)> = conn
        .prepare("SELECT id, path FROM documents WHERE presence='present' AND hash IS NULL AND size > 0 AND size IN (SELECT size FROM documents WHERE presence='present' GROUP BY size HAVING COUNT(*)>1)")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?;
    for (id, path) in cands {
        if jobs::wait_or_cancelled(ctl) {
            break;
        }
        if let Ok(Some(h)) = hash_file(Path::new(&path), Some(ctl)) {
            conn.execute("UPDATE documents SET hash=?2 WHERE id=?1", params![id, h])?;
        }
    }
    Ok(())
}

pub fn search(conn: &Connection, text: &str, ext: Option<&str>, limit: i64) -> Result<Vec<Value>> {
    require(conn)?;
    let mut sql = "SELECT id, path, name, folder, ext, size, mtime, content_status, content FROM documents WHERE presence='present'".to_string();
    let mut ps: Vec<rusqlite::types::Value> = vec![];
    for tok in text.split_whitespace().take(10).map(fold) {
        ps.push(format!("%{}%", like_escape(&tok)).into());
        sql.push_str(&format!(" AND search_text LIKE ?{} ESCAPE '\\'", ps.len()));
    }
    if let Some(e) = ext.filter(|e| !e.is_empty()) {
        ps.push(e.to_ascii_lowercase().into());
        sql.push_str(&format!(" AND ext = ?{}", ps.len()));
    }
    sql.push_str(&format!(
        " ORDER BY mtime DESC LIMIT {}",
        limit.clamp(1, 1000)
    ));
    let mut stmt = conn.prepare(&sql)?;
    let q = text.split_whitespace().next().map(fold);
    let v = stmt
        .query_map(rusqlite::params_from_iter(ps.iter()), |r| {
            let content: Option<String> = r.get(8)?;
            let snippet = match (&content, &q) {
                (Some(c), Some(q)) => {
                    let f = fold(c);
                    f.find(q.as_str()).map(|i| {
                        let start = f[..i].char_indices().rev().nth(60).map(|x| x.0).unwrap_or(0);
                        f[start..].chars().take(180).collect::<String>()
                    })
                }
                _ => None,
            };
            Ok(json!({"id": r.get::<_, i64>(0)?, "path": r.get::<_, String>(1)?, "name": r.get::<_, String>(2)?, "folder": r.get::<_, String>(3)?, "ext": r.get::<_, String>(4)?,
                "size": r.get::<_, i64>(5)?, "mtime": r.get::<_, Option<i64>>(6)?, "content_status": r.get::<_, String>(7)?, "snippet": snippet}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn report(conn: &Connection) -> Result<Value> {
    require(conn)?;
    let mut stmt = conn.prepare("SELECT content_status, COUNT(*) FROM documents WHERE presence='present' GROUP BY content_status")?;
    let statuses: Vec<Value> = stmt
        .query_map([], |r| {
            Ok(json!({"status": r.get::<_, String>(0)?, "count": r.get::<_, i64>(1)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut stmt = conn.prepare("SELECT hash, GROUP_CONCAT(path, char(31)), MAX(size) FROM documents WHERE presence='present' AND hash IS NOT NULL GROUP BY hash HAVING COUNT(*)>1 LIMIT 500")?;
    let dups: Vec<Value> = stmt
        .query_map([], |r| Ok(json!({"paths": r.get::<_, String>(1)?.split('\u{1f}').collect::<Vec<_>>(), "size": r.get::<_, i64>(2)?})))?
        .collect::<std::result::Result<_, _>>()?;
    let mut stmt = conn.prepare("SELECT ext, COUNT(*), SUM(size) FROM documents WHERE presence='present' GROUP BY ext ORDER BY COUNT(*) DESC LIMIT 30")?;
    let types: Vec<Value> = stmt.query_map([], |r| Ok(json!({"ext": r.get::<_, String>(0)?, "count": r.get::<_, i64>(1)?, "bytes": r.get::<_, i64>(2)?})))?.collect::<std::result::Result<_, _>>()?;
    let mut stmt = conn.prepare("SELECT path, content_status FROM documents WHERE presence='present' AND content_status IN ('encrypted','unreadable') ORDER BY path LIMIT 300")?;
    let flagged: Vec<Value> = stmt
        .query_map([], |r| {
            Ok(json!({"path": r.get::<_, String>(0)?, "status": r.get::<_, String>(1)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    // Organisation suggestions: loose files at a root's top level, grouped by type and year.
    let mut stmt = conn.prepare(
        "SELECT path, ext, mtime FROM documents WHERE presence='present' AND folder='' LIMIT 2000",
    )?;
    let mut sugg: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for r in stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<i64>>(2)?,
        ))
    })? {
        let (path, ext, mtime) = r?;
        let year = mtime.map(|m| 1970 + m / 31_556_952_000).unwrap_or(0);
        let kind = match ext.as_str() {
            "pdf" | "doc" | "docx" | "odt" | "txt" | "md" | "rtf" => "Documents",
            "xls" | "xlsx" | "csv" | "ods" => "Spreadsheets",
            "jpg" | "jpeg" | "png" | "gif" | "heic" | "webp" => "Pictures",
            "zip" | "rar" | "7z" => "Archives",
            _ => "Other",
        };
        sugg.entry(format!("{kind}/{year}")).or_default().push(path);
    }
    let suggestions: Vec<Value> = sugg
        .into_iter()
        .filter(|(_, v)| v.len() >= 3)
        .map(|(k, v)| json!({"folder": k, "count": v.len(), "examples": v.iter().take(3).collect::<Vec<_>>(), "note": "Suggestion only — nothing is moved."}))
        .collect();
    Ok(
        json!({"statuses": statuses, "duplicates": dups, "types": types, "flagged": flagged, "suggestions": suggestions}),
    )
}

pub fn clear(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM documents", [])?;
    conn.execute("DELETE FROM doc_roots", [])?;
    Ok(())
}
