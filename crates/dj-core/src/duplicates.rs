//! Conservative duplicate review.
//!
//! * `exact`: identical full-file BLAKE3 hash (every byte compared via hash).
//! * `possible`: same normalised artist + title, same version labels and
//!   durations within a tolerance. Needs the DJ's review.
//! * `alternate`: same normalised artist + title but different version labels
//!   (remix, live, clean, radio edit, ...). Likely intentional.
//!
//! Nothing here deletes, merges or modifies files.
use crate::db::now_ms;
use crate::error::{invalid, Result};
use crate::library;
use crate::scanner::{hash_file, ScanControl};
use rusqlite::{params, Connection};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

type Member = (i64, Option<i64>, String);

pub const DURATION_TOLERANCE_MS: i64 = 2_000;

#[derive(Debug, Clone, Serialize)]
pub struct DupGroup {
    pub kind: String,
    pub key: String,
    pub reason: String,
    pub decision: Option<String>,
    pub tracks: Vec<library::TrackRow>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct HashProgress {
    pub state: String,
    pub candidates: u64,
    pub hashed: u64,
    pub errors: u64,
    pub skipped_offline: u64,
}

/// Hash every present, online file that shares its exact byte size with at
/// least one other file (only those can be byte-identical). Hashes are
/// cached and invalidated when size or modification time changes.
pub fn hash_candidates(
    conn: &Connection,
    ctl: &ScanControl,
    progress: &Mutex<HashProgress>,
) -> Result<HashProgress> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.path, t.file_size, t.file_mtime FROM tracks t JOIN library_roots r ON r.id=t.root_id
         WHERE t.presence='present' AND r.status<>'offline' AND t.file_size > 0
           AND t.file_size IN (SELECT file_size FROM tracks WHERE presence='present' GROUP BY file_size HAVING COUNT(*) > 1)
           AND (t.content_hash IS NULL OR t.hash_size IS NOT t.file_size OR t.hash_mtime IS NOT t.file_mtime)",
    )?;
    let todo: Vec<(i64, String, i64, Option<i64>)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<std::result::Result<_, _>>()?;
    {
        let mut p = progress.lock().unwrap_or_else(|e| e.into_inner());
        *p = HashProgress {
            state: "running".into(),
            candidates: todo.len() as u64,
            ..Default::default()
        };
    }
    for (id, path, size, mtime) in todo {
        if ctl.cancel.load(std::sync::atomic::Ordering::Relaxed) {
            break;
        }
        // Re-check the file is unchanged since the scan before trusting the hash.
        let md = std::fs::metadata(&path);
        let still_same = md
            .as_ref()
            .ok()
            .map(|m| m.len() as i64 == size)
            .unwrap_or(false);
        if !still_same {
            let mut p = progress.lock().unwrap_or_else(|e| e.into_inner());
            p.errors += 1;
            continue;
        }
        match hash_file(Path::new(&path), Some(ctl)) {
            Ok(Some(h)) => {
                conn.execute(
                    "UPDATE tracks SET content_hash=?1, hash_size=?2, hash_mtime=?3 WHERE id=?4",
                    params![h, size, mtime, id],
                )?;
                progress.lock().unwrap_or_else(|e| e.into_inner()).hashed += 1;
            }
            Ok(None) => break,
            Err(_) => progress.lock().unwrap_or_else(|e| e.into_inner()).errors += 1,
        }
    }
    let mut p = progress.lock().unwrap_or_else(|e| e.into_inner());
    p.state = if ctl.cancel.load(std::sync::atomic::Ordering::Relaxed) {
        "cancelled".into()
    } else {
        "completed".into()
    };
    Ok(p.clone())
}

fn rows_by_ids(conn: &Connection, ids: &[i64]) -> Result<Vec<library::TrackRow>> {
    let mut out = Vec::new();
    for id in ids {
        if let Ok(d) = library::track_detail(conn, *id) {
            out.push(d.row);
        }
    }
    Ok(out)
}

fn decisions(conn: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt = conn.prepare("SELECT pair_key, decision FROM duplicate_reviews")?;
    let m = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<HashMap<String, String>, _>>()?;
    Ok(m)
}

pub fn group_key(kind: &str, ids: &[i64]) -> String {
    let mut v = ids.to_vec();
    v.sort_unstable();
    format!(
        "{kind}:{}",
        v.iter()
            .map(|i| i.to_string())
            .collect::<Vec<_>>()
            .join(",")
    )
}

