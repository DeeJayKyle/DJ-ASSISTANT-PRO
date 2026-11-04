//! Opt-in, verified tag writing. This is the ONLY module that changes music
//! files, and it follows the safety process:
//!
//! 1. Off by default (`allow_file_changes` setting).
//! 2. Exact preview of every field change, with Serato warnings.
//! 3. Before writing: the file must be unchanged since the preview
//!    (size, modified time and full hash).
//! 4. A backup copy is made and verified (hash) — if that fails, stop.
//! 5. Tags are written to a temporary copy next to the original; the audio
//!    data region must hash identically and every tag frame we did not edit
//!    (e.g. Serato's GEOB frames with cues and beatgrids) must be preserved.
//!    Only then is the temporary file atomically renamed over the original.
//! 6. Every change is logged with the backup path and can be rolled back.
//!
//! Supported formats: MP3 (ID3v2), FLAC (Vorbis comments), M4A (MP4 atoms).
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use lofty::config::{ParseOptions, WriteOptions};
use lofty::file::AudioFile;
use lofty::prelude::Accessor;
use lofty::tag::items::Timestamp;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub const WRITABLE: &[&str] = &[
    "title", "artist", "album", "genre", "year", "bpm", "key", "comment",
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileStamp {
    pub size: u64,
    pub mtime: Option<i64>,
    pub hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlannedChange {
    pub track_id: i64,
    pub path: String,
    pub format: String,
    pub changes: BTreeMap<String, (Option<String>, Option<String>)>,
    pub stamp: FileStamp,
    pub warnings: Vec<String>,
    pub blocked: Option<String>,
}

pub fn enabled(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "allow_file_changes")?
        .map(|v| v == "1")
        .unwrap_or(false))
}

pub fn stamp(path: &Path) -> std::io::Result<FileStamp> {
    let md = std::fs::metadata(path)?;
    let mtime = md
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64);
    let hash = crate::scanner::hash_file(path, None)?.unwrap_or_default();
    Ok(FileStamp {
        size: md.len(),
        mtime,
        hash,
    })
}

fn kind_of(path: &Path) -> Option<&'static str> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "mp3" => Some("mp3"),
        "flac" => Some("flac"),
        "m4a" | "mp4" | "aac" => Some("m4a"),
        _ => None,
    }
}

/// Current tag values as the writer sees them.
fn read_current(path: &Path, kind: &str) -> std::result::Result<BTreeMap<String, String>, String> {
    let mut f = File::open(path).map_err(|e| e.to_string())?;
    let opts = ParseOptions::new().read_properties(false);
    let mut m = BTreeMap::new();
    let mut put = |k: &str, v: Option<String>| {
        if let Some(v) = v.filter(|s| !s.is_empty()) {
            m.insert(k.to_string(), v);
        }
    };
    match kind {
        "mp3" => {
            let file = lofty::mpeg::MpegFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if let Some(t) = file.id3v2() {
                put("title", t.title().map(|s| s.to_string()));
                put("artist", t.artist().map(|s| s.to_string()));
                put("album", t.album().map(|s| s.to_string()));
                put("genre", t.genre().map(|s| s.to_string()));
                put("comment", t.comment().map(|s| s.to_string()));
                put(
                    "year",
                    t.get_text(&lofty::id3::v2::FrameId::Valid("TDRC".into()))
                        .or_else(|| t.get_text(&lofty::id3::v2::FrameId::Valid("TYER".into())))
                        .map(|s| s.to_string()),
                );
                put(
                    "bpm",
                    t.get_text(&lofty::id3::v2::FrameId::Valid("TBPM".into()))
                        .map(|s| s.to_string()),
                );
                put(
                    "key",
                    t.get_text(&lofty::id3::v2::FrameId::Valid("TKEY".into()))
                        .map(|s| s.to_string()),
                );
            }
        }
        "flac" => {
            let file = lofty::flac::FlacFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if let Some(t) = file.vorbis_comments() {
                for (k, key) in [
                    ("title", "TITLE"),
                    ("artist", "ARTIST"),
                    ("album", "ALBUM"),
                    ("genre", "GENRE"),
                    ("year", "DATE"),
                    ("bpm", "BPM"),
                    ("key", "INITIALKEY"),
                    ("comment", "COMMENT"),
                ] {
                    put(k, t.get(key).map(|s| s.to_string()));
                }
            }
        }
        "m4a" => {
            let file = lofty::mp4::Mp4File::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if let Some(t) = file.ilst() {
                put("title", t.title().map(|s| s.to_string()));
                put("artist", t.artist().map(|s| s.to_string()));
                put("album", t.album().map(|s| s.to_string()));
                put("genre", t.genre().map(|s| s.to_string()));
                put("comment", t.comment().map(|s| s.to_string()));
                put("year", t.date().map(|d| d.year.to_string()));
            }
        }
        _ => return Err("unsupported format".into()),
    }
    Ok(m)
}

