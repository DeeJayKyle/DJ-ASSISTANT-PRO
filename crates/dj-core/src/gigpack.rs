//! Gig packs: copy approved tracks to a USB stick or drive, verify every copy
//! by hash, and write a manifest, playlists and a missing-file report.
//!
//! Sources are only read. Nothing in the destination is ever overwritten: the
//! pack goes into a new folder (or a new .zip file) that must not already
//! exist, and the destination may not be inside a library folder.
//!
//! Quick Prep uses the same copier with a layout: each track can go into its
//! own sub-folder under a clean file name, with a playlist per folder, as a
//! folder or one ZIP file, and optionally with clean tags written into the
//! copies (see `safe_write::tag_new_copy`; originals are never tagged).
use crate::db::now_ms;
use crate::error::{invalid, Result};
use crate::jobs::{self, Progress};
use crate::paths;
use crate::scanner::{hash_file, ScanControl};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackFile {
    pub n: usize,
    pub track_id: i64,
    pub artist: Option<String>,
    pub title: Option<String>,
    pub source: String,
    pub dest_name: String,
    /// Path inside the pack, with `/` separators ("Music/x.mp3", "House/x.mp3").
    #[serde(default)]
    pub rel_path: String,
    pub size: i64,
    #[serde(default)]
    pub duration_s: Option<i64>,
    pub available: bool,
    pub problem: Option<String>,
    /// Tags to write into the copy, when asked for.
    #[serde(default)]
    pub tags: Option<BTreeMap<String, Option<String>>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PackPlaylist {
    pub name: String,
    /// Where the playlist goes inside the pack ("Playlists/House.m3u8").
    pub path: String,
    pub track_ids: Vec<i64>,
}

/// Where each track goes; omitted tracks use the gig-pack default (`Music/`).
#[derive(Debug, Clone, Deserialize)]
pub struct PackItem {
    pub track_id: i64,
    #[serde(default)]
    pub folder: String,
    /// File name without extension; the original name when omitted.
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct PackOptions {
    #[serde(default)]
    pub items: Option<Vec<PackItem>>,
    #[serde(default)]
    pub playlists: Option<Vec<PackPlaylist>>,
    #[serde(default)]
    pub zip: bool,
    #[serde(default)]
    pub write_tags: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackPlan {
    pub pack_dir: String,
    pub files: Vec<PackFile>,
    pub total_bytes: i64,
    pub free_bytes: Option<u64>,
    pub fits: bool,
    pub missing: usize,
    pub warnings: Vec<String>,
    #[serde(default)]
    pub playlists: Vec<PackPlaylist>,
    #[serde(default)]
    pub zip: bool,
    #[serde(default)]
    pub write_tags: bool,
}

fn sanitize(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| {
            if c.is_control() || r#"<>:"/\|?*"#.contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    let s = s.trim().trim_end_matches('.').to_string();
    if s.is_empty() {
        "DJ Assistant pack".into()
    } else {
        s.chars().take(80).collect()
    }
}

/// One file or folder name: no separators, no reserved Windows names.
fn segment(name: &str, max: usize) -> Option<String> {
    let s: String = name
        .chars()
        .map(|c| {
            if c.is_control() || r#"<>:"/\|?*"#.contains(c) {
                ' '
            } else {
                c
            }
        })
        .collect();
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let s = s
        .trim_end_matches(['.', ' '])
        .trim_start_matches('.')
        .trim()
        .to_string();
    if s.is_empty() {
        return None;
    }
    let mut s: String = s.chars().take(max).collect::<String>().trim().to_string();
    let stem = s.split('.').next().unwrap_or("").to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.as_bytes()[3].is_ascii_digit())
    {
        s.push('_');
    }
    Some(s)
}

/// A relative folder ("Friday Night/Warm Up") made safe; "" for the pack root.
fn folder_path(folder: &str) -> String {
    folder
        .split(['/', '\\'])
        .filter_map(|p| segment(p, 80))
        .collect::<Vec<_>>()
        .join("/")
}

/// Values written into tagged copies: what the catalogue shows (your edits win).
fn tag_values(conn: &Connection, id: i64) -> Result<BTreeMap<String, Option<String>>> {
    let (title, artist, genre, bpm, camelot, version, energy): (Option<String>, Option<String>, Option<String>, Option<f64>, Option<String>, Option<String>, Option<i64>) = conn.query_row(
        "SELECT COALESCE(u.title,t.title,t.file_name), COALESCE(u.artist,t.artist), COALESCE(u.genre,t.genre), COALESCE(u.bpm,t.bpm_tag,a.bpm),
                keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)), COALESCE(u.version_label,t.version_hint), COALESCE(u.energy,a.energy)
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
        params![id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
    )?;
    let musical = crate::db::get_setting(conn, "key_notation")?.as_deref() == Some("musical");
    let key = camelot.as_deref().map(|c| {
        if musical {
            crate::analysis::musical_name(c)
                .map(|m| m.to_string())
                .unwrap_or_else(|| c.to_string())
        } else {
            c.to_string()
        }
    });
    let title = title.map(|t| match &version {
        Some(v) if !t.to_lowercase().contains(&v.to_lowercase()) => format!("{t} ({v})"),
        _ => t,
    });
    let comment = [
        camelot
            .as_deref()
            .map(|c| match crate::analysis::musical_name(c) {
                Some(m) => format!("{c} ({m})"),
                None => c.to_string(),
            }),
        bpm.map(|b| format!("{} BPM", b.round() as i64)),
        energy.map(|e| format!("Energy {e}")),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" · ");
    let mut m = BTreeMap::new();
    m.insert("title".into(), title);
    m.insert("artist".into(), artist);
    m.insert("genre".into(), genre);
    m.insert("bpm".into(), bpm.map(|b| (b.round() as i64).to_string()));
    m.insert("key".into(), key);
    m.insert("comment".into(), (!comment.is_empty()).then_some(comment));
    Ok(m)
}

pub fn preview(conn: &Connection, ids: &[i64], dest: &Path, name: &str) -> Result<PackPlan> {
    preview_with(conn, ids, dest, name, &PackOptions::default())
}

pub fn preview_with(
    conn: &Connection,
    ids: &[i64],
    dest: &Path,
    name: &str,
    opts: &PackOptions,
) -> Result<PackPlan> {
    let layout: Option<HashMap<i64, &PackItem>> = opts
        .items
        .as_ref()
        .map(|items| items.iter().map(|i| (i.track_id, i)).collect());
    let ids: Vec<i64> = match &opts.items {
        Some(items) => items.iter().map(|i| i.track_id).collect(),
        None => ids.to_vec(),
    };
    if ids.is_empty() {
        return invalid("choose some tracks (a crate or a set) first");
    }
    if !dest.is_dir() {
        return invalid("choose a destination folder or drive that exists");
    }
    let dkey = paths::path_key_with(&dest.to_string_lossy(), paths::CASE_INSENSITIVE);
    for r in crate::library::list_roots(conn)? {
        let rk = paths::path_key_with(&r.path, paths::CASE_INSENSITIVE);
        if paths::key_is_within(&dkey, &rk) {
            return invalid(format!("The destination is inside your library folder {}. Choose a separate drive or folder so copies are not catalogued as duplicates.", r.path));
        }
    }
    let base = sanitize(name);
    let pack_dir = if opts.zip {
        dest.join(format!("{base}.zip"))
    } else {
        dest.join(&base)
    };
    let mut warnings = vec![
        "Serato cue points, loops and beatgrids stored inside MP3/M4A/FLAC tags travel with the copied files, but Serato crates and library links do not. This has not been tested with every Serato version — check on the gig laptop before you rely on it.".to_string(),
    ];
    if pack_dir.exists() {
        warnings.push(format!(
            "“{}” already exists there; choose another name. Nothing will be overwritten.",
            pack_dir.display()
        ));
    }
    let mut files = vec![];
    let mut used = HashSet::new();
    let mut total = 0i64;
    let mut missing = 0;
    let mut seen = HashSet::new();
    for (i, id) in ids.iter().enumerate() {
        if !seen.insert(*id) {
            continue;
        }
        let row: Option<(String, i64, String, Option<String>, Option<String>, String, String, Option<i64>, String)> = conn
            .query_row(
                "SELECT t.path, t.file_size, t.presence, COALESCE(u.artist,t.artist), COALESCE(u.title,t.title), t.file_name, COALESCE(r.status,'unknown'), t.duration_ms, t.media_kind
                 FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?)),
            )
            .ok();
        let Some((src, size, presence, artist, title, file_name, rstatus, duration_ms, media_kind)) =
            row
        else {
            missing += 1;
            continue;
        };
        let item = layout.as_ref().and_then(|l| l.get(id).copied());
        let folder = match item {
            Some(it) => folder_path(&it.folder),
            None => "Music".to_string(),
        };
        let (orig_stem, ext) = match file_name.rsplit_once('.') {
            Some((s, e)) => (s.to_string(), format!(".{e}")),
            None => (file_name.clone(), String::new()),
        };
        let stem = item
            .and_then(|it| it.name.as_deref())
            .and_then(|n| segment(n, 150))
            .unwrap_or(orig_stem);
        let prefix = if folder.is_empty() {
            String::new()
        } else {
            format!("{folder}/")
        };
        let mut dest_name = format!("{stem}{ext}");
        let mut k = 2;
        while !used.insert(format!("{prefix}{dest_name}").to_lowercase()) {
            dest_name = format!("{stem} ({k}){ext}");
            k += 1;
        }
        let exists = Path::new(&src).is_file();
        let problem = if presence != "present" {
            Some("missing from library".to_string())
        } else if rstatus == "offline" || !exists {
            Some("drive offline or file not found".to_string())
        } else {
            None
        };
        if problem.is_some() {
            missing += 1;
        } else {
            total += size;
        }
        let taggable = opts.write_tags
            && media_kind != "video"
            && matches!(ext.to_ascii_lowercase().as_str(), ".mp3" | ".flac" | ".m4a");
        files.push(PackFile {
            n: i + 1,
            track_id: *id,
            artist,
            title,
            source: src,
            rel_path: format!("{prefix}{dest_name}"),
            dest_name,
            size,
            duration_s: duration_ms.map(|d| (d + 500) / 1000),
            available: problem.is_none(),
            problem,
            tags: if taggable {
                Some(tag_values(conn, *id)?)
            } else {
                None
            },
        });
    }
    let playlists = match &opts.playlists {
        Some(p) => p
            .iter()
            .filter(|p| !p.track_ids.is_empty())
            .map(|p| {
                let path = folder_path(p.path.trim_end_matches(".m3u8"));
                PackPlaylist {
                    name: p.name.trim().chars().take(120).collect(),
                    path: format!(
                        "{}.m3u8",
                        if path.is_empty() {
                            "playlist".into()
                        } else {
                            path
                        }
                    ),
                    track_ids: p.track_ids.clone(),
                }
            })
            .collect(),
        None => vec![PackPlaylist {
            name: base.clone(),
            path: "playlist.m3u8".into(),
            track_ids: files.iter().map(|f| f.track_id).collect(),
        }],
    };
    let free = fs4::available_space(dest).ok();
    // Tagged copies can grow a little (new tag frames); ZIPs add headers.
    let need = (total as u64) + 5 * 1024 * 1024 + files.len() as u64 * 64 * 1024;
    let fits = free.map(|f| need <= f).unwrap_or(false);
    if !fits {
        warnings.push(match free {
            Some(f) => format!(
                "Not enough free space: the pack needs {} MB, {} MB available.",
                need / 1_048_576,
                f / 1_048_576
            ),
            None => "Free space on the destination could not be determined.".into(),
        });
    }
    let untaggable = opts.write_tags && files.iter().any(|f| f.tags.is_none() && f.available);
    if untaggable {
        warnings.push("Clean tags are written into MP3, FLAC and M4A copies; other formats are copied unchanged.".into());
    }
    Ok(PackPlan {
        pack_dir: pack_dir.to_string_lossy().to_string(),
        files,
        total_bytes: total,
        free_bytes: free,
        fits,
        missing,
        warnings,
        playlists,
        zip: opts.zip,
        write_tags: opts.write_tags,
    })
}

