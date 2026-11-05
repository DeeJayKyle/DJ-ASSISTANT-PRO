//! Writes what 1.x reads from every fixture file, so DJ Assistant 2.0 (Dart) can be
//! checked against it: `cargo test -p dj-core --test golden_meta -- --ignored`.
use serde_json::{json, Value};
use std::path::Path;

#[test]
#[ignore]
fn write_metadata_golden() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/library");
    let mut out = serde_json::Map::new();
    let mut files: Vec<_> = walkdir::WalkDir::new(&root).into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()).collect();
    files.sort_by(|a, b| a.path().cmp(b.path()));
    for e in files {
        let rel = e.path().strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/");
        let ext = e.path().extension().map(|x| x.to_string_lossy().to_string()).unwrap_or_default();
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
            }),
            Err(err) => json!({"kind": kind, "ok": false, "error": err}),
        };
        out.insert(rel, v);
    }
    let dest = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../dj_assistant_flutter/test/golden/metadata.json");
    std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
    std::fs::write(&dest, serde_json::to_string_pretty(&Value::Object(out)).unwrap()).unwrap();
}