/// Build the exact preview for writing `values` (field -> new value, or
/// null to remove) to each track. Nothing is written.
pub fn preview(
    conn: &Connection,
    ids: &[i64],
    values: &BTreeMap<String, Option<String>>,
) -> Result<Vec<PlannedChange>> {
    if !enabled(conn)? {
        return invalid("Writing to music files is turned off. Turn it on in Settings → Safety only if you have backups and have tested on copies.");
    }
    if ids.is_empty() || ids.len() > 500 {
        return invalid("choose between 1 and 500 tracks");
    }
    for k in values.keys() {
        if !WRITABLE.contains(&k.as_str()) {
            return invalid(format!("'{k}' cannot be written to files"));
        }
    }
    let mut out = vec![];
    for id in ids {
        let (path, presence, media): (String, String, String) = conn
            .query_row(
                "SELECT path, presence, media_kind FROM tracks WHERE id=?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .ok_or_else(|| Error::NotFound("track".into()))?;
        let p = Path::new(&path);
        let mut pc = PlannedChange {
            track_id: *id,
            path: path.clone(),
            format: String::new(),
            changes: BTreeMap::new(),
            stamp: FileStamp {
                size: 0,
                mtime: None,
                hash: String::new(),
            },
            warnings: vec![],
            blocked: None,
        };
        if media == "video" {
            pc.blocked =
                Some("Video files are never written. Use catalogue values instead.".into());
            out.push(pc);
            continue;
        }
        let Some(kind) = kind_of(p) else {
            pc.blocked =
                Some("This format is not supported for writing (only MP3, FLAC and M4A).".into());
            out.push(pc);
            continue;
        };
        pc.format = kind.into();
        if presence != "present" || !p.exists() {
            pc.blocked = Some("File is missing or its drive is offline.".into());
            out.push(pc);
            continue;
        }
        match (stamp(p), read_current(p, kind)) {
            (Ok(st), Ok(cur)) => {
                pc.stamp = st;
                for (k, v) in values {
                    let old = cur.get(k).cloned();
                    let new = v
                        .as_ref()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty());
                    if old != new {
                        pc.changes.insert(k.clone(), (old, new));
                    }
                }
                if kind == "mp3" {
                    pc.warnings.push("Serato keeps cue points, loops, beatgrids and overview data inside this file's tags. Only the fields listed will change; every other tag frame is verified to be preserved. Test on a copy first.".into());
                }
                if kind == "m4a" && (values.contains_key("bpm") || values.contains_key("key")) {
                    pc.warnings.push("BPM and key are not written to M4A files in this version; those fields will be skipped.".into());
                    pc.changes.remove("bpm");
                    pc.changes.remove("key");
                }
                if pc.changes.is_empty() {
                    pc.blocked =
                        Some("Nothing to change: the file already has these values.".into());
                }
            }
            (Err(e), _) => pc.blocked = Some(format!("Cannot read file: {e}")),
            (_, Err(e)) => pc.blocked = Some(format!("Cannot read tags: {e}")),
        }
        out.push(pc);
    }
    Ok(out)
}