fn create_new(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
}

/// Hashes what passes through, so a ZIP entry can be checked against its source.
struct HashingReader<R> {
    inner: R,
    hasher: blake3::Hasher,
}
impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}

/// Where the pack is written: a new folder, or a new ZIP being built.
#[allow(clippy::large_enum_variant)] // one per pack, never moved around
enum Sink {
    Dir(PathBuf),
    Zip {
        zw: zip::ZipWriter<std::fs::File>,
        part: PathBuf,
        tmp_dir: PathBuf,
    },
}

impl Sink {
    fn text(&mut self, rel: &str, text: &str) -> Result<()> {
        match self {
            Sink::Dir(root) => {
                let p = root.join(rel);
                if let Some(d) = p.parent() {
                    std::fs::create_dir_all(d)?;
                }
                create_new(&p)?.write_all(text.as_bytes())?;
            }
            Sink::Zip { zw, .. } => {
                zw.start_file(
                    rel,
                    zip::write::SimpleFileOptions::default()
                        .compression_method(zip::CompressionMethod::Deflated),
                )
                .map_err(|e| crate::error::Error::Invalid(format!("zip: {e}")))?;
                zw.write_all(text.as_bytes())?;
            }
        }
        Ok(())
    }

    /// Copies one track; returns (hash of what was stored, tagged).
    fn track(&mut self, f: &PackFile) -> Result<(String, bool)> {
        let src = Path::new(&f.source);
        let md = std::fs::metadata(src)?;
        if md.len() as i64 != f.size {
            return invalid("file changed since the preview");
        }
        // A verified, byte-identical copy first; tags (if any) go into the copy.
        let verified_copy = |dst: &Path| -> Result<String> {
            let mut input = std::fs::File::open(src)?;
            let mut out = create_new(dst)?;
            std::io::copy(&mut input, &mut out)?;
            out.sync_all()?;
            let a = hash_file(src, None)?.unwrap_or_default();
            let b = hash_file(dst, None)?.unwrap_or_default();
            if a != b {
                return invalid("copy did not verify (hash mismatch)");
            }
            Ok(a)
        };
        let tag = |dst: &Path| -> Result<bool> {
            match &f.tags {
                Some(t) => crate::safe_write::tag_new_copy(dst, t),
                None => Ok(false),
            }
        };
        match self {
            Sink::Dir(root) => {
                let dst = root.join(&f.rel_path);
                if let Some(d) = dst.parent() {
                    std::fs::create_dir_all(d)?;
                }
                let h = verified_copy(&dst)?;
                let tagged = tag(&dst)?;
                let h = if tagged {
                    hash_file(&dst, None)?.unwrap_or_default()
                } else {
                    h
                };
                Ok((h, tagged))
            }
            Sink::Zip { zw, tmp_dir, .. } => {
                let opts = zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored)
                    .large_file(f.size > u32::MAX as i64 - 1_048_576);
                if f.tags.is_some() {
                    std::fs::create_dir_all(&*tmp_dir)?;
                    let tmp = tmp_dir.join(format!("{}-{}", f.n, f.dest_name));
                    let res = (|| -> Result<(String, bool)> {
                        verified_copy(&tmp)?;
                        let tagged = tag(&tmp)?;
                        zw.start_file(f.rel_path.as_str(), opts)
                            .map_err(|e| crate::error::Error::Invalid(format!("zip: {e}")))?;
                        let mut r = HashingReader {
                            inner: std::fs::File::open(&tmp)?,
                            hasher: blake3::Hasher::new(),
                        };
                        std::io::copy(&mut r, zw)?;
                        let stored = r.hasher.finalize().to_hex().to_string();
                        if stored != hash_file(&tmp, None)?.unwrap_or_default() {
                            return invalid("zip entry did not verify");
                        }
                        Ok((stored, tagged))
                    })();
                    let _ = std::fs::remove_file(&tmp);
                    res
                } else {
                    zw.start_file(f.rel_path.as_str(), opts)
                        .map_err(|e| crate::error::Error::Invalid(format!("zip: {e}")))?;
                    let mut r = HashingReader {
                        inner: std::fs::File::open(src)?,
                        hasher: blake3::Hasher::new(),
                    };
                    std::io::copy(&mut r, zw)?;
                    let stored = r.hasher.finalize().to_hex().to_string();
                    if stored != hash_file(src, None)?.unwrap_or_default() {
                        return invalid(
                            "zip entry did not verify (the file changed while copying)",
                        );
                    }
                    Ok((stored, false))
                }
            }
        }
    }
}

