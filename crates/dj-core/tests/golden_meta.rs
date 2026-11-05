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