/// Hash of the audio data only (everything except tag blocks).
pub fn audio_hash(path: &Path, kind: &str) -> std::io::Result<String> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let (start, end) = match kind {
        "mp3" => {
            let mut h = [0u8; 10];
            let mut start = 0u64;
            f.read_exact(&mut h)?;
            if &h[..3] == b"ID3" {
                let size = ((h[6] as u64 & 0x7f) << 21)
                    | ((h[7] as u64 & 0x7f) << 14)
                    | ((h[8] as u64 & 0x7f) << 7)
                    | (h[9] as u64 & 0x7f);
                start = 10 + size + if h[5] & 0x10 != 0 { 10 } else { 0 };
            }
            let mut end = len;
            if len >= 128 {
                f.seek(SeekFrom::Start(len - 128))?;
                let mut t = [0u8; 3];
                f.read_exact(&mut t)?;
                if &t == b"TAG" {
                    end = len - 128;
                }
            }
            // skip zero padding that may follow the tag
            f.seek(SeekFrom::Start(start))?;
            let mut b = [0u8; 1];
            while start < end {
                f.read_exact(&mut b)?;
                if b[0] != 0 {
                    break;
                }
                start += 1;
            }
            (start, end)
        }
        "flac" => {
            f.seek(SeekFrom::Start(4))?;
            let mut pos = 4u64;
            loop {
                let mut h = [0u8; 4];
                f.read_exact(&mut h)?;
                let size = ((h[1] as u64) << 16) | ((h[2] as u64) << 8) | h[3] as u64;
                pos += 4 + size;
                f.seek(SeekFrom::Start(pos))?;
                if h[0] & 0x80 != 0 {
                    break;
                }
            }
            (pos, len)
        }
        "m4a" => {
            // hash the 'mdat' atom payload
            let mut pos = 0u64;
            let mut found = None;
            while pos + 8 <= len {
                f.seek(SeekFrom::Start(pos))?;
                let mut h = [0u8; 8];
                f.read_exact(&mut h)?;
                let mut size = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64;
                let mut hdr = 8;
                if size == 1 {
                    let mut e = [0u8; 8];
                    f.read_exact(&mut e)?;
                    size = u64::from_be_bytes(e);
                    hdr = 16;
                } else if size == 0 {
                    size = len - pos;
                }
                if &h[4..8] == b"mdat" {
                    found = Some((pos + hdr, pos + size));
                    break;
                }
                if size < 8 {
                    break;
                }
                pos += size;
            }
            found.ok_or_else(|| std::io::Error::other("no audio data atom"))?
        }
        _ => return Err(std::io::Error::other("unsupported")),
    };
    f.seek(SeekFrom::Start(start))?;
    let mut hasher = blake3::Hasher::new();
    let mut remaining = end.saturating_sub(start);
    let mut buf = vec![0u8; 1 << 20];
    while remaining > 0 {
        let n = f.read(&mut buf[..remaining.min(1 << 20) as usize])?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        remaining -= n as u64;
    }
    Ok(hasher.finalize().to_hex().to_string())
}

/// Every tag frame/field we were NOT asked to edit, as comparable strings.
fn untouched_fingerprint(
    path: &Path,
    kind: &str,
    edited: &[&str],
) -> std::result::Result<Vec<String>, String> {
    let mut f = File::open(path).map_err(|e| e.to_string())?;
    let opts = ParseOptions::new().read_properties(false);
    let mut v = vec![];
    match kind {
        "mp3" => {
            let ids: Vec<&str> = edited.iter().flat_map(|k| id3_ids(k)).collect();
            let file = lofty::mpeg::MpegFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if let Some(t) = file.id3v2() {
                for fr in t.iter() {
                    let id = fr.id_str().to_string();
                    if !ids.contains(&id.as_str()) {
                        v.push(format!("{fr:?}"));
                    }
                }
            }
        }
        "flac" => {
            let keys: Vec<&str> = edited.iter().map(|k| vorbis_key(k)).collect();
            let file = lofty::flac::FlacFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if let Some(t) = file.vorbis_comments() {
                for (k, val) in t.items() {
                    if !keys.iter().any(|x| x.eq_ignore_ascii_case(k)) {
                        v.push(format!("{k}={val}"));
                    }
                }
            }
            {
                use lofty::ogg::OggPictureStorage;
                v.push(format!("pictures={}", file.pictures().len()));
            }
        }
        "m4a" => {
            let file = lofty::mp4::Mp4File::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            let skip: Vec<&[u8]> = edited.iter().filter_map(|k| mp4_atom(k)).collect();
            if let Some(t) = file.ilst() {
                for a in t {
                    let id = format!("{:?}", a.ident());
                    if !skip.iter().any(|s| {
                        id.contains(&String::from_utf8_lossy(&s[1..]).to_string())
                            && id.contains(
                                &String::from_utf8_lossy(s)
                                    .chars()
                                    .last()
                                    .unwrap()
                                    .to_string(),
                            )
                    }) {
                        v.push(format!("{a:?}"));
                    }
                }
            }
        }
        _ => {}
    }
    v.sort();
    Ok(v)
}

