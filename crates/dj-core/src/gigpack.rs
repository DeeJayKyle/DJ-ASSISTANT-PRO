//! Gig packs: copy approved tracks to a USB stick or drive, verify every copy
//! by hash, and write a manifest, a playlist and a missing-file report.
//!
//! Sources are only read. Nothing in the destination is ever overwritten: the
//! pack goes into a new folder that must not already exist, and the
//! destination may not be inside a library folder.
use crate::db::now_ms;
use crate::error::{invalid, Result};
use crate::jobs::{self, Progress};
use crate::paths;
use crate::scanner::{hash_file, ScanControl};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackFile {
    pub n: usize,
    pub track_id: i64,
    pub artist: Option<String>,
    pub title: Option<String>,
    pub source: String,
    pub dest_name: String,
    pub size: i64,
    pub available: bool,
    pub problem: Option<String>,
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

pub fn preview(conn: &Connection, ids: &[i64], dest: &Path, name: &str) -> Result<PackPlan> {
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
    let pack_dir = dest.join(sanitize(name));
    let mut warnings = vec![
        "Serato cue points, loops and beatgrids stored inside MP3/M4A/FLAC tags travel with the copied files, but Serato crates and library links do not. This has not been tested with every Serato version — check on the gig laptop before you rely on it.".to_string(),
    ];
    if pack_dir.exists() {
        warnings.push(format!("A folder called \"{}\" already exists there; choose another pack name. Nothing will be overwritten.", pack_dir.display()));
    }
    let mut files = vec![];
    let mut used = HashSet::new();
    let mut total = 0i64;
    let mut missing = 0;
    for (i, id) in ids.iter().enumerate() {
        let row: Option<(String, i64, String, Option<String>, Option<String>, String, String)> = conn
            .query_row(
                "SELECT t.path, t.file_size, t.presence, COALESCE(u.artist,t.artist), COALESCE(u.title,t.title), t.file_name, COALESCE(r.status,'unknown')
                 FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?1",
                params![id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
            )
            .ok();
        let Some((src, size, presence, artist, title, file_name, rstatus)) = row else {
            missing += 1;
            continue;
        };
        let mut dest_name = file_name.clone();
        let mut k = 2;
        while !used.insert(dest_name.to_lowercase()) {
            let (stem, ext) = file_name.rsplit_once('.').unwrap_or((&file_name, ""));
            dest_name = format!("{stem} ({k}).{ext}");
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
        files.push(PackFile {
            n: i + 1,
            track_id: *id,
            artist,
            title,
            source: src,
            dest_name,
            size,
            available: problem.is_none(),
            problem,
        });
    }
    let free = fs4::available_space(dest).ok();
    let fits = free
        .map(|f| (total as u64) + 5 * 1024 * 1024 <= f)
        .unwrap_or(false);
    if !fits {
        warnings.push(match free {
            Some(f) => format!(
                "Not enough free space: the pack needs {} MB, {} MB available.",
                total / 1_048_576,
                f / 1_048_576
            ),
            None => "Free space on the destination could not be determined.".into(),
        });
    }
    Ok(PackPlan {
        pack_dir: pack_dir.to_string_lossy().to_string(),
        files,
        total_bytes: total,
        free_bytes: free,
        fits,
        missing,
        warnings,
    })
}

fn create_new(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
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
    let music = pack.join("Music");
    std::fs::create_dir_all(&music)?;
    let todo: Vec<&PackFile> = plan.files.iter().filter(|f| f.available).collect();
    jobs::set_total(p, todo.len() as u64);
    let mut manifest = vec![];
    let mut failures = vec![];
    for f in todo {
        if jobs::wait_or_cancelled(ctl) {
            break;
        }
        let src = Path::new(&f.source);
        let dst = music.join(&f.dest_name);
        let res = (|| -> Result<String> {
            let md = std::fs::metadata(src)?;
            if md.len() as i64 != f.size {
                return invalid("file changed since the preview");
            }
            let mut input = std::fs::File::open(src)?;
            let mut out = create_new(&dst)?;
            std::io::copy(&mut input, &mut out)?;
            out.sync_all()?;
            let a = hash_file(src, None)?.unwrap_or_default();
            let b = hash_file(&dst, None)?.unwrap_or_default();
            if a != b {
                return invalid("copy did not verify (hash mismatch)");
            }
            Ok(a)
        })();
        match res {
            Ok(h) => {
                manifest.push(json!({"n": f.n, "track_id": f.track_id, "artist": f.artist, "title": f.title, "file": format!("Music/{}", f.dest_name), "source": f.source, "size": f.size, "blake3": h, "verified": true}));
                jobs::tick(p, true);
            }
            Err(e) => {
                failures.push(format!("{} — {}", f.source, e));
                jobs::tick(p, false);
            }
        }
    }
    let cancelled = ctl.cancel.load(std::sync::atomic::Ordering::Relaxed);
    // Manifest, playlist and reports (new files inside the new pack folder only).
    let mut mf = create_new(&pack.join("manifest.json"))?;
    mf.write_all(serde_json::to_string_pretty(&json!({"created_at": now_ms(), "app": format!("DJ Assistant {}", crate::api::APP_VERSION), "files": manifest, "complete": !cancelled && failures.is_empty()}))?.as_bytes())?;
    let mut csv = create_new(&pack.join("manifest.csv"))?;
    writeln!(csv, "#,Artist,Title,File,Size,BLAKE3,Verified")?;
    for m in &manifest {
        writeln!(
            csv,
            "{},\"{}\",\"{}\",\"{}\",{},{},yes",
            m["n"],
            m["artist"].as_str().unwrap_or("").replace('"', "\"\""),
            m["title"].as_str().unwrap_or("").replace('"', "\"\""),
            m["file"].as_str().unwrap_or(""),
            m["size"],
            m["blake3"].as_str().unwrap_or("")
        )?;
    }
    let mut pl = create_new(&pack.join("playlist.m3u8"))?;
    writeln!(pl, "#EXTM3U")?;
    for m in &manifest {
        writeln!(
            pl,
            "#EXTINF:-1,{} - {}",
            m["artist"].as_str().unwrap_or(""),
            m["title"].as_str().unwrap_or("")
        )?;
        writeln!(
            pl,
            "{}",
            m["file"]
                .as_str()
                .unwrap_or("")
                .replace('/', std::path::MAIN_SEPARATOR_STR)
        )?;
    }
    let mut miss = create_new(&pack.join("missing-and-failed.txt"))?;
    for f in plan.files.iter().filter(|f| !f.available) {
        writeln!(
            miss,
            "MISSING  {} — {}",
            f.source,
            f.problem.as_deref().unwrap_or("")
        )?;
    }
    for e in &failures {
        writeln!(miss, "FAILED   {e}")?;
    }
    if cancelled {
        writeln!(miss, "The copy was cancelled before it finished.")?;
    }
    let mut rd = create_new(&pack.join("README.txt"))?;
    writeln!(rd, "Gig pack made by DJ Assistant.\n\nMusic/ holds verified copies (BLAKE3 hashes in manifest.csv).\nplaylist.m3u8 lists them in order and can be dragged into Serato or another DJ app.\n\nSerato crates and library links are NOT copied. Cues and beatgrids stored in the files' tags travel with them, but check before the gig.")?;
    let _ = conn.execute("INSERT INTO settings(key, value) VALUES ('last_gig_pack', ?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![plan.pack_dir]);
    if !failures.is_empty() {
        jobs::message(
            p,
            format!(
                "{} file(s) failed; see missing-and-failed.txt in the pack",
                failures.len()
            ),
        );
    }
    Ok(())
}
