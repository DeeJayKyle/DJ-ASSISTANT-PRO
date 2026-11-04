//! Persisting analysis estimates and running analysis as a background job.
use crate::analysis::{self, Analysis};
use crate::db::{self, now_ms};
use crate::error::Result;
use crate::jobs::{self, Progress};
use crate::scanner::ScanControl;
use crossbeam_channel::bounded;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub fn get(conn: &Connection, id: i64) -> Result<Option<Value>> {
    Ok(conn
        .query_row(
            "SELECT method, version, analysed_at, status, error, bpm, bpm_confidence, bpm_alt, musical_key, camelot, key_confidence, energy,
                    loudness_lufs, peak_dbfs, clipped_runs, silence_start_ms, silence_end_ms, intro_end_ms, outro_start_ms, tempo_stable,
                    cues_json, warnings_json, waveform, duration_ms, fingerprint_encoded IS NOT NULL
             FROM analysis WHERE track_id=?1",
            params![id],
            |r| {
                let wf: Option<Vec<u8>> = r.get(22)?;
                Ok(json!({
                    "method": r.get::<_, String>(0)?, "version": r.get::<_, i64>(1)?, "analysed_at": r.get::<_, i64>(2)?,
                    "status": r.get::<_, String>(3)?, "error": r.get::<_, Option<String>>(4)?,
                    "bpm": r.get::<_, Option<f64>>(5)?, "bpm_confidence": r.get::<_, Option<f64>>(6)?, "bpm_alt": r.get::<_, Option<f64>>(7)?,
                    "key": r.get::<_, Option<String>>(8)?, "camelot": r.get::<_, Option<String>>(9)?, "key_confidence": r.get::<_, Option<f64>>(10)?,
                    "energy": r.get::<_, Option<i64>>(11)?, "loudness_lufs": r.get::<_, Option<f64>>(12)?, "peak_dbfs": r.get::<_, Option<f64>>(13)?,
                    "clipped_runs": r.get::<_, Option<i64>>(14)?, "silence_start_ms": r.get::<_, Option<i64>>(15)?, "silence_end_ms": r.get::<_, Option<i64>>(16)?,
                    "intro_end_ms": r.get::<_, Option<i64>>(17)?, "outro_start_ms": r.get::<_, Option<i64>>(18)?,
                    "tempo_stable": r.get::<_, Option<i64>>(19)?.map(|v| v == 1),
                    "cues": r.get::<_, Option<String>>(20)?.and_then(|s| serde_json::from_str::<Value>(&s).ok()).unwrap_or(json!([])),
                    "warnings": r.get::<_, Option<String>>(21)?.and_then(|s| serde_json::from_str::<Value>(&s).ok()).unwrap_or(json!([])),
                    "waveform": wf.unwrap_or_default(),
                    "duration_ms": r.get::<_, Option<i64>>(23)?,
                    "has_fingerprint": r.get::<_, bool>(24)?,
                }))
            },
        )
        .optional()?)
}

fn fp_to_blob(fp: &[u32]) -> Vec<u8> {
    fp.iter().flat_map(|v| v.to_le_bytes()).collect()
}