fn id3_ids(k: &str) -> Vec<&'static str> {
    match k {
        "title" => vec!["TIT2"],
        "artist" => vec!["TPE1"],
        "album" => vec!["TALB"],
        "genre" => vec!["TCON"],
        "year" => vec!["TDRC", "TYER"],
        "bpm" => vec!["TBPM"],
        "key" => vec!["TKEY"],
        "comment" => vec!["COMM"],
        _ => vec![],
    }
}
fn vorbis_key(k: &str) -> &'static str {
    match k {
        "title" => "TITLE",
        "artist" => "ARTIST",
        "album" => "ALBUM",
        "genre" => "GENRE",
        "year" => "DATE",
        "bpm" => "BPM",
        "key" => "INITIALKEY",
        _ => "COMMENT",
    }
}
fn mp4_atom(k: &str) -> Option<&'static [u8]> {
    Some(match k {
        "title" => b"\xa9nam",
        "artist" => b"\xa9ART",
        "album" => b"\xa9alb",
        "genre" => b"\xa9gen",
        "year" => b"\xa9day",
        "comment" => b"\xa9cmt",
        _ => return None,
    })
}

fn year_ts(v: &str) -> Option<Timestamp> {
    let y: u16 = v.get(..4)?.parse().ok()?;
    Some(Timestamp {
        year: y,
        ..Default::default()
    })
}

fn write_tags(
    path: &Path,
    kind: &str,
    changes: &BTreeMap<String, (Option<String>, Option<String>)>,
) -> std::result::Result<(), String> {
    use lofty::id3::v2::{Frame, FrameId, TextInformationFrame};
    use lofty::TextEncoding;
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    let opts = ParseOptions::new().read_properties(false);
    match kind {
        "mp3" => {
            let mut file =
                lofty::mpeg::MpegFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if file.id3v2().is_none() {
                file.set_id3v2(lofty::id3::v2::Id3v2Tag::new());
            }
            let t = file.id3v2_mut().unwrap();
            for (k, (_, new)) in changes {
                let set_text =
                    |t: &mut lofty::id3::v2::Id3v2Tag, id: &str, v: &Option<String>| match v {
                        Some(v) => {
                            t.insert(Frame::Text(TextInformationFrame::new(
                                FrameId::Valid(id.to_string().into()),
                                TextEncoding::UTF8,
                                v.clone(),
                            )));
                        }
                        None => {
                            let _ = t.remove(&FrameId::Valid(id.to_string().into())).count();
                        }
                    };
                match k.as_str() {
                    "title" => set_text(t, "TIT2", new),
                    "artist" => set_text(t, "TPE1", new),
                    "album" => set_text(t, "TALB", new),
                    "genre" => set_text(t, "TCON", new),
                    "year" => set_text(t, "TDRC", new),
                    "bpm" => set_text(t, "TBPM", new),
                    "key" => set_text(t, "TKEY", new),
                    "comment" => match new {
                        Some(v) => t.set_comment(v.clone()),
                        None => t.remove_comment(),
                    },
                    _ => {}
                }
            }
            f.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            file.save_to(&mut f, WriteOptions::default())
                .map_err(|e| e.to_string())?;
        }
        "flac" => {
            let mut file =
                lofty::flac::FlacFile::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if file.vorbis_comments().is_none() {
                file.set_vorbis_comments(lofty::ogg::tag::VorbisComments::new());
            }
            let t = file.vorbis_comments_mut().unwrap();
            for (k, (_, new)) in changes {
                let key = vorbis_key(k);
                let _ = t.remove(key).count();
                if let Some(v) = new {
                    t.insert(key.to_string(), v.clone());
                }
            }
            f.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            file.save_to(&mut f, WriteOptions::default())
                .map_err(|e| e.to_string())?;
        }
        "m4a" => {
            let mut file =
                lofty::mp4::Mp4File::read_from(&mut f, opts).map_err(|e| e.to_string())?;
            if file.ilst().is_none() {
                file.set_ilst(lofty::mp4::Ilst::default());
            }
            let t = file.ilst_mut().unwrap();
            for (k, (_, new)) in changes {
                match (k.as_str(), new) {
                    ("title", Some(v)) => t.set_title(v.clone()),
                    ("title", None) => t.remove_title(),
                    ("artist", Some(v)) => t.set_artist(v.clone()),
                    ("artist", None) => t.remove_artist(),
                    ("album", Some(v)) => t.set_album(v.clone()),
                    ("album", None) => t.remove_album(),
                    ("genre", Some(v)) => t.set_genre(v.clone()),
                    ("genre", None) => t.remove_genre(),
                    ("comment", Some(v)) => t.set_comment(v.clone()),
                    ("comment", None) => t.remove_comment(),
                    ("year", Some(v)) => {
                        if let Some(ts) = year_ts(v) {
                            t.set_date(ts)
                        }
                    }
                    ("year", None) => t.remove_date(),
                    _ => {}
                }
            }
            f.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
            file.save_to(&mut f, WriteOptions::default())
                .map_err(|e| e.to_string())?;
        }
        _ => return Err("unsupported".into()),
    }
    f.sync_all().map_err(|e| e.to_string())?;
    Ok(())
}

