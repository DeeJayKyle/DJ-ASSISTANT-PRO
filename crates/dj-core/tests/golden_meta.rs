//! Writes what 1.x reads from every fixture file, so DJ Assistant 2.0 (Dart) can be
//! checked against it: `cargo test -p dj-core --test golden_meta -- --ignored`.
use serde_json::{json, Value};
use std::path::Path;

#[test]
#[ignore]
fn write_metadata_golden() {
    write_golden("library", "metadata.json");
    write_golden("video", "video.json");
}

fn write_golden(fixtures: &str, golden: &str) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(fixtures);
    let mut out = serde_json::Map::new();
    let mut files: Vec<_> = walkdir::WalkDir::new(&root)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .collect();
    files.sort_by(|a, b| a.path().cmp(b.path()));
    for e in files {
        let rel = e
            .path()
            .strip_prefix(&root)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let ext = e
            .path()
            .extension()
            .map(|x| x.to_string_lossy().to_string())
            .unwrap_or_default();
        let kind = format!("{:?}", dj_core::metadata::classify_extension(&ext));
        let v: Value = match dj_core::metadata::read_media_meta(e.path()) {
            Ok(m) => json!({
                "kind": kind, "ok": true, "format": m.format, "codec": m.codec, "lossless": m.lossless,
                "duration_ms": m.duration_ms, "bitrate_kbps": m.bitrate_kbps, "sample_rate": m.sample_rate,
                "bit_depth": m.bit_depth, "channels": m.channels, "title": m.title, "artist": m.artist,
                "album": m.album, "album_artist": m.album_artist, "genre": m.genre, "year": m.year,
                "date_text": m.date_text, "original_year": m.original_year, "track_no": m.track_no,
                "disc_no": m.disc_no, "composer": m.composer, "label": m.label, "comment": m.comment,
                "isrc": m.isrc, "bpm": m.bpm, "key": m.key, "media_kind": m.media_kind,
                "video_codec": m.video_codec, "width": m.width, "height": m.height,
                "frame_rate": m.frame_rate,
            }),
            Err(err) => json!({"kind": kind, "ok": false, "error": err}),
        };
        out.insert(rel, v);
    }
    let dest = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../dj_assistant_flutter/test/golden")
        .join(golden);
    std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
    std::fs::write(
        &dest,
        serde_json::to_string_pretty(&Value::Object(out)).unwrap(),
    )
    .unwrap();
}

/// What a 1.x scan stores for each fixture (derived columns included), so the Dart
/// scanner can be checked row for row.
#[test]
#[ignore]
fn write_scan_golden() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/library");
    let conn = dj_core::db::open_in_memory().unwrap();
    dj_core::library::add_root(&conn, root.to_str().unwrap()).unwrap();
    let ctl = dj_core::scanner::ScanControl::default();
    let progress = std::sync::Mutex::new(dj_core::scanner::ScanProgress::default());
    let s = dj_core::scanner::run_scan_with_conn(&conn, None, &ctl, &progress).unwrap();
    let mut stmt = conn
        .prepare(
            "SELECT rel_path, read_status, read_error, version_hint, clean_hint, work_key, search_text,
                    media_kind, presence FROM tracks ORDER BY rel_path",
        )
        .unwrap();
    let mut rows = serde_json::Map::new();
    let it = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?.replace('\\', "/"),
                json!({
                    "read_status": r.get::<_, String>(1)?,
                    "read_error": r.get::<_, Option<String>>(2)?,
                    "version_hint": r.get::<_, Option<String>>(3)?,
                    "clean_hint": r.get::<_, Option<String>>(4)?,
                    "work_key": r.get::<_, Option<String>>(5)?,
                    "search_text": r.get::<_, Option<String>>(6)?,
                    "media_kind": r.get::<_, String>(7)?,
                    "presence": r.get::<_, String>(8)?,
                }),
            ))
        })
        .unwrap();
    for row in it {
        let (k, v) = row.unwrap();
        rows.insert(k, v);
    }
    let out = json!({
        "summary": {"status": s.status, "files_seen": s.files_seen, "added": s.added, "errors": s.errors},
        "tracks": rows,
    });
    std::fs::write(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../dj_assistant_flutter/test/golden/scan.json"),
        serde_json::to_string_pretty(&out).unwrap(),
    )
    .unwrap();
}

