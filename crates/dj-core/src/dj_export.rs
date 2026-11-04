//! Export crates to other DJ software.
//!
//! * Serato: one new `.crate` file per crate in `_Serato_/Subcrates`. Existing
//!   crate files are never overwritten — a name already taken gets
//!   " (DJ Assistant)" added. Serato reads new crates when it next starts, so
//!   export with Serato closed. Serato's database, cues and beatgrids are not
//!   touched.
//! * rekordbox: a rekordbox XML collection with a playlist per crate (folders
//!   kept), for rekordbox's "Imported Library" (rekordbox xml) import. Written
//!   to a new file of the DJ's choosing.
use crate::error::{invalid, Error, Result};
use crate::library::{self, TrackQuery};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::{Component, Path, PathBuf};

struct CrateNode {
    id: i64,
    name: String,
    parent: Option<i64>,
}

fn all_crates(conn: &Connection) -> Result<Vec<CrateNode>> {
    Ok(conn
        .prepare("SELECT id, name, parent_id FROM crates ORDER BY sort_order, id")?
        .query_map([], |r| {
            Ok(CrateNode {
                id: r.get(0)?,
                name: r.get(1)?,
                parent: r.get(2)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}

fn crate_track_ids(conn: &Connection, crate_id: i64) -> Result<Vec<i64>> {
    library::track_ids(
        conn,
        &TrackQuery {
            crate_id: Some(crate_id),
            ..Default::default()
        },
        50_000,
    )
}

/// Crates to export: the chosen ones plus everything nested inside them.
fn selection(all: &[CrateNode], ids: Option<&[i64]>) -> Vec<i64> {
    let Some(ids) = ids else {
        return all.iter().map(|c| c.id).collect();
    };
    let mut out: Vec<i64> = ids.to_vec();
    let mut i = 0;
    while i < out.len() {
        let id = out[i];
        for c in all.iter().filter(|c| c.parent == Some(id)) {
            if !out.contains(&c.id) {
                out.push(c.id);
            }
        }
        i += 1;
    }
    out
}

fn chain(all: &[CrateNode], id: i64) -> Vec<String> {
    let mut names = vec![];
    let mut cur = all.iter().find(|c| c.id == id);
    let mut guard = 0;
    while let Some(c) = cur {
        names.push(c.name.clone());
        cur = c.parent.and_then(|p| all.iter().find(|x| x.id == p));
        guard += 1;
        if guard > 32 {
            break;
        }
    }
    names.reverse();
    names
}

// ------------------------------------------------------------------ Serato

fn chunk(tag: &[u8], data: &[u8]) -> Vec<u8> {
    let mut v = tag.to_vec();
    v.extend((data.len() as u32).to_be_bytes());
    v.extend(data);
    v
}
fn u16be(s: &str) -> Vec<u8> {
    s.encode_utf16().flat_map(|u| u.to_be_bytes()).collect()
}

/// A Serato crate file listing `paths` (relative to the drive root, "/" separated).
pub fn serato_crate_bytes(paths: &[String]) -> Vec<u8> {
    let mut out = chunk(b"vrsn", &u16be("1.0/Serato ScratchLive Crate"));
    out.extend(chunk(
        b"osrt",
        &[chunk(b"tvcn", &u16be("song")), chunk(b"brev", &[0])].concat(),
    ));
    for col in ["song", "artist", "bpm", "key", "length", "genre"] {
        out.extend(chunk(
            b"ovct",
            &[chunk(b"tvcn", &u16be(col)), chunk(b"tvcw", &u16be("0"))].concat(),
        ));
    }
    for p in paths {
        out.extend(chunk(b"otrk", &chunk(b"ptrk", &u16be(p))));
    }
    out
}

fn volume_key(p: &Path) -> String {
    p.components()
        .take_while(|c| matches!(c, Component::Prefix(_) | Component::RootDir))
        .map(|c| c.as_os_str().to_string_lossy().to_ascii_uppercase())
        .collect()
}

/// Path as Serato writes it: relative to the drive root, with "/".
fn serato_rel(track: &Path) -> String {
    track
        .components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("/")
}

pub fn export_serato(
    conn: &Connection,
    serato_dir: &Path,
    crate_ids: Option<&[i64]>,
) -> Result<Value> {
    let name_ok = serato_dir
        .file_name()
        .map(|n| n.to_string_lossy().eq_ignore_ascii_case("_Serato_"))
        .unwrap_or(false);
    if !name_ok {
        return invalid("Choose Serato's _Serato_ folder (in your Music folder, or at the top of an external drive).");
    }
    if !serato_dir.is_dir() {
        return invalid("That _Serato_ folder doesn't exist.");
    }
    let sub = serato_dir.join("Subcrates");
    std::fs::create_dir_all(&sub)
        .map_err(|e| Error::Invalid(format!("couldn't open Subcrates: {e}")))?;
    let vol = volume_key(serato_dir);
    let all = all_crates(conn)?;
    let mut written = vec![];
    let mut skipped_tracks = 0usize;
    for id in selection(&all, crate_ids) {
        let c = all.iter().find(|c| c.id == id).unwrap();
        let ids = crate_track_ids(conn, id)?;
        // A crate that only groups sub-crates has no file of its own.
        if ids.is_empty() && all.iter().any(|x| x.parent == Some(id)) {
            continue;
        }
        let mut paths = vec![];
        for tid in ids {
            let p: String = conn
                .query_row(
                    "SELECT path FROM tracks WHERE id=?1 AND presence='present'",
                    params![tid],
                    |r| r.get(0),
                )
                .unwrap_or_default();
            if p.is_empty() {
                continue;
            }
            let pp = PathBuf::from(&p);
            if volume_key(&pp) != vol {
                skipped_tracks += 1;
                continue;
            }
            paths.push(serato_rel(&pp));
        }
        // Serato nests crates with "%%" in the file name.
        let base = chain(&all, id)
            .iter()
            .map(|n| crate::organize::sanitize(&n.replace("%%", "%")))
            .collect::<Vec<_>>()
            .join("%%");
        let mut file = sub.join(format!("{base}.crate"));
        let mut n = 1;
        while file.exists() {
            file = sub.join(if n == 1 {
                format!("{base} (DJ Assistant).crate")
            } else {
                format!("{base} (DJ Assistant {n}).crate")
            });
            n += 1;
        }
        let tmp = file.with_extension("crate.djassistant-tmp");
        std::fs::write(&tmp, serato_crate_bytes(&paths))
            .map_err(|e| Error::Invalid(format!("couldn't write {}: {e}", file.display())))?;
        std::fs::rename(&tmp, &file)
            .map_err(|e| Error::Invalid(format!("couldn't finish {}: {e}", file.display())))?;
        written.push(json!({"crate": c.name, "file": file.file_name().map(|f| f.to_string_lossy().to_string()), "tracks": paths.len()}));
    }
    Ok(
        json!({"written": written, "skipped_other_drive": skipped_tracks,
        "note": "Start Serato to see the crates. Tracks on other drives belong in that drive's own _Serato_ folder."}),
    )
}

// ---------------------------------------------------------------- rekordbox

fn xml_escape(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_control() || *c == '\t')
        .map(|c| match c {
            '&' => "&amp;".to_string(),
            '<' => "&lt;".to_string(),
            '>' => "&gt;".to_string(),
            '"' => "&quot;".to_string(),
            '\'' => "&apos;".to_string(),
            c => c.to_string(),
        })
        .collect()
}

/// file://localhost/C:/Music/My%20Track.mp3
pub fn file_url(path: &str) -> String {
    let p = path.replace('\\', "/");
    let mut out = String::from("file://localhost");
    if !p.starts_with('/') {
        out.push('/');
    }
    for b in p.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' | b':' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub fn export_rekordbox(
    conn: &Connection,
    dest: &Path,
    crate_ids: Option<&[i64]>,
    version: &str,
) -> Result<Value> {
    if dest.exists() {
        return invalid("A file with that name already exists; choose a new name.");
    }
    if dest
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| !e.eq_ignore_ascii_case("xml"))
        .unwrap_or(true)
    {
        return invalid("the rekordbox file must end in .xml");
    }
    let all = all_crates(conn)?;
    let sel = selection(&all, crate_ids);
    let mut track_ids: Vec<i64> = vec![];
    let mut members: std::collections::HashMap<i64, Vec<i64>> = Default::default();
    for &id in &sel {
        let ids = crate_track_ids(conn, id)?;
        for t in &ids {
            if !track_ids.contains(t) {
                track_ids.push(*t);
            }
        }
        members.insert(id, ids);
    }
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<DJ_PLAYLISTS Version=\"1.0.0\">\n",
    );
    xml.push_str(&format!(
        "  <PRODUCT Name=\"DJ Assistant\" Version=\"{}\" Company=\"DJ Assistant\"/>\n",
        xml_escape(version)
    ));
    let mut tracks_xml = String::new();
    let mut exported: Vec<i64> = vec![];
    for (i, tid) in track_ids.iter().enumerate() {
        let row = conn.query_row(
            "SELECT t.path, COALESCE(u.title, t.title, t.file_name), COALESCE(u.artist, t.artist), COALESCE(u.album, t.album), COALESCE(u.genre, t.genre),
                    COALESCE(u.year, t.year), COALESCE(u.bpm, t.bpm_tag, a.bpm), keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)), u.rating, t.duration_ms,
                    t.file_size, t.bitrate_kbps, t.sample_rate, t.format, u.notes, t.presence
             FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
            params![tid],
            |r| {
                Ok((
                    r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?, r.get::<_, Option<i64>>(5)?, r.get::<_, Option<f64>>(6)?, r.get::<_, Option<String>>(7)?,
                    r.get::<_, Option<i64>>(8)?, r.get::<_, Option<i64>>(9)?, r.get::<_, i64>(10)?, r.get::<_, Option<i64>>(11)?,
                    r.get::<_, Option<i64>>(12)?, r.get::<_, Option<String>>(13)?, r.get::<_, Option<String>>(14)?, r.get::<_, String>(15)?,
                ))
            },
        );
        let Ok((
            path,
            title,
            artist,
            album,
            genre,
            year,
            bpm,
            key,
            rating,
            dur,
            size,
            bitrate,
            sr,
            format,
            notes,
            presence,
        )) = row
        else {
            continue;
        };
        if presence != "present" {
            continue;
        }
        let tonality = key
            .as_deref()
            .and_then(crate::analysis::musical_name)
            .map(|s| s.to_string())
            .or(key)
            .unwrap_or_default();
        let kind = format!(
            "{} File",
            format
                .as_deref()
                .unwrap_or("Audio")
                .split(' ')
                .next()
                .unwrap_or("Audio")
        );
        tracks_xml.push_str(&format!(
            "    <TRACK TrackID=\"{}\" Name=\"{}\" Artist=\"{}\" Album=\"{}\" Genre=\"{}\" Kind=\"{}\" Size=\"{}\" TotalTime=\"{}\" Year=\"{}\" AverageBpm=\"{}\" BitRate=\"{}\" SampleRate=\"{}\" Comments=\"{}\" Rating=\"{}\" Tonality=\"{}\" Location=\"{}\"/>\n",
            i + 1,
            xml_escape(title.as_deref().unwrap_or("")),
            xml_escape(artist.as_deref().unwrap_or("")),
            xml_escape(album.as_deref().unwrap_or("")),
            xml_escape(genre.as_deref().unwrap_or("")),
            xml_escape(&kind),
            size,
            dur.unwrap_or(0) / 1000,
            year.map(|y| y.to_string()).unwrap_or_default(),
            bpm.map(|b| format!("{b:.2}")).unwrap_or_else(|| "0.00".into()),
            bitrate.unwrap_or(0),
            sr.unwrap_or(0),
            xml_escape(notes.as_deref().unwrap_or("")),
            // rekordbox stores stars as 0, 51, 102, 153, 204, 255.
            rating.unwrap_or(0).clamp(0, 5) * 51,
            xml_escape(&tonality),
            xml_escape(&file_url(&path)),
        ));
        exported.push(*tid);
    }
    xml.push_str(&format!(
        "  <COLLECTION Entries=\"{}\">\n{tracks_xml}  </COLLECTION>\n",
        exported.len()
    ));
    let index_of = |t: i64| exported.iter().position(|x| *x == t).map(|i| i + 1);
    // Playlist tree: folders keep their children.
    fn node(
        all: &[CrateNode],
        sel: &[i64],
        members: &std::collections::HashMap<i64, Vec<i64>>,
        id: i64,
        idx: &dyn Fn(i64) -> Option<usize>,
        depth: usize,
    ) -> String {
        let c = all.iter().find(|c| c.id == id).unwrap();
        let pad = "  ".repeat(depth + 3);
        let kids: Vec<i64> = all
            .iter()
            .filter(|x| x.parent == Some(id) && sel.contains(&x.id))
            .map(|x| x.id)
            .collect();
        let own = members.get(&id).map(|m| !m.is_empty()).unwrap_or(false);
        if !kids.is_empty() {
            let mut s = format!(
                "{pad}<NODE Type=\"0\" Name=\"{}\" Count=\"{}\">\n",
                xml_escape(&c.name),
                kids.len() + usize::from(own)
            );
            if own {
                // A crate that also has sub-crates: its own tracks as a playlist inside the folder.
                let keys: Vec<usize> = members
                    .get(&id)
                    .into_iter()
                    .flatten()
                    .filter_map(|t| idx(*t))
                    .collect();
                s.push_str(&format!(
                    "{pad}  <NODE Name=\"{}\" Type=\"1\" KeyType=\"0\" Entries=\"{}\">\n",
                    xml_escape(&c.name),
                    keys.len()
                ));
                for k in keys {
                    s.push_str(&format!("{pad}    <TRACK Key=\"{k}\"/>\n"));
                }
                s.push_str(&format!("{pad}  </NODE>\n"));
            }
            for k in kids {
                s.push_str(&node(all, sel, members, k, idx, depth + 1));
            }
            s.push_str(&format!("{pad}</NODE>\n"));
            s
        } else {
            let keys: Vec<usize> = members
                .get(&id)
                .into_iter()
                .flatten()
                .filter_map(|t| idx(*t))
                .collect();
            let mut s = format!(
                "{pad}<NODE Name=\"{}\" Type=\"1\" KeyType=\"0\" Entries=\"{}\">\n",
                xml_escape(&c.name),
                keys.len()
            );
            for k in keys {
                s.push_str(&format!("{pad}  <TRACK Key=\"{k}\"/>\n"));
            }
            s.push_str(&format!("{pad}</NODE>\n"));
            s
        }
    }
    let tops: Vec<i64> = sel
        .iter()
        .copied()
        .filter(|id| {
            let p = all.iter().find(|c| c.id == *id).and_then(|c| c.parent);
            p.map(|p| !sel.contains(&p)).unwrap_or(true)
        })
        .collect();
    xml.push_str(&format!(
        "  <PLAYLISTS>\n    <NODE Type=\"0\" Name=\"ROOT\" Count=\"{}\">\n",
        tops.len()
    ));
    for id in tops {
        xml.push_str(&node(&all, &sel, &members, id, &index_of, 0));
    }
    xml.push_str("    </NODE>\n  </PLAYLISTS>\n</DJ_PLAYLISTS>\n");
    // create_new: never replaces an existing file, even one created a moment ago.
    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(dest)
            .map_err(|e| Error::Invalid(format!("couldn't create {}: {e}", dest.display())))?;
        f.write_all(xml.as_bytes())
            .map_err(|e| Error::Invalid(format!("couldn't write {}: {e}", dest.display())))?;
    }
    Ok(
        json!({"file": dest.to_string_lossy(), "tracks": exported.len(), "playlists": sel.len(),
        "note": "In rekordbox: Preferences → Advanced → Database → rekordbox xml → choose this file, then open \"rekordbox xml\" in the tree and import the playlists."}),
    )
}