/// Build all duplicate groups from the catalogue. Exact groups require a
/// full-file hash; possible/alternate groups are metadata-based candidates.
pub fn find_groups(conn: &Connection, max_groups: usize) -> Result<Vec<DupGroup>> {
    let dec = decisions(conn)?;
    let mut groups = Vec::new();

    // Exact (full hash)
    let mut stmt = conn.prepare(
        "SELECT content_hash, GROUP_CONCAT(id) FROM tracks WHERE presence='present' AND content_hash IS NOT NULL
           AND hash_size = file_size AND hash_mtime IS file_mtime
         GROUP BY content_hash HAVING COUNT(*) > 1 LIMIT ?1",
    )?;
    let exact: Vec<(String, String)> = stmt
        .query_map(params![max_groups as i64], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let mut exact_sets: Vec<Vec<i64>> = Vec::new();
    for (hash, ids) in exact {
        let ids: Vec<i64> = ids.split(',').filter_map(|s| s.parse().ok()).collect();
        let key = group_key("exact", &ids);
        exact_sets.push(ids.clone());
        groups.push(DupGroup {
            kind: "exact".into(),
            reason: format!(
                "Identical file contents: full-file BLAKE3 hash {}… matches for all {} files.",
                &hash[..12],
                ids.len()
            ),
            decision: dec.get(&key).cloned(),
            key,
            tracks: rows_by_ids(conn, &ids)?,
        });
    }

    // Metadata candidates by work key.
    let mut stmt = conn.prepare(
        "SELECT t.work_key, t.id, t.duration_ms, COALESCE(u.version_label, t.version_hint, '') FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id
         WHERE t.presence='present' AND t.read_status='ok' AND t.work_key IS NOT NULL
           AND t.work_key IN (SELECT work_key FROM tracks WHERE presence='present' AND work_key IS NOT NULL GROUP BY work_key HAVING COUNT(*) > 1)
         ORDER BY t.work_key, t.id",
    )?;
    let rows: Vec<(String, i64, Option<i64>, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<std::result::Result<_, _>>()?;
    let mut by_key: HashMap<String, Vec<Member>> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for (k, id, d, v) in rows {
        if !by_key.contains_key(&k) {
            order.push(k.clone());
        }
        by_key.entry(k).or_default().push((id, d, v));
    }
    for k in order {
        if groups.len() >= max_groups {
            break;
        }
        let members = &by_key[&k];
        // Split into clusters by version label.
        let mut by_version: HashMap<&str, Vec<&Member>> = HashMap::new();
        for m in members {
            by_version.entry(m.2.as_str()).or_default().push(m);
        }
        let (artist, title) = k.split_once('|').unwrap_or(("", &k));
        // Possible duplicates: same version label, durations close.
        for (ver, ms) in &by_version {
            let mut used = vec![false; ms.len()];
            for i in 0..ms.len() {
                if used[i] {
                    continue;
                }
                let mut cluster = vec![ms[i].0];
                let Some(di) = ms[i].1 else { continue };
                for j in (i + 1)..ms.len() {
                    if used[j] {
                        continue;
                    }
                    if let Some(dj) = ms[j].1 {
                        if (di - dj).abs() <= DURATION_TOLERANCE_MS {
                            used[j] = true;
                            cluster.push(ms[j].0);
                        }
                    }
                }
                if cluster.len() > 1 {
                    cluster.sort_unstable();
                    // Skip if every member is already in the same exact group.
                    if exact_sets
                        .iter()
                        .any(|s| cluster.iter().all(|c| s.contains(c)))
                    {
                        continue;
                    }
                    let key = group_key("possible", &cluster);
                    let vtxt = if ver.is_empty() {
                        "no version label".to_string()
                    } else {
                        format!("version label \"{ver}\"")
                    };
                    groups.push(DupGroup {
                        kind: "possible".into(),
                        reason: format!(
                            "Same artist (\"{artist}\") and title (\"{title}\") after normalising case/accents/featuring credits, {vtxt}, and durations within {} s. Contents were not proven identical.",
                            DURATION_TOLERANCE_MS / 1000
                        ),
                        decision: dec.get(&key).cloned(),
                        key,
                        tracks: rows_by_ids(conn, &cluster)?,
                    });
                }
            }
        }
        // Alternate versions: more than one distinct version label.
        if by_version.len() > 1 {
            let mut ids: Vec<i64> = members.iter().map(|m| m.0).collect();
            ids.sort_unstable();
            let mut labels: Vec<&str> = by_version
                .keys()
                .map(|v| if v.is_empty() { "unlabelled" } else { v })
                .collect();
            labels.sort_unstable();
            let key = group_key("alternate", &ids);
            groups.push(DupGroup {
                kind: "alternate".into(),
                reason: format!(
                    "Same artist and title but different version labels ({}). These are probably intentional alternate versions — review before treating any as a duplicate.",
                    labels.join(", ")
                ),
                decision: dec.get(&key).cloned(),
                key,
                tracks: rows_by_ids(conn, &ids)?,
            });
        }
    }
    Ok(groups)
}

pub fn set_decision(conn: &Connection, key: &str, decision: Option<&str>) -> Result<()> {
    if key.len() > 4000
        || !(key.starts_with("exact:")
            || key.starts_with("possible:")
            || key.starts_with("alternate:"))
    {
        return invalid("invalid group key");
    }
    match decision {
        None => {
            conn.execute(
                "DELETE FROM duplicate_reviews WHERE pair_key=?1",
                params![key],
            )?;
        }
        Some(d)
            if [
                "not_duplicate",
                "intentional_version",
                "confirmed_duplicate",
            ]
            .contains(&d) =>
        {
            conn.execute(
                "INSERT INTO duplicate_reviews(pair_key, decision, decided_at) VALUES (?1,?2,?3) ON CONFLICT(pair_key) DO UPDATE SET decision=excluded.decision, decided_at=excluded.decided_at",
                params![key, d, now_ms()],
            )?;
        }
        Some(_) => return invalid("unknown decision"),
    }
    Ok(())
}
