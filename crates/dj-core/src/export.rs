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

/// File types the Studio saves (stems, remixes, MIDI, instruments and kits).
pub const STUDIO_EXT: &[&str] = &["wav", "mid", "sfz", "json"];

/// Studio files may be WAV, but an existing audio file is never replaced (it could be music).
fn studio_guard(path: &Path, overwrite: bool) -> Result<()> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    if !STUDIO_EXT.contains(&ext.as_str()) {
        return invalid(format!("file must end with .{}", STUDIO_EXT.join(" or .")));
    }
    if path.exists() && (!overwrite || ext == "wav") {
        return invalid("a file with that name already exists; choose another name");
    }
    Ok(())
}

/// Writes one Studio file the DJ chose in a save dialog (it already asked about replacing).
/// Writes beside the target and renames, so a half-written file is never left behind.
pub fn write_bytes(path: &Path, bytes: &[u8], overwrite: bool) -> Result<()> {
    studio_guard(path, overwrite)?;
    let mut part = path.as_os_str().to_owned();
    part.push(".part");
    let part = std::path::PathBuf::from(part);
    let written = (|| -> Result<()> {
        let mut f = std::fs::File::create(&part)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(&part, path)?;
        Ok(())
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    written
}

fn safe_segment(s: &str) -> String {
    let t: String = s
        .chars()
        .map(|c| {
            if c.is_control() || r#"<>:"/\|?*"#.contains(c) {
                ' '
            } else {
                c
            }
        })
        .collect();
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    let t = t.trim_matches(|c: char| c == '.' || c == ' ').to_string();
    if t.is_empty() {
        "Untitled".into()
    } else {
        t.chars().take(120).collect()
    }
}

/// Makes a NEW folder `name` in `parent` (adding " (2)", " (3)"… if taken) and returns it.
pub fn new_folder(parent: &Path, name: &str) -> Result<std::path::PathBuf> {
    if !parent.is_dir() {
        return invalid("choose a folder that exists");
    }
    let base = safe_segment(name);
    let mut dir = parent.join(&base);
    let mut n = 2;
    while dir.exists() {
        dir = parent.join(format!("{base} ({n})"));
        n += 1;
    }
    std::fs::create_dir(&dir)?;
    Ok(dir)
}

/// Writes a new file inside a folder made by `new_folder` (sub-folders allowed, never outside it).
pub fn write_into(folder: &Path, rel: &str, bytes: &[u8]) -> Result<std::path::PathBuf> {
    let mut path = folder.to_path_buf();
    for seg in rel
        .split(['/', '\\'])
        .filter(|s| !s.is_empty() && *s != "." && *s != "..")
    {
        path.push(safe_segment(seg));
    }
    if path == folder {
        return invalid("missing file name");
    }
    studio_guard(&path, false)?;
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(path)
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
    fn studio_files_go_only_into_new_files_and_folders() {
        let d = tempfile::tempdir().unwrap();
        let dir = new_folder(d.path(), "My: Stems").unwrap();
        assert!(dir.ends_with("My Stems"));
        assert!(new_folder(d.path(), "My: Stems")
            .unwrap()
            .ends_with("My Stems (2)"));
        let p = write_into(&dir, "samples/../Kick 01.wav", b"RIFF").unwrap();
        assert!(p.starts_with(&dir) && p.ends_with("samples/Kick 01.wav"));
        assert!(
            write_into(&dir, "samples/Kick 01.wav", b"x").is_err(),
            "never replaces"
        );
        assert!(write_into(&dir, "evil.exe", b"x").is_err());
        assert!(
            write_bytes(&d.path().join("song.mp3"), b"x", true).is_err(),
            "only Studio file types"
        );
        write_bytes(&d.path().join("mix.wav"), b"RIFF", false).unwrap();
        assert!(
            write_bytes(&d.path().join("mix.wav"), b"RIFF", true).is_err(),
            "an existing WAV is never replaced"
        );
        write_bytes(&d.path().join("song.mid"), b"MThd", false).unwrap();
        assert!(write_bytes(&d.path().join("song.mid"), b"MThd", false).is_err());
        write_bytes(&d.path().join("song.mid"), b"MThd2", true).unwrap();
        assert_eq!(std::fs::read(d.path().join("song.mid")).unwrap(), b"MThd2");
        assert!(
            !d.path().join("song.mid.part").exists() && !d.path().join("mix.wav.part").exists(),
            "no temporary files are left behind"
        );
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