/// Path from a playlist to a file, both relative to the pack root.
fn relative(from_playlist: &str, to: &str) -> String {
    let from: Vec<&str> = from_playlist.split('/').collect();
    let from_dir = &from[..from.len().saturating_sub(1)];
    let to_parts: Vec<&str> = to.split('/').collect();
    let mut i = 0;
    while i < from_dir.len() && i + 1 < to_parts.len() && from_dir[i] == to_parts[i] {
        i += 1;
    }
    let mut out: Vec<&str> = std::iter::repeat_n("..", from_dir.len() - i).collect();
    out.extend(&to_parts[i..]);
    out.join("/")
}

fn m3u8(pl: &PackPlaylist, done: &HashMap<i64, Value>) -> String {
    let mut s = format!(
        "#EXTM3U\r\n#PLAYLIST:{}\r\n",
        pl.name.replace(['\r', '\n'], " ")
    );
    for id in &pl.track_ids {
        let Some(m) = done.get(id) else { continue };
        let label = match (m["artist"].as_str(), m["title"].as_str()) {
            (Some(a), Some(t)) if !a.is_empty() => format!("{a} - {t}"),
            (_, Some(t)) => t.to_string(),
            _ => String::new(),
        };
        s.push_str(&format!(
            "#EXTINF:{},{}\r\n",
            m["duration_s"].as_i64().unwrap_or(-1),
            label.replace(['\r', '\n'], " ")
        ));
        s.push_str(
            &relative(&pl.path, m["file"].as_str().unwrap_or(""))
                .replace('/', std::path::MAIN_SEPARATOR_STR),
        );
        s.push_str("\r\n");
    }
    s
}

