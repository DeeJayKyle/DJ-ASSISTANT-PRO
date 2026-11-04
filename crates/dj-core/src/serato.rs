//! Read-only Serato import.
//!
//! * Crates: `_Serato_/Subcrates/*.crate` files are parsed defensively (the
//!   format is undocumented and may change) and copied into DJ Assistant as
//!   virtual crates. Serato's files are opened read-only and never written.
//! * History: Serato's own "Export → CSV" history files are imported as play
//!   history. Unknown rows are kept as unmatched entries.
use crate::crates::{self, CrateInput};
use crate::db::now_ms;
use crate::error::{invalid, Result};
use crate::paths;
use crate::text::{base_artist, base_title};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

const MAX_CRATE_BYTES: u64 = 64 * 1024 * 1024;

fn utf16be(b: &[u8]) -> String {
    let units: Vec<u16> = b
        .chunks_exact(2)
        .map(|c| u16::from_be_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&units)
        .trim_end_matches('\0')
        .to_string()
}

/// Parse a Serato .crate file into the track paths it lists.
/// Unknown chunks are skipped; malformed data ends parsing safely.
pub fn parse_crate(bytes: &[u8]) -> Vec<String> {
    fn walk(b: &[u8], out: &mut Vec<String>, depth: usize) {
        let mut i = 0usize;
        while i + 8 <= b.len() {
            let tag = &b[i..i + 4];
            let len = u32::from_be_bytes([b[i + 4], b[i + 5], b[i + 6], b[i + 7]]) as usize;
            let start = i + 8;
            let Some(end) = start.checked_add(len).filter(|e| *e <= b.len()) else {
                break;
            };
            let data = &b[start..end];
            match tag {
                b"otrk" if depth < 3 => walk(data, out, depth + 1),
                b"ptrk" => {
                    let p = utf16be(data);
                    if !p.is_empty() {
                        out.push(p);
                    }
                }
                _ => {}
            }
            i = end;
        }
    }
    let mut out = vec![];
    walk(bytes, &mut out, 0);
    out
}

/// The folder Serato's relative paths are anchored at: the root of the volume
/// that holds the `_Serato_` folder.
fn volume_root(serato_dir: &Path) -> PathBuf {
    let mut root = PathBuf::new();
    for c in serato_dir.components() {
        match c {
            Component::Prefix(_) | Component::RootDir => root.push(c.as_os_str()),
            _ => break,
        }
    }
    root
}

fn crate_name_parts(file_stem: &str) -> Vec<String> {
    file_stem
        .split("%%")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

pub fn import_crates(conn: &Connection, serato_dir: &Path) -> Result<Value> {
    let sub = serato_dir.join("Subcrates");
    if !sub.is_dir() {
        return invalid("That folder has no Subcrates folder. Choose the _Serato_ folder (usually in your Music folder or at the top of an external drive).");
    }
    let root = volume_root(serato_dir);
    // path_key -> track id
    let mut index: HashMap<String, i64> = HashMap::new();
    {
        let mut stmt = conn.prepare("SELECT path_key, id FROM tracks")?;
        for r in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
            let (k, v) = r?;
            index.insert(k, v);
        }
    }
    let find = |name: &str, parent: Option<i64>| -> Result<Option<i64>> {
        Ok(conn
            .query_row(
                "SELECT id FROM crates WHERE name=?1 AND parent_id IS ?2",
                params![name, parent],
                |r| r.get(0),
            )
            .optional()?)
    };
    let top_name = format!("Serato import ({})", serato_dir.display());
    let top = match find(&top_name, None)? {
        Some(id) => id,
        None => {
            crates::create(
                conn,
                &CrateInput {
                    name: top_name.chars().take(120).collect(),
                    kind: "manual".into(),
                    color: Some("purple".into()),
                    category: Some("Imported".into()),
                    parent_id: None,
                    rules: None,
                },
            )?
            .id
        }
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(&sub)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("crate"))
        .collect();
    files.sort();
    let mut report = vec![];
    for f in files {
        let size = std::fs::metadata(&f)?.len();
        if size > MAX_CRATE_BYTES {
            report.push(json!({"crate": f.file_name().map(|n| n.to_string_lossy().to_string()), "error": "file too large"}));
            continue;
        }
        let bytes = std::fs::read(&f)?;
        let paths_in = parse_crate(&bytes);
        let stem = f
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let mut parent = Some(top);
        for part in crate_name_parts(&stem) {
            parent = Some(match find(&part, parent)? {
                Some(id) => id,
                None => {
                    crates::create(
                        conn,
                        &CrateInput {
                            name: part.chars().take(120).collect(),
                            kind: "manual".into(),
                            color: None,
                            category: None,
                            parent_id: parent,
                            rules: None,
                        },
                    )?
                    .id
                }
            });
        }
        let cid = parent.unwrap_or(top);
        let mut matched = vec![];
        let mut unmatched = vec![];
        for p in &paths_in {
            let full = if Path::new(p).is_absolute() {
                PathBuf::from(p)
            } else {
                root.join(p)
            };
            let key = paths::path_key_with(&full.to_string_lossy(), paths::CASE_INSENSITIVE);
            match index.get(&key) {
                Some(id) => matched.push(*id),
                None => unmatched.push(p.clone()),
            }
        }
        crates::add_tracks(conn, cid, &matched)?;
        report.push(json!({"crate": stem.replace("%%", " / "), "tracks": paths_in.len(), "matched": matched.len(), "unmatched": unmatched.len(), "unmatched_sample": unmatched.iter().take(5).collect::<Vec<_>>()}));
    }
    Ok(
        json!({"parent_id": top, "crates": report, "note": "Serato's files were only read. Tracks not in your DJ Assistant library (or on a drive that is not added) are listed as unmatched."}),
    )
}