/// What 1.x analysis reports for the analysis clips and the lossless library fixtures.
#[test]
#[ignore]
fn write_analysis_golden() {
    let base = Path::new(env!("CARGO_MANIFEST_DIR"));
    let flutter = base.join("../../dj_assistant_flutter");
    let mut files: Vec<(String, std::path::PathBuf)> =
        std::fs::read_dir(flutter.join("test/fixtures/analysis"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .map(|p| {
                (
                    format!("analysis/{}", p.file_name().unwrap().to_string_lossy()),
                    p,
                )
            })
            .collect();
    for f in [
        "Lossless/Low Tide.flac",
        "Lossless/Driftwood.aiff",
        "Lossless/untagged recording.wav",
    ] {
        files.push((
            format!("library/{f}"),
            base.join("tests/fixtures/library").join(f),
        ));
    }
    files.sort();
    let mut out = serde_json::Map::new();
    for (key, path) in files {
        let a = dj_core::analysis::analyse_file(&path).unwrap();
        let mut v = serde_json::to_value(&a).unwrap();
        v["fingerprint"] = json!(a.fingerprint);
        v["fingerprint_encoded"] = json!(a.fingerprint_encoded);
        out.insert(key, v);
    }
    std::fs::write(
        flutter.join("test/golden/analysis.json"),
        serde_json::to_string_pretty(&Value::Object(out)).unwrap(),
    )
    .unwrap();
}

/// A full 1.x analysis job over a scanned folder: stored rows, the suggestions they
/// create and the library-relative energy (needs 8+ tracks).
#[test]
#[ignore]
fn write_analysis_job_golden() {
    let base = Path::new(env!("CARGO_MANIFEST_DIR"));
    let flutter = base.join("../../dj_assistant_flutter");
    let tmp = tempfile::tempdir().unwrap();
    let music = tmp.path().join("Music");
    std::fs::create_dir_all(&music).unwrap();
    for e in std::fs::read_dir(flutter.join("test/fixtures/analysis")).unwrap() {
        let p = e.unwrap().path();
        std::fs::copy(&p, music.join(p.file_name().unwrap())).unwrap();
    }
    for f in ["Low Tide.flac", "Driftwood.aiff", "untagged recording.wav"] {
        std::fs::copy(
            base.join("tests/fixtures/library/Lossless").join(f),
            music.join(f),
        )
        .unwrap();
    }
    let db_path = tmp.path().join("catalogue.sqlite3");
    let conn = dj_core::db::open(&db_path).unwrap();
    dj_core::library::add_root(&conn, music.to_str().unwrap()).unwrap();
    let ctl = dj_core::scanner::ScanControl::default();
    let progress = std::sync::Mutex::new(dj_core::scanner::ScanProgress::default());
    dj_core::scanner::run_scan_with_conn(&conn, None, &ctl, &progress).unwrap();
    // Tags that agree (half time, same key) and tags that disagree.
    conn.execute_batch(
        "UPDATE tracks SET bpm_tag=62, key_tag='Am' WHERE file_name='afro124_amin.flac';
         UPDATE tracks SET bpm_tag=140, key_tag='5A' WHERE file_name='house128_cmaj_stereo.flac';
         UPDATE tracks SET bpm_tag=180.5, key_tag='F#m' WHERE file_name='slow90_fsmin.flac';",
    )
    .unwrap();
    let p: dj_core::jobs::Progress = Default::default();
    dj_core::analysis_store::run_job(&db_path, None, false, &ctl, &p).unwrap();
    let st = dj_core::jobs::lock(&p).clone();
    let rows = |sql: &str| -> Vec<Value> {
        let mut stmt = conn.prepare(sql).unwrap();
        let n = stmt.column_count();
        let names: Vec<String> = (0..n)
            .map(|i| stmt.column_name(i).unwrap().to_string())
            .collect();
        stmt.query_map([], |r| {
            let mut m = serde_json::Map::new();
            for (i, name) in names.iter().enumerate() {
                let v = match r.get_ref(i)? {
                    rusqlite::types::ValueRef::Null => Value::Null,
                    rusqlite::types::ValueRef::Integer(x) => json!(x),
                    rusqlite::types::ValueRef::Real(x) => json!(x),
                    rusqlite::types::ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                    rusqlite::types::ValueRef::Blob(b) => json!(b.len()),
                };
                m.insert(name.clone(), v);
            }
            Ok(Value::Object(m))
        })
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
    };
    let out = json!({
        "job": {"total": st.total, "done": st.done, "errors": st.errors},
        "analysis": rows("SELECT t.file_name, a.method, a.version, a.status, a.error, a.bpm, a.bpm_alt, a.musical_key, a.camelot,
            a.energy, a.energy_raw, a.loudness_lufs, a.peak_dbfs, a.clipped_runs, a.silence_start_ms, a.silence_end_ms,
            a.intro_end_ms, a.outro_start_ms, a.tempo_stable, a.cues_json, a.warnings_json, a.duration_ms, a.fingerprint_encoded,
            length(a.waveform) AS waveform_len, length(a.fingerprint) AS fingerprint_len
            FROM analysis a JOIN tracks t ON t.id=a.track_id ORDER BY t.file_name"),
        "suggestions": rows("SELECT t.file_name, s.field, s.current_value, s.suggested_value, s.source, s.evidence, s.confidence, s.status
            FROM suggestions s JOIN tracks t ON t.id=s.track_id ORDER BY t.file_name, s.field"),
    });
    std::fs::write(
        flutter.join("test/golden/analysis_job.json"),
        serde_json::to_string_pretty(&out).unwrap(),
    )
    .unwrap();
}