/// Copy and verify. Re-checks the plan so nothing changed since the preview.
pub fn execute(conn: &Connection, plan: &PackPlan, ctl: &ScanControl, p: &Progress) -> Result<()> {
    let pack = PathBuf::from(&plan.pack_dir);
    if pack.exists() {
        return invalid("the pack folder already exists; nothing was copied");
    }
    if !plan.fits {
        return invalid("not enough free space; nothing was copied");
    }
    let mut sink = if plan.zip {
        let part = PathBuf::from(format!("{}.part", plan.pack_dir));
        let tmp_dir = PathBuf::from(format!("{}.tmp", plan.pack_dir));
        if tmp_dir.exists() {
            return invalid(
                "a previous copy left a temporary folder next to the ZIP; remove it and try again",
            );
        }
        Sink::Zip {
            zw: zip::ZipWriter::new(create_new(&part)?),
            part,
            tmp_dir,
        }
    } else {
        std::fs::create_dir_all(&pack)?;
        Sink::Dir(pack.clone())
    };
    let todo: Vec<&PackFile> = plan.files.iter().filter(|f| f.available).collect();
    jobs::set_total(p, todo.len() as u64);
    let mut manifest = vec![];
    let mut failures = vec![];
    let mut tagged = 0;
    for f in todo {
        if jobs::wait_or_cancelled(ctl) {
            break;
        }
        match sink.track(f) {
            Ok((h, t)) => {
                tagged += t as usize;
                manifest.push(json!({"n": f.n, "track_id": f.track_id, "artist": f.artist, "title": f.title, "file": f.rel_path, "source": f.source, "size": f.size, "duration_s": f.duration_s, "blake3": h, "verified": true, "tagged": t}));
                jobs::tick(p, true);
            }
            Err(e) => {
                failures.push(format!("{} — {}", f.source, e));
                jobs::tick(p, false);
            }
        }
    }
    let cancelled = ctl.cancel.load(std::sync::atomic::Ordering::Relaxed);
    // Manifest, playlists and reports (new files inside the new pack only).
    let done: HashMap<i64, Value> = manifest
        .iter()
        .map(|m| (m["track_id"].as_i64().unwrap_or(0), m.clone()))
        .collect();
    for pl in &plan.playlists {
        sink.text(&pl.path, &m3u8(pl, &done))?;
    }
    sink.text("manifest.json", &serde_json::to_string_pretty(&json!({"created_at": now_ms(), "app": format!("DJ Assistant {}", crate::api::APP_VERSION), "files": manifest, "tagged": tagged, "complete": !cancelled && failures.is_empty()}))?)?;
    let mut csv = String::from("#,Artist,Title,File,Size,BLAKE3,Verified,Tagged\r\n");
    for m in &manifest {
        csv.push_str(&format!(
            "{},\"{}\",\"{}\",\"{}\",{},{},yes,{}\r\n",
            m["n"],
            m["artist"].as_str().unwrap_or("").replace('"', "\"\""),
            m["title"].as_str().unwrap_or("").replace('"', "\"\""),
            m["file"].as_str().unwrap_or("").replace('"', "\"\""),
            m["size"],
            m["blake3"].as_str().unwrap_or(""),
            if m["tagged"].as_bool().unwrap_or(false) {
                "yes"
            } else {
                "no"
            }
        ));
    }
    sink.text("manifest.csv", &csv)?;
    let mut miss = String::new();
    for f in plan.files.iter().filter(|f| !f.available) {
        miss.push_str(&format!(
            "MISSING  {} — {}\r\n",
            f.source,
            f.problem.as_deref().unwrap_or("")
        ));
    }
    for e in &failures {
        miss.push_str(&format!("FAILED   {e}\r\n"));
    }
    if cancelled {
        miss.push_str("The copy was cancelled before it finished.\r\n");
    }
    sink.text("missing-and-failed.txt", &miss)?;
    let lists = plan
        .playlists
        .iter()
        .map(|p| p.path.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    sink.text("README.txt", &format!("Made by DJ Assistant.\r\n\r\nThe music files are verified copies (BLAKE3 hashes in manifest.csv){}.\r\nPlaylists: {lists}. Drag a .m3u8 into Serato, or import it in Rekordbox, Traktor or VirtualDJ.\r\n\r\nSerato crates and library links are NOT copied. Cues and beatgrids stored in the files' tags travel with them, but check before the gig.\r\nYour original files were not changed.\r\n", if plan.write_tags { "; clean title, artist, genre, BPM and key were written into the MP3, FLAC and M4A copies only" } else { "" }))?;
    if let Sink::Zip { zw, part, tmp_dir } = sink {
        let file = zw
            .finish()
            .map_err(|e| crate::error::Error::Invalid(format!("zip: {e}")))?;
        file.sync_all()?;
        drop(file);
        let _ = std::fs::remove_dir(&tmp_dir);
        if pack.exists() {
            return invalid(
                "a file with the ZIP's name appeared while copying; the copy is kept as .part",
            );
        }
        std::fs::rename(&part, &pack)?;
    }
    let _ = conn.execute("INSERT INTO settings(key, value) VALUES ('last_gig_pack', ?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![plan.pack_dir]);
    if !failures.is_empty() {
        jobs::message(
            p,
            format!(
                "{} file(s) failed; see missing-and-failed.txt in the pack",
                failures.len()
            ),
        );
    } else if plan.write_tags {
        jobs::message(p, format!("{tagged} copies tagged"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_names_and_relative_paths() {
        assert_eq!(folder_path("Friday Night/Warm Up"), "Friday Night/Warm Up");
        assert_eq!(folder_path("../a/./b:c//"), "a/b c");
        assert_eq!(segment("CON", 80).unwrap(), "CON_");
        assert_eq!(segment(" what? ", 80).unwrap(), "what");
        assert!(segment("...", 80).is_none());
        assert_eq!(
            relative("Playlists/House.m3u8", "House/Deep/a.mp3"),
            "../House/Deep/a.mp3"
        );
        assert_eq!(
            relative("My Set/My Set.m3u8", "My Set/01 a.mp3"),
            "01 a.mp3"
        );
        assert_eq!(relative("playlist.m3u8", "Music/a.mp3"), "Music/a.mp3");
    }
}
