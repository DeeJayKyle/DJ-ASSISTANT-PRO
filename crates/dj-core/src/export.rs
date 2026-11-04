//! Exports: M3U8 playlists and CSV lists. These write ONLY the new file the
//! DJ chose in a save dialog; music files are never touched. An existing file
//! is never overwritten unless `overwrite` is set (the save dialog asked).
use crate::error::{invalid, Result};
use crate::library::{self};
use rusqlite::Connection;
use std::io::Write;
use std::path::Path;

fn guard(path: &Path, overwrite: bool, allowed_ext: &[&str]) -> Result<()> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    if !allowed_ext.contains(&ext.as_str()) {
        return invalid(format!("file must end with .{}", allowed_ext.join(" or .")));
    }
    if crate::metadata::classify_extension(&ext) != crate::metadata::ExtKind::Other {
        return invalid("refusing to write to an audio file");
    }
    if path.exists() && !overwrite {
        return invalid("a file with that name already exists");
    }
    Ok(())
}

fn rows(conn: &Connection, ids: &[i64]) -> Result<Vec<library::TrackRow>> {
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Ok(d) = library::track_detail(conn, *id) {
            out.push(d.row);
        }
    }
    Ok(out)
}

/// Write an extended M3U8 playlist. With `relative_to`, paths are written
/// relative to that folder (used by gig packs).
pub fn write_m3u(conn: &Connection, ids: &[i64], path: &Path, overwrite: bool) -> Result<usize> {
    guard(path, overwrite, &["m3u8", "m3u"])?;
    let rows = rows(conn, ids)?;
    let mut f = std::fs::File::create(path)?;
    writeln!(f, "#EXTM3U")?;
    for r in &rows {
        let secs = r.duration_ms.map(|d| d / 1000).unwrap_or(-1);
        let name = format!(
            "{} - {}",
            r.artist.as_deref().unwrap_or("Unknown artist"),
            r.title.as_deref().unwrap_or(&r.file_name)
        );
        writeln!(f, "#EXTINF:{secs},{name}")?;
        writeln!(f, "{}", r.path)?;
    }
    f.sync_all()?;
    Ok(rows.len())
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

pub fn write_csv(conn: &Connection, ids: &[i64], path: &Path, overwrite: bool) -> Result<usize> {
    guard(path, overwrite, &["csv"])?;
    let rows = rows(conn, ids)?;
    let mut f = std::fs::File::create(path)?;
    writeln!(
        f,
        "#,Artist,Title,Version,Genre,Year,BPM,Key,Energy,Rating,Duration,Format,Bitrate,Path"
    )?;
    for (i, r) in rows.iter().enumerate() {
        let o = |v: Option<String>| v.unwrap_or_default();
        let line = [
            (i + 1).to_string(),
            o(r.artist.clone()),
            o(r.title.clone()),
            o(r.version.clone()),
            o(r.genre.clone()),
            o(r.year.map(|v| v.to_string())),
            o(r.bpm.map(|v| format!("{v:.1}"))),
            o(r.key.clone()),
            o(r.energy.map(|v| v.to_string())),
            o(r.rating.map(|v| v.to_string())),
            o(r.duration_ms
                .map(|d| format!("{}:{:02}", d / 60000, (d / 1000) % 60))),
            o(r.format.clone()),
            o(r.bitrate_kbps.map(|v| v.to_string())),
            r.path.clone(),
        ]
        .iter()
        .map(|s| csv_field(s))
        .collect::<Vec<_>>()
        .join(",");
        writeln!(f, "{line}")?;
    }
    f.sync_all()?;
    Ok(rows.len())
}

pub fn write_text(path: &Path, text: &str, overwrite: bool) -> Result<()> {
    guard(path, overwrite, &["txt", "md"])?;
    let mut f = std::fs::File::create(path)?;
    f.write_all(text.as_bytes())?;
    f.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn csv_escaping() {
        assert_eq!(csv_field("a,b"), "\"a,b\"");
        assert_eq!(csv_field("say \"hi\""), "\"say \"\"hi\"\"\"");
        assert_eq!(csv_field("plain"), "plain");
    }
    #[test]
    fn refuses_audio_extensions_and_existing_files() {
        let d = tempfile::tempdir().unwrap();
        assert!(guard(&d.path().join("x.mp3"), true, &["m3u8"]).is_err());
        let p = d.path().join("x.m3u8");
        std::fs::write(&p, "x").unwrap();
        assert!(guard(&p, false, &["m3u8"]).is_err());
        assert!(guard(&p, true, &["m3u8"]).is_ok());
    }
}