fn backup_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("backups")
}

fn sibling_temp(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    path.with_file_name(format!(".{name}.djassistant-{}.tmp", now_ms()))
}

/// Apply previously previewed changes. Returns one result per file.
pub fn apply(conn: &Connection, data_dir: &Path, planned: &[PlannedChange]) -> Result<Vec<Value>> {
    if !enabled(conn)? {
        return invalid("Writing to music files is turned off.");
    }
    let mut results = vec![];
    for pc in planned {
        if pc.blocked.is_some() || pc.changes.is_empty() {
            results
                .push(json!({"track_id": pc.track_id, "status": "skipped", "message": pc.blocked}));
            continue;
        }
        let res = apply_one(conn, data_dir, pc);
        match res {
            Ok(change_id) => results
                .push(json!({"track_id": pc.track_id, "status": "done", "change_id": change_id})),
            Err(e) => {
                conn.execute(
                    "INSERT INTO change_log(track_id, path, action, changes_json, status, error, at) VALUES (?1,?2,'tag_write',?3,'failed',?4,?5)",
                    params![pc.track_id, pc.path, serde_json::to_string(&pc.changes)?, e.to_string(), now_ms()],
                )?;
                results.push(
                    json!({"track_id": pc.track_id, "status": "failed", "message": e.to_string()}),
                );
            }
        }
    }
    Ok(results)
}