fn split_csv_line(line: &str) -> Vec<String> {
    let mut out = vec![];
    let mut cur = String::new();
    let mut q = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, q) {
            ('"', true) if chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
            }
            ('"', _) => q = !q,
            (',', false) => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out.into_iter().map(|s| s.trim().to_string()).collect()
}

/// Import a history CSV (Serato "Export" or any CSV with artist/title columns).
pub fn import_history_csv(conn: &Connection, text: &str, session: &str) -> Result<Value> {
    if text.len() > 20_000_000 {
        return invalid("file is too large");
    }
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let header = lines.next().map(split_csv_line).unwrap_or_default();
    let col = |names: &[&str]| {
        header
            .iter()
            .position(|h| names.iter().any(|n| crate::text::fold(h) == *n))
    };
    let (Some(ci_title), ci_artist) = (col(&["name", "title", "song", "track"]), col(&["artist"]))
    else {
        return invalid("Could not find a title/name column in this CSV.");
    };
    let ci_time = col(&["start time", "start", "date", "time", "played"]);
    // artist|title|version -> id (versions never merged)
    let mut index: HashMap<String, i64> = HashMap::new();
    for t in crate::profile::load(conn)? {
        let v = t
            .version
            .clone()
            .unwrap_or_else(|| crate::discovery::version_of(&t.title));
        index.insert(
            format!("{}|{}|{}", base_artist(&t.artist), base_title(&t.title), v),
            t.id,
        );
    }
    let (mut matched, mut unmatched) = (0, 0);
    let now = now_ms();
    for l in lines {
        let f = split_csv_line(l);
        let title = f.get(ci_title).cloned().unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let artist = ci_artist
            .and_then(|i| f.get(i).cloned())
            .unwrap_or_default();
        let played = ci_time.and_then(|i| f.get(i).cloned());
        let id = index
            .get(&format!(
                "{}|{}|{}",
                base_artist(&artist),
                base_title(&title),
                crate::discovery::version_of(&title)
            ))
            .copied();
        if id.is_some() {
            matched += 1;
        } else {
            unmatched += 1;
        }
        conn.execute(
            "INSERT INTO play_history(source, session, track_id, artist, title, played_at, imported_at) VALUES ('csv', ?1, ?2, ?3, ?4, NULL, ?5)",
            params![format!("{session}{}", played.map(|p| format!(" @ {p}")).unwrap_or_default()), id, artist, title, now],
        )?;
    }
    Ok(json!({"matched": matched, "unmatched": unmatched}))
}

pub fn history(conn: &Connection, limit: i64) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT id, source, session, track_id, artist, title, imported_at FROM play_history ORDER BY id DESC LIMIT ?1")?;
    let v = stmt
        .query_map(params![limit.clamp(1, 5000)], |r| {
            Ok(json!({"id": r.get::<_, i64>(0)?, "source": r.get::<_, String>(1)?, "session": r.get::<_, Option<String>>(2)?, "track_id": r.get::<_, Option<i64>>(3)?,
                "artist": r.get::<_, Option<String>>(4)?, "title": r.get::<_, Option<String>>(5)?, "imported_at": r.get::<_, i64>(6)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn clear_history(conn: &Connection) -> Result<usize> {
    Ok(conn.execute("DELETE FROM play_history", [])?)
}

/// Builds a minimal crate file (used by tests).
#[doc(hidden)]
pub fn build_crate_for_tests(paths: &[&str]) -> Vec<u8> {
    let chunk = |tag: &[u8], data: &[u8]| -> Vec<u8> {
        let mut v = tag.to_vec();
        v.extend((data.len() as u32).to_be_bytes());
        v.extend(data);
        v
    };
    let u16be = |s: &str| -> Vec<u8> { s.encode_utf16().flat_map(|u| u.to_be_bytes()).collect() };
    let mut out = chunk(b"vrsn", &u16be("1.0/Serato ScratchLive Crate"));
    out.extend(chunk(b"osrt", &chunk(b"tvcn", &u16be("song"))));
    for p in paths {
        out.extend(chunk(b"otrk", &chunk(b"ptrk", &u16be(p))));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_crates_defensively() {
        let b = build_crate_for_tests(&["Music/Afro/Song.mp3", "Music/Ünïcode/Déjà.mp3"]);
        assert_eq!(
            parse_crate(&b),
            vec!["Music/Afro/Song.mp3", "Music/Ünïcode/Déjà.mp3"]
        );
        // truncated / garbage input must not panic
        assert!(parse_crate(&b[..b.len() - 3]).len() <= 2);
        assert!(parse_crate(b"\xff\xff\xff\xff\xff\xff\xff\xff").is_empty());
        assert!(parse_crate(&[]).is_empty());
    }
    #[test]
    fn csv_split_handles_quotes() {
        assert_eq!(
            split_csv_line(r#"a,"b, c","d ""q""""#),
            vec!["a", "b, c", "d \"q\""]
        );
    }
}