// ------------------------------------------------------------------ folders

/// Copy each crate into its own folder under `dest` (crate folders become real
/// folders), verifying every copy like a Gig Pack. Existing folders are never
/// written into; that crate is skipped.
pub fn export_folders(
    db_path: &Path,
    dest: &Path,
    crate_ids: Option<Vec<i64>>,
    ctl: &crate::scanner::ScanControl,
    p: &crate::jobs::Progress,
) -> Result<()> {
    let conn = crate::db::open(db_path)?;
    let all = all_crates(&conn)?;
    let sel = selection(&all, crate_ids.as_deref());
    let mut report = vec![];
    for id in sel {
        if crate::jobs::wait_or_cancelled(ctl) {
            break;
        }
        let c = all.iter().find(|c| c.id == id).unwrap();
        let ids = crate_track_ids(&conn, id)?;
        if ids.is_empty() {
            continue;
        }
        let names = chain(&all, id);
        let mut parent = dest.to_path_buf();
        for n in &names[..names.len() - 1] {
            parent.push(crate::organize::sanitize(n));
        }
        std::fs::create_dir_all(&parent)
            .map_err(|e| Error::Invalid(format!("couldn't create {}: {e}", parent.display())))?;
        crate::jobs::message(p, format!("Copying “{}”…", c.name));
        match crate::gigpack::preview(&conn, &ids, &parent, &c.name) {
            Ok(plan) if !Path::new(&plan.pack_dir).exists() && plan.fits => {
                crate::gigpack::execute(&conn, &plan, ctl, p)?;
                report.push(
                    json!({"crate": c.name, "folder": plan.pack_dir, "files": plan.files.len()}),
                );
            }
            Ok(plan) if !plan.fits => {
                report.push(json!({"crate": c.name, "skipped": "not enough free space"}))
            }
            Ok(plan) => report.push(
                json!({"crate": c.name, "skipped": format!("{} already exists", plan.pack_dir)}),
            ),
            Err(e) => report.push(json!({"crate": c.name, "skipped": e.to_string()})),
        }
    }
    crate::jobs::message(
        p,
        format!(
            "Exported {} crate(s).",
            report.iter().filter(|r| r.get("folder").is_some()).count()
        ),
    );
    crate::jobs::lock(p).result = Some(json!({"crates": report}));
    Ok(())
}