fn apply_one(conn: &Connection, data_dir: &Path, pc: &PlannedChange) -> Result<i64> {
    let path = Path::new(&pc.path);
    let kind = pc.format.as_str();
    // 3. unchanged since preview?
    let now = stamp(path)?;
    if now != pc.stamp {
        return invalid("The file changed since the preview. Nothing was written; preview again.");
    }
    // 4. verified backup
    let dir = backup_dir(data_dir).join(format!("{}", now_ms() / 86_400_000));
    std::fs::create_dir_all(&dir)?;
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());
    let backup = dir.join(format!("{}-{}-{}", pc.track_id, now_ms(), file_name));
    if backup.exists() {
        return invalid("backup name collision; try again");
    }
    std::fs::copy(path, &backup)
        .map_err(|e| Error::Invalid(format!("Backup failed, nothing was written: {e}")))?;
    let bh = crate::scanner::hash_file(&backup, None)?.unwrap_or_default();
    if bh != pc.stamp.hash {
        let _ = std::fs::remove_file(&backup);
        return invalid("Backup could not be verified, nothing was written.");
    }
    // 5. write to a temporary copy and verify it
    let edited: Vec<&str> = pc.changes.keys().map(|k| k.as_str()).collect();
    let audio_before = audio_hash(path, kind)?;
    let untouched_before = untouched_fingerprint(path, kind, &edited).map_err(Error::Invalid)?;
    let tmp = sibling_temp(path);
    std::fs::copy(path, &tmp)?;
    let verify = (|| -> Result<()> {
        write_tags(&tmp, kind, &pc.changes)
            .map_err(|e| Error::Invalid(format!("writing tags failed: {e}")))?;
        if audio_hash(&tmp, kind)? != audio_before {
            return invalid("verification failed: audio data would change");
        }
        if untouched_fingerprint(&tmp, kind, &edited).map_err(Error::Invalid)? != untouched_before {
            return invalid("verification failed: other tag data (for example Serato cue/beatgrid frames) would not be preserved");
        }
        let after = read_current(&tmp, kind).map_err(Error::Invalid)?;
        for (k, (_, new)) in &pc.changes {
            let got = after.get(k).cloned();
            let ok = match (new, &got) {
                (Some(n), Some(g)) => g == n || (k == "year" && g.starts_with(n.as_str())),
                (None, None) => true,
                _ => false,
            };
            if !ok {
                return invalid(format!("verification failed: {k} reads back as {got:?}"));
            }
        }
        Ok(())
    })();
    if let Err(e) = verify {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    // Final check right before replacing: still unchanged?
    if stamp(path)? != pc.stamp {
        let _ = std::fs::remove_file(&tmp);
        return invalid("The file changed while preparing the update. Nothing was written.");
    }
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return invalid(format!("Could not replace the file (is it open in another app, such as Serato?): {e}. Nothing was written."));
    }
    let after = crate::scanner::hash_file(path, None)?.unwrap_or_default();
    conn.execute(
        "INSERT INTO change_log(track_id, path, action, changes_json, backup_path, before_hash, after_hash, status, at) VALUES (?1,?2,'tag_write',?3,?4,?5,?6,'done',?7)",
        params![pc.track_id, pc.path, serde_json::to_string(&pc.changes)?, backup.to_string_lossy(), pc.stamp.hash, after, now_ms()],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Restore the verified backup for a change, if the file has not been
/// changed again since.
pub fn rollback(conn: &Connection, change_id: i64) -> Result<()> {
    let (track_id, path, backup, before, after, status): (Option<i64>, String, Option<String>, Option<String>, Option<String>, String) = conn
        .query_row("SELECT track_id, path, backup_path, before_hash, after_hash, status FROM change_log WHERE id=?1 AND action='tag_write'", params![change_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?))
        })
        .optional()?
        .ok_or_else(|| Error::NotFound("change".into()))?;
    if status != "done" {
        return invalid("this change cannot be rolled back (it failed or was already rolled back)");
    }
    let (backup, before, after) = (
        backup.unwrap_or_default(),
        before.unwrap_or_default(),
        after.unwrap_or_default(),
    );
    let p = Path::new(&path);
    let current = crate::scanner::hash_file(p, None)?.unwrap_or_default();
    if current != after {
        return invalid("The file has changed since this edit (perhaps by another app). Rolling back would lose those changes, so nothing was done.");
    }
    if crate::scanner::hash_file(Path::new(&backup), None)?.unwrap_or_default() != before {
        return invalid("The backup no longer matches; nothing was done.");
    }
    let tmp = sibling_temp(p);
    std::fs::copy(&backup, &tmp)?;
    if crate::scanner::hash_file(&tmp, None)?.unwrap_or_default() != before {
        let _ = std::fs::remove_file(&tmp);
        return invalid("Restore copy could not be verified; nothing was done.");
    }
    std::fs::rename(&tmp, p).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::Invalid(format!("Could not restore (file in use?): {e}"))
    })?;
    conn.execute(
        "UPDATE change_log SET status='rolled_back' WHERE id=?1",
        params![change_id],
    )?;
    conn.execute(
        "INSERT INTO change_log(track_id, path, action, changes_json, backup_path, before_hash, after_hash, status, at) VALUES (?1,?2,'rollback',?3,?4,?5,?6,'done',?7)",
        params![track_id, path, json!({"rolled_back_change": change_id}).to_string(), backup, after, before, now_ms()],
    )?;
    Ok(())
}

pub fn log(conn: &Connection, limit: i64) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT id, track_id, path, action, changes_json, backup_path, status, error, at FROM change_log ORDER BY id DESC LIMIT ?1")?;
    let v = stmt
        .query_map(params![limit.clamp(1, 1000)], |r| {
            Ok(json!({"id": r.get::<_, i64>(0)?, "track_id": r.get::<_, Option<i64>>(1)?, "path": r.get::<_, String>(2)?, "action": r.get::<_, String>(3)?,
                "changes": serde_json::from_str::<Value>(&r.get::<_, String>(4)?).unwrap_or(Value::Null), "backup_path": r.get::<_, Option<String>>(5)?,
                "status": r.get::<_, String>(6)?, "error": r.get::<_, Option<String>>(7)?, "at": r.get::<_, i64>(8)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}
