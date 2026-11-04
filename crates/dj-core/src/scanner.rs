//! Read-only library scanner.
//!
//! Safety properties (covered by tests):
//! * Source files are only ever opened for reading.
//! * Symlinks/junctions are not followed, so loops are impossible.
//! * Writes to the catalogue happen in short transactions, so a cancelled or
//!   interrupted scan leaves a consistent catalogue.
//! * A root that is unavailable (disconnected drive) is marked offline and its
//!   tracks are kept; tracks are only marked "missing" after a completed scan
//!   of an online root, and never deleted.
use crate::db::{self, now_ms};
use crate::error::{Error, Result};
use crate::metadata::{self, AudioMeta, ExtKind};
use crate::paths;
use crate::text;
use crossbeam_channel::bounded;
use rusqlite::{params, Connection};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};
use walkdir::WalkDir;

#[derive(Default)]
pub struct ScanControl {
    pub cancel: AtomicBool,
    pub pause: AtomicBool,
}

impl ScanControl {
    fn wait_if_paused(&self) {
        while self.pause.load(Ordering::Relaxed) && !self.cancel.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ScanProgress {
    pub state: String, // idle | running | paused | completed | cancelled | failed
    pub scan_id: Option<i64>,
    pub phase: String, // discovering | reading | finalising | done
    pub current_root: Option<String>,
    pub current_path: Option<String>,
    pub files_found: u64,
    pub files_to_read: u64,
    pub files_processed: u64,
    pub added: u64,
    pub updated: u64,
    pub unchanged: u64,
    pub missing: u64,
    pub errors: u64,
    pub offline_roots: u64,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanSummary {
    pub scan_id: i64,
    pub status: String,
    pub files_seen: u64,
    pub added: u64,
    pub updated: u64,
    pub unchanged: u64,
    pub missing: u64,
    pub errors: u64,
    pub offline_roots: u64,
}

struct Candidate {
    path: PathBuf,
    path_str: String,
    key: String,
    rel: String,
    file_name: String,
    ext: String,
    size: i64,
    mtime: Option<i64>,
    unsupported: bool,
    existing_id: Option<i64>,
}

enum ReadOutcome {
    Ok(Box<AudioMeta>),
    Err(String),
    Unsupported,
}

static UID_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn new_uid(seed: &str) -> String {
    let n = UID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let t = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let h = blake3::hash(format!("{seed}|{t}|{n}|{}", std::process::id()).as_bytes());
    h.to_hex()[..20].to_string()
}

fn mtime_ms(md: &std::fs::Metadata) -> Option<i64> {
    md.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
}

struct Ctx<'a> {
    conn: &'a Connection,
    scan_id: i64,
    ctl: &'a ScanControl,
    progress: &'a Mutex<ScanProgress>,
    scan_video: bool,
}

impl Ctx<'_> {
    fn update(&self, f: impl FnOnce(&mut ScanProgress)) {
        if let Ok(mut p) = self.progress.lock() {
            f(&mut p);
            p.state = if self.ctl.pause.load(Ordering::Relaxed) {
                "paused".into()
            } else {
                "running".into()
            };
        }
    }
    fn error(&self, root_id: Option<i64>, path: &str, kind: &str, msg: &str) {
        let _ = self.conn.execute(
            "INSERT INTO scan_errors(scan_id, root_id, path, kind, message, at) VALUES (?1,?2,?3,?4,?5,?6)",
            params![self.scan_id, root_id, path, kind, msg, now_ms()],
        );
        self.update(|p| p.errors += 1);
    }
}

/// Scan the given roots (or all roots when None). Blocks until finished.
pub fn run_scan(
    db_path: &Path,
    root_ids: Option<Vec<i64>>,
    ctl: &ScanControl,
    progress: &Mutex<ScanProgress>,
) -> Result<ScanSummary> {
    let conn = db::open(db_path)?;
    run_scan_with_conn(&conn, root_ids, ctl, progress)
}

pub fn run_scan_with_conn(
    conn: &Connection,
    root_ids: Option<Vec<i64>>,
    ctl: &ScanControl,
    progress: &Mutex<ScanProgress>,
) -> Result<ScanSummary> {
    let started = now_ms();
    conn.execute(
        "INSERT INTO scans(started_at, status) VALUES (?1, 'running')",
        params![started],
    )?;
    let scan_id = conn.last_insert_rowid();
    if let Ok(mut p) = progress.lock() {
        *p = ScanProgress {
            state: "running".into(),
            scan_id: Some(scan_id),
            phase: "discovering".into(),
            started_at: Some(started),
            ..Default::default()
        };
    }
    let scan_video = db::get_setting(conn, "scan_video")?
        .map(|v| v == "1")
        .unwrap_or(true);
    let ctx = Ctx {
        conn,
        scan_id,
        ctl,
        progress,
        scan_video,
    };

    let roots: Vec<(i64, String)> = {
        let mut stmt = conn.prepare("SELECT id, path FROM library_roots ORDER BY id")?;
        let all = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<Vec<(i64, String)>, _>>()?;
        match &root_ids {
            Some(ids) => all.into_iter().filter(|(id, _)| ids.contains(id)).collect(),
            None => all,
        }
    };

    let mut result: Result<()> = Ok(());
    for (root_id, root_path) in &roots {
        if ctl.cancelled() {
            break;
        }
        if let Err(e) = scan_root(&ctx, *root_id, root_path) {
            ctx.error(Some(*root_id), root_path, "scan", &e.to_string());
            result = Err(e);
            break;
        }
    }

    let status = if result.is_err() {
        "failed"
    } else if ctl.cancelled() {
        "cancelled"
    } else {
        "completed"
    };
    let p = progress.lock().map(|p| p.clone()).unwrap_or_default();
    let finished = now_ms();
    conn.execute(
        "UPDATE scans SET finished_at=?1, status=?2, files_seen=?3, tracks_added=?4, tracks_updated=?5, tracks_unchanged=?6, tracks_missing=?7, error_count=?8, message=?9 WHERE id=?10",
        params![
            finished,
            status,
            p.files_found as i64,
            p.added as i64,
            p.updated as i64,
            p.unchanged as i64,
            p.missing as i64,
            p.errors as i64,
            result.as_ref().err().map(|e| e.to_string()),
            scan_id
        ],
    )?;
    if let Ok(mut pp) = progress.lock() {
        pp.state = status.into();
        pp.phase = "done".into();
        pp.finished_at = Some(finished);
        pp.current_path = None;
        pp.message = result.as_ref().err().map(|e| e.to_string());
    }
    Ok(ScanSummary {
        scan_id,
        status: status.into(),
        files_seen: p.files_found,
        added: p.added,
        updated: p.updated,
        unchanged: p.unchanged,
        missing: p.missing,
        errors: p.errors,
        offline_roots: p.offline_roots,
    })
}

fn root_available(path: &Path) -> bool {
    std::fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
}

fn scan_root(ctx: &Ctx, root_id: i64, root_path: &str) -> Result<()> {
    let conn = ctx.conn;
    let root = PathBuf::from(root_path);
    ctx.update(|p| {
        p.current_root = Some(root_path.to_string());
        p.phase = "discovering".into();
    });
    if !root_available(&root) {
        conn.execute(
            "UPDATE library_roots SET status='offline', last_scan_at=?1, last_scan_status='offline' WHERE id=?2",
            params![now_ms(), root_id],
        )?;
        ctx.error(Some(root_id), root_path, "offline", "Folder or drive is not available. Its tracks are kept and shown as offline, not deleted.");
        ctx.update(|p| p.offline_roots += 1);
        return Ok(());
    }
    conn.execute(
        "UPDATE library_roots SET status='online' WHERE id=?1",
        params![root_id],
    )?;

    // Existing catalogue state for this root.
    let mut existing: HashMap<String, (i64, i64, Option<i64>, String)> = HashMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT path_key, id, file_size, file_mtime, read_status FROM tracks WHERE root_id=?1",
        )?;
        let rows = stmt.query_map(params![root_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                (r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?),
            ))
        })?;
        for row in rows {
            let (k, v) = row?;
            existing.insert(k, v);
        }
    }

    // Phase 1: discover files (metadata only, no reads of file contents).
    let mut to_read: Vec<Candidate> = Vec::new();
    let mut unchanged_ids: Vec<i64> = Vec::new();
    let mut seen_keys: HashSet<String> = HashSet::new();
    let walker = WalkDir::new(&root)
        .follow_links(false)
        .same_file_system(false);
    for entry in walker {
        if ctx.ctl.cancelled() {
            return Ok(());
        }
        ctx.ctl.wait_if_paused();
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                let p = e
                    .path()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_else(|| root_path.to_string());
                ctx.error(
                    Some(root_id),
                    &p,
                    "walk",
                    &format!("Could not read folder entry: {e}"),
                );
                continue;
            }
        };
        let ft = entry.file_type();
        if ft.is_symlink() || !ft.is_file() {
            continue;
        }
        let path = entry.path();
        let file_name = entry.file_name().to_string_lossy().to_string();
        if file_name.starts_with("._") {
            continue; // macOS resource-fork sidecar files, not audio.
        }
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default();
        let kind = metadata::classify_extension(&ext);
        if kind == ExtKind::Other
            || (!ctx.scan_video && matches!(kind, ExtKind::Video | ExtKind::UnsupportedVideo))
        {
            continue;
        }
        let Some(path_str) = path.to_str().map(|s| s.to_string()) else {
            ctx.error(
                Some(root_id),
                &path.to_string_lossy(),
                "path",
                "File name contains characters that cannot be stored safely; skipped.",
            );
            continue;
        };
        let key = paths::path_key_with(&path_str, paths::CASE_INSENSITIVE);
        if !seen_keys.insert(key.clone()) {
            continue;
        }
        let md = match entry.metadata() {
            Ok(m) => m,
            Err(e) => {
                ctx.error(
                    Some(root_id),
                    &path_str,
                    "stat",
                    &format!("Could not read file information: {e}"),
                );
                continue;
            }
        };
        let size = md.len() as i64;
        let mtime = mtime_ms(&md);
        ctx.update(|p| p.files_found += 1);
        let prev = existing.get(&key);
        if let Some((id, psize, pmtime, status)) = prev {
            if *psize == size && *pmtime == mtime && status != "error" {
                unchanged_ids.push(*id);
                continue;
            }
        }
        let rel = path
            .strip_prefix(&root)
            .map(|r| r.to_string_lossy().to_string())
            .unwrap_or_else(|_| file_name.clone());
        to_read.push(Candidate {
            path: path.to_path_buf(),
            path_str,
            key,
            rel,
            file_name,
            ext,
            size,
            mtime,
            unsupported: matches!(kind, ExtKind::UnsupportedMusic | ExtKind::UnsupportedVideo),
            existing_id: prev.map(|p| p.0),
        });
    }

    // Unchanged files: confirm presence in short batches.
    for chunk in unchanged_ids.chunks(500) {
        let tx = conn.unchecked_transaction()?;
        {
            let mut stmt = tx.prepare_cached("UPDATE tracks SET presence='present', last_seen_at=?1, last_scan_id=?2 WHERE id=?3")?;
            let now = now_ms();
            for id in chunk {
                stmt.execute(params![now, ctx.scan_id, id])?;
            }
        }
        tx.commit()?;
        ctx.update(|p| p.unchanged += chunk.len() as u64);
    }

    // Phase 2: read metadata with a bounded worker pool; one writer.
    ctx.update(|p| {
        p.phase = "reading".into();
        p.files_to_read += to_read.len() as u64;
    });
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
        .clamp(1, 4);
    let (job_tx, job_rx) = bounded::<(usize, PathBuf, bool)>(64);
    let (res_tx, res_rx) = bounded::<(usize, ReadOutcome)>(64);
    let ctl = ctx.ctl;
    let cancelled_flag = Arc::new(AtomicBool::new(false));
    let write_result: Result<()> = std::thread::scope(|s| {
        for _ in 0..workers {
            let job_rx = job_rx.clone();
            let res_tx = res_tx.clone();
            s.spawn(move || {
                for (idx, path, unsupported) in job_rx.iter() {
                    if ctl.cancelled() {
                        break;
                    }
                    ctl.wait_if_paused();
                    let out = if unsupported {
                        ReadOutcome::Unsupported
                    } else {
                        // catch_unwind guards against a malformed file panicking a parser.
                        match std::panic::catch_unwind(|| metadata::read_media_meta(&path)) {
                            Ok(Ok(m)) => ReadOutcome::Ok(Box::new(m)),
                            Ok(Err(e)) => ReadOutcome::Err(e),
                            Err(_) => ReadOutcome::Err(
                                "parser failed on this file (possibly corrupt)".into(),
                            ),
                        }
                    };
                    if res_tx.send((idx, out)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(job_rx);
        drop(res_tx);
        let jobs: Vec<(usize, PathBuf, bool)> = to_read
            .iter()
            .enumerate()
            .map(|(i, c)| (i, c.path.clone(), c.unsupported))
            .collect();
        let cf = cancelled_flag.clone();
        s.spawn(move || {
            for j in jobs {
                if ctl.cancelled() {
                    cf.store(true, Ordering::Relaxed);
                    break;
                }
                if job_tx.send(j).is_err() {
                    break;
                }
            }
        });

        let mut batch: Vec<(usize, ReadOutcome)> = Vec::with_capacity(100);
        for item in res_rx.iter() {
            batch.push(item);
            if batch.len() >= 100 {
                write_batch(ctx, root_id, &to_read, &mut batch)?;
            }
        }
        write_batch(ctx, root_id, &to_read, &mut batch)?;
        Ok(())
    });
    write_result?;

    if ctx.ctl.cancelled() {
        conn.execute(
            "UPDATE library_roots SET last_scan_at=?1, last_scan_status='cancelled' WHERE id=?2",
            params![now_ms(), root_id],
        )?;
        return Ok(());
    }

    // Phase 3: finalise. Only mark files missing if the root is still
    // reachable (a drive unplugged mid-scan must not look like deletions).
    ctx.update(|p| p.phase = "finalising".into());
    if !root_available(&root) {
        conn.execute("UPDATE library_roots SET status='offline', last_scan_at=?1, last_scan_status='offline' WHERE id=?2", params![now_ms(), root_id])?;
        ctx.error(
            Some(root_id),
            root_path,
            "offline",
            "Folder became unavailable during the scan; no tracks were marked missing.",
        );
        ctx.update(|p| p.offline_roots += 1);
        return Ok(());
    }
    let missing = conn.execute(
        "UPDATE tracks SET presence='missing' WHERE root_id=?1 AND presence='present' AND (last_scan_id IS NULL OR last_scan_id<>?2)",
        params![root_id, ctx.scan_id],
    )?;
    ctx.update(|p| p.missing += missing as u64);
    conn.execute(
        "UPDATE library_roots SET last_scan_at=?1, last_scan_status='completed' WHERE id=?2",
        params![now_ms(), root_id],
    )?;
    Ok(())
}

fn write_batch(
    ctx: &Ctx,
    root_id: i64,
    cands: &[Candidate],
    batch: &mut Vec<(usize, ReadOutcome)>,
) -> Result<()> {
    if batch.is_empty() {
        return Ok(());
    }
    let conn = ctx.conn;
    let now = now_ms();
    let tx = conn.unchecked_transaction()?;
    let mut added = 0u64;
    let mut updated = 0u64;
    let mut errs: Vec<(String, String, String)> = Vec::new();
    {
        let mut ins = tx.prepare_cached(
            "INSERT INTO tracks (uid, root_id, path, path_key, rel_path, file_name, extension, file_size, file_mtime, read_status, read_error, presence,
              format, codec, lossless, duration_ms, bitrate_kbps, sample_rate, bit_depth, channels, title, artist, album, album_artist, genre, year,
              date_text, original_year, track_no, disc_no, composer, label, comment, isrc, bpm_tag, key_tag, version_hint, clean_hint, work_key,
              search_text, first_seen_at, last_seen_at, last_scan_id)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'present',?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,?40,?41)",
        )?;
        let mut upd = tx.prepare_cached(
            "UPDATE tracks SET root_id=?2, path=?3, rel_path=?5, file_name=?6, extension=?7, file_size=?8, file_mtime=?9, read_status=?10, read_error=?11, presence='present',
              format=?12, codec=?13, lossless=?14, duration_ms=?15, bitrate_kbps=?16, sample_rate=?17, bit_depth=?18, channels=?19, title=?20, artist=?21, album=?22,
              album_artist=?23, genre=?24, year=?25, date_text=?26, original_year=?27, track_no=?28, disc_no=?29, composer=?30, label=?31, comment=?32, isrc=?33,
              bpm_tag=?34, key_tag=?35, version_hint=?36, clean_hint=?37, work_key=?38, search_text=?39, last_seen_at=?40, last_scan_id=?41,
              content_hash=CASE WHEN file_size=?8 AND file_mtime IS ?9 THEN content_hash ELSE NULL END
             WHERE id=?1 AND path_key=?4",
        )?;
        let mut media_upd = tx.prepare_cached(
            "UPDATE tracks SET media_kind=?1, video_codec=?2, width=?3, height=?4, frame_rate=?5 WHERE path_key=?6",
        )?;
        for (idx, out) in batch.drain(..) {
            let c = &cands[idx];
            let (status, err, m) = match out {
                ReadOutcome::Ok(m) => ("ok", None, *m),
                ReadOutcome::Err(e) => {
                    errs.push((c.path_str.clone(), "read".into(), e.clone()));
                    ("error", Some(e), AudioMeta::default())
                }
                ReadOutcome::Unsupported => (
                    "unsupported",
                    Some(format!(
                        "{} files are not supported in this version",
                        c.ext.to_uppercase()
                    )),
                    AudioMeta::default(),
                ),
            };
            let label_src = format!(
                "{} {}",
                m.title.as_deref().unwrap_or(""),
                if m.title.is_none() {
                    c.file_name.as_str()
                } else {
                    ""
                }
            );
            let version_hint = text::detect_version_labels(&label_src);
            let clean_hint = text::detect_clean_explicit(&label_src);
            let work_key = match (&m.artist, &m.title) {
                (Some(a), Some(t)) => {
                    let (a, t) = (text::base_artist(a), text::base_title(t));
                    if a.is_empty() || t.is_empty() {
                        None
                    } else {
                        Some(format!("{a}|{t}"))
                    }
                }
                _ => None,
            };
            let search_text = text::fold(
                &[
                    m.title.as_deref(),
                    m.artist.as_deref(),
                    m.album.as_deref(),
                    m.album_artist.as_deref(),
                    m.genre.as_deref(),
                    m.label.as_deref(),
                    m.composer.as_deref(),
                    m.comment.as_deref(),
                    Some(c.file_name.as_str()),
                    version_hint.as_deref(),
                ]
                .iter()
                .flatten()
                .copied()
                .collect::<Vec<_>>()
                .join(" \u{1f} "),
            );
            let lossless = m.lossless.map(|b| b as i64);
            let p_common = params![
                c.existing_id.unwrap_or(0),
                root_id,
                c.path_str,
                c.key,
                c.rel,
                c.file_name,
                c.ext,
                c.size,
                c.mtime,
                status,
                err,
                m.format,
                m.codec,
                lossless,
                m.duration_ms,
                m.bitrate_kbps,
                m.sample_rate,
                m.bit_depth,
                m.channels,
                m.title,
                m.artist,
                m.album,
                m.album_artist,
                m.genre,
                m.year,
                m.date_text,
                m.original_year,
                m.track_no,
                m.disc_no,
                m.composer,
                m.label,
                m.comment,
                m.isrc,
                m.bpm,
                m.key,
                version_hint,
                clean_hint,
                work_key,
                search_text,
                now,
                ctx.scan_id
            ];
            let media = (
                m.media_kind.as_deref().unwrap_or(
                    if metadata::UNSUPPORTED_VIDEO_EXTENSIONS.contains(&c.ext.as_str())
                        || metadata::VIDEO_EXTENSIONS.contains(&c.ext.as_str())
                    {
                        "video"
                    } else {
                        "audio"
                    },
                ),
                &m.video_codec,
                m.width,
                m.height,
                m.frame_rate,
            );
            if c.existing_id.is_some() {
                upd.execute(p_common)?;
                updated += 1;
            } else {
                // Same parameter order, but ?1 is a fresh uid instead of the id.
                let uid = new_uid(&c.key);
                let mut vals: Vec<&dyn rusqlite::ToSql> = p_common.to_vec();
                vals[0] = &uid;
                // INSERT uses ?1 uid, ?2 root ... with ?4 path_key ... identical indices.
                ins.execute(rusqlite::params_from_iter(vals.iter()))?;
                added += 1;
            }
            media_upd.execute(params![media.0, media.1, media.2, media.3, media.4, c.key])?;
        }
    }
    tx.commit()?;
    for (p, k, e) in errs {
        ctx.error(Some(root_id), &p, &k, &e);
    }
    ctx.update(|p| {
        p.added += added;
        p.updated += updated;
        p.files_processed += added + updated;
        p.current_path = None;
    });
    Ok(())
}

/// Compute a full BLAKE3 hash of a file, reading it only.
pub fn hash_file(path: &Path, ctl: Option<&ScanControl>) -> std::io::Result<Option<String>> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if let Some(c) = ctl {
            if c.cancelled() {
                return Ok(None);
            }
        }
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(Some(hasher.finalize().to_hex().to_string()))
}

impl From<std::sync::PoisonError<std::sync::MutexGuard<'_, ScanProgress>>> for Error {
    fn from(_: std::sync::PoisonError<std::sync::MutexGuard<'_, ScanProgress>>) -> Self {
        Error::Busy("scan progress lock poisoned".into())
    }
}