pub fn blob_to_fp(b: &[u8]) -> Vec<u32> {
    b.chunks_exact(4)
        .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

pub fn store(
    conn: &Connection,
    id: i64,
    size: i64,
    mtime: Option<i64>,
    res: &std::result::Result<Analysis, String>,
) -> Result<()> {
    match res {
        Ok(a) => {
            conn.execute(
                "INSERT OR REPLACE INTO analysis (track_id, method, version, analysed_at, file_size, file_mtime, status, error, bpm, bpm_confidence, bpm_alt,
                   musical_key, camelot, key_confidence, energy, loudness_lufs, peak_dbfs, clipped_runs, silence_start_ms, silence_end_ms, intro_end_ms,
                   outro_start_ms, tempo_stable, cues_json, warnings_json, waveform, fingerprint, fingerprint_encoded, duration_ms, energy_raw)
                 VALUES (?1,?2,?3,?4,?5,?6,'ok',NULL,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28)",
                params![
                    id,
                    analysis::METHOD,
                    analysis::VERSION,
                    now_ms(),
                    size,
                    mtime,
                    a.bpm,
                    a.bpm_confidence,
                    a.bpm_alt,
                    a.key,
                    a.camelot,
                    a.key_confidence,
                    a.energy,
                    a.loudness_lufs,
                    a.peak_dbfs,
                    a.clipped_runs,
                    a.silence_start_ms,
                    a.silence_end_ms,
                    a.intro_end_ms,
                    a.outro_start_ms,
                    a.tempo_stable.map(|b| b as i64),
                    serde_json::to_string(&a.cues)?,
                    serde_json::to_string(&a.warnings)?,
                    a.waveform,
                    if a.fingerprint.is_empty() { None } else { Some(fp_to_blob(&a.fingerprint)) },
                    a.fingerprint_encoded,
                    a.duration_ms,
                    a.energy_raw
                ],
            )?;
            suggest_from_analysis(conn, id, a)?;
        }
        Err(e) => {
            conn.execute(
                "INSERT OR REPLACE INTO analysis (track_id, method, version, analysed_at, file_size, file_mtime, status, error) VALUES (?1,?2,?3,?4,?5,?6,'error',?7)",
                params![id, analysis::METHOD, analysis::VERSION, now_ms(), size, mtime, e],
            )?;
        }
    }
    Ok(())
}

/// Turn estimates that disagree with (or fill gaps in) file tags into
/// suggestions the DJ can accept into the catalogue.
fn suggest_from_analysis(conn: &Connection, id: i64, a: &Analysis) -> Result<()> {
    let (bpm_tag, key_tag): (Option<f64>, Option<String>) = conn.query_row(
        "SELECT bpm_tag, key_tag FROM tracks WHERE id=?1",
        params![id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let add = |field: &str,
               current: Option<String>,
               value: String,
               evidence: String,
               conf: f64|
     -> Result<()> {
        crate::suggest::insert(
            conn,
            id,
            field,
            current.as_deref(),
            &value,
            "Local analysis",
            &evidence,
            conf,
        )
    };
    if let Some(bpm) = a.bpm {
        let differs = bpm_tag.map(|t| {
            let r = t / bpm;
            ![0.5, 1.0, 2.0].iter().any(|x| (r / x - 1.0).abs() < 0.02)
        });
        if bpm_tag.is_none() || differs == Some(true) {
            let alt = a
                .bpm_alt
                .map(|b| format!(" It could also be heard as {b:.1} BPM (half/double time)."))
                .unwrap_or_default();
            add(
                "bpm",
                bpm_tag.map(|b| format!("{b}")),
                format!("{bpm:.1}"),
                format!("Tempo estimated from the audio.{alt}"),
                a.bpm_confidence,
            )?;
        }
    }
    if let (Some(k), Some(cam)) = (&a.key, &a.camelot) {
        let tag_cam = key_tag.as_deref().and_then(|k| {
            analysis::parse_camelot(k)
                .map(|_| k.to_uppercase())
                .or_else(|| analysis::camelot_for(k).map(|s| s.to_string()))
        });
        if key_tag.is_none() || tag_cam.as_deref() != Some(cam.as_str()) {
            add(
                "key",
                key_tag.clone(),
                cam.clone(),
                format!("Key estimated from the audio: {k} ({cam})."),
                a.key_confidence,
            )?;
        }
    }
    Ok(())
}

/// Scale estimated energy to 1-10 relative to the DJ's own library: half
/// percentile rank, half absolute score. Needs at least 8 analysed tracks.
pub fn rescale_energy(conn: &Connection) -> Result<usize> {
    let mut stmt = conn.prepare("SELECT track_id, energy_raw FROM analysis WHERE status='ok' AND energy_raw IS NOT NULL ORDER BY energy_raw")?;
    let rows: Vec<(i64, f64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?;
    if rows.len() < 8 {
        return Ok(0);
    }
    let n = rows.len() as f64;
    let tx = conn.unchecked_transaction()?;
    {
        let mut up = tx.prepare_cached("UPDATE analysis SET energy=?2 WHERE track_id=?1")?;
        for (i, (id, raw)) in rows.iter().enumerate() {
            let pct = i as f64 / (n - 1.0);
            let e = (1.0 + (0.5 * pct + 0.5 * raw) * 9.0)
                .round()
                .clamp(1.0, 10.0) as i64;
            up.execute(params![id, e])?;
        }
    }
    tx.commit()?;
    Ok(rows.len())
}

pub fn is_current(conn: &Connection, id: i64) -> Result<bool> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM analysis a JOIN tracks t ON t.id=a.track_id WHERE a.track_id=?1 AND a.version=?2 AND a.file_size=t.file_size AND a.file_mtime IS t.file_mtime",
            params![id, analysis::VERSION],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// Tracks needing analysis: readable, present, online, and not analysed with
/// the current version for the current file contents.
pub fn pending_ids(
    conn: &Connection,
    only: Option<&[i64]>,
    force: bool,
) -> Result<Vec<(i64, PathBuf, i64, Option<i64>)>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.path, t.file_size, t.file_mtime FROM tracks t JOIN library_roots r ON r.id=t.root_id LEFT JOIN analysis a ON a.track_id=t.id
         WHERE t.presence='present' AND t.read_status='ok' AND r.status<>'offline'
           AND (?1 OR a.track_id IS NULL OR a.version<>?2 OR a.file_size<>t.file_size OR a.file_mtime IS NOT t.file_mtime)
         ORDER BY t.id",
    )?;
    let rows = stmt
        .query_map(params![force, analysis::VERSION], |r| {
            Ok((
                r.get(0)?,
                PathBuf::from(r.get::<_, String>(1)?),
                r.get(2)?,
                r.get(3)?,
            ))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(match only {
        Some(ids) => rows.into_iter().filter(|r| ids.contains(&r.0)).collect(),
        None => rows,
    })
}

pub fn run_job(
    db_path: &Path,
    only: Option<Vec<i64>>,
    force: bool,
    ctl: &ScanControl,
    p: &Progress,
) -> Result<()> {
    let conn = db::open(db_path)?;
    let todo = pending_ids(&conn, only.as_deref(), force)?;
    jobs::set_total(p, todo.len() as u64);
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
        .clamp(1, 3);
    let (jtx, jrx) = bounded::<(i64, PathBuf, i64, Option<i64>)>(8);
    let (rtx, rrx) = bounded::<(i64, i64, Option<i64>, std::result::Result<Analysis, String>)>(8);
    std::thread::scope(|s| -> Result<()> {
        for _ in 0..workers {
            let (jrx, rtx) = (jrx.clone(), rtx.clone());
            s.spawn(move || {
                for (id, path, size, mtime) in jrx.iter() {
                    if jobs::wait_or_cancelled(ctl) {
                        break;
                    }
                    let res = std::panic::catch_unwind(|| analysis::analyse_file(&path))
                        .unwrap_or_else(|_| Err("analysis failed on this file".into()));
                    if rtx.send((id, size, mtime, res)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(jrx);
        drop(rtx);
        s.spawn(move || {
            for j in todo {
                if ctl.cancel.load(std::sync::atomic::Ordering::Relaxed) || jtx.send(j).is_err() {
                    break;
                }
            }
        });
        for (id, size, mtime, res) in rrx.iter() {
            let ok = res.is_ok();
            store(&conn, id, size, mtime, &res)?;
            jobs::tick(p, ok);
        }
        rescale_energy(&conn)?;
        Ok(())
    })
}
