//! Content packs: large optional parts of the app (AI models, runtimes) that are
//! downloaded once instead of riding along in every installer and update.
//!
//! Each pack is a fixed list of files with known sizes and SHA-256 checksums. Files
//! download into `<base>/packs/<id>/<name>.part`, are verified, then renamed into
//! place; a pack counts as installed only when every file is present and verified
//! (recorded in `installed.json`). Downloads resume after an interruption.
use crate::error::{invalid, Error, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};

pub struct PackFile {
    pub name: &'static str,
    pub url: &'static str,
    pub size: u64,
    pub sha256: &'static str,
}

pub struct Pack {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub credits: &'static str,
    pub files: &'static [PackFile],
}

const PACKS_RELEASE: &str =
    "https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/download/packs-1/";

macro_rules! release_url {
    ($f:literal) => {
        concat!(
            "https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/download/packs-1/",
            $f
        )
    };
}

pub const PACKS: &[Pack] = &[Pack {
    id: "stems-ai",
    name: "Pro Stems AI",
    description: "AI stem separation (HTDemucs) for the Studio: much cleaner vocals, drums, bass and melodies than the built-in splitter. Runs on this computer, on your graphics card when it can (WebGPU) or the processor.",
    credits: "HTDemucs by Alexandre Défossez et al., Meta Platforms, Inc. (MIT licence). Browser export by timcsy/demucs-web (MIT). ONNX Runtime Web by Microsoft (MIT).",
    files: &[
        PackFile {
            name: "htdemucs_embedded.onnx",
            url: release_url!("htdemucs_embedded.onnx"),
            size: 180_534_758,
            sha256: "e5e425c17683f163a472462eb5f5a4ffcd11c31858d57fbd0833b012d8b88077",
        },
        PackFile {
            name: "ort-wasm-simd-threaded.asyncify.wasm",
            url: release_url!("ort-wasm-simd-threaded.asyncify.wasm"),
            size: 25_499_390,
            sha256: "babec0bbddb6d3082623b99b7e1391b75e0729bcca076ff8424d7753af97fada",
        },
    ],
}];

/// Where packs are mirrored (the "Publish packs" workflow uploads them here).
pub fn release_base() -> &'static str {
    PACKS_RELEASE
}

pub fn pack(id: &str) -> Option<&'static Pack> {
    PACKS.iter().find(|p| p.id == id)
}

pub fn dir(base: &Path, id: &str) -> PathBuf {
    base.join("packs").join(id)
}

pub fn installed(base: &Path, p: &Pack) -> bool {
    let d = dir(base, p.id);
    d.join("installed.json").is_file()
        && p.files.iter().all(|f| {
            std::fs::metadata(d.join(f.name))
                .map(|m| m.len() == f.size)
                .unwrap_or(false)
        })
}

/// The path of one file of an installed pack (for the app's pack:// server), or None.
pub fn file_path(base: &Path, id: &str, name: &str) -> Option<PathBuf> {
    let p = pack(id)?;
    let f = p.files.iter().find(|f| f.name == name)?;
    installed(base, p).then(|| dir(base, p.id).join(f.name))
}

/// Content type for a pack file (WebAssembly must be served as application/wasm).
pub fn mime(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("") {
        "wasm" => "application/wasm",
        "json" => "application/json",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut h = Sha256::new();
    let mut f = std::fs::File::open(path)?;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Every pack with its state, for Settings → Packs.
pub fn list(base: &Path, jobs: &crate::jobs::Jobs) -> Value {
    json!(PACKS
        .iter()
        .map(|p| json!({
            "id": p.id, "name": p.name, "description": p.description, "credits": p.credits,
            "size": p.files.iter().map(|f| f.size).sum::<u64>(),
            "installed": installed(base, p),
            "download": jobs.status(&format!("pack:{}", p.id)),
        }))
        .collect::<Vec<_>>())
}

/// Download, verify and install every file of a pack. `download(url, dest, progress)`
/// appends to `dest` (resuming), calling `progress(bytes_now_in_file)`; it returns
/// false from progress to stop.
pub fn install(
    base: &Path,
    p: &Pack,
    download: &dyn Fn(&str, &Path, &mut dyn FnMut(u64) -> bool) -> std::result::Result<(), String>,
    ctl: &crate::scanner::ScanControl,
    prog: &crate::jobs::Progress,
) -> Result<()> {
    let d = dir(base, p.id);
    std::fs::create_dir_all(&d)?;
    let total: u64 = p.files.iter().map(|f| f.size).sum();
    crate::jobs::set_total(prog, total);
    let mut done_before = 0u64;
    for f in p.files {
        let target = d.join(f.name);
        let ok_already = std::fs::metadata(&target)
            .map(|m| m.len() == f.size)
            .unwrap_or(false)
            && sha256_file(&target)? == f.sha256;
        if !ok_already {
            let part = d.join(format!("{}.part", f.name));
            // a partial file bigger than the real one can't be resumed
            if std::fs::metadata(&part)
                .map(|m| m.len() > f.size)
                .unwrap_or(false)
            {
                std::fs::remove_file(&part)?;
            }
            crate::jobs::message(prog, format!("Downloading {}…", f.name));
            let mut stop = false;
            download(f.url, &part, &mut |now| {
                {
                    let mut s = crate::jobs::lock(prog);
                    s.done = done_before + now.min(f.size);
                }
                stop = crate::jobs::wait_or_cancelled(ctl);
                !stop
            })
            .map_err(|e| Error::Network(format!("{e}. Check your internet connection and try again.")))?;
            if stop {
                crate::jobs::message(
                    prog,
                    "Stopped. The download picks up where it left off next time.",
                );
                return Ok(());
            }
            crate::jobs::message(prog, format!("Checking {}…", f.name));
            let len = std::fs::metadata(&part)?.len();
            if len != f.size || sha256_file(&part)? != f.sha256 {
                std::fs::remove_file(&part)?;
                return invalid(format!(
                    "{} didn't download correctly (checksum mismatch). Try again.",
                    f.name
                ));
            }
            std::fs::rename(&part, &target)?;
        }
        done_before += f.size;
        crate::jobs::lock(prog).done = done_before;
    }
    std::fs::write(
        d.join("installed.json"),
        serde_json::to_vec_pretty(&json!({"id": p.id, "files": p.files.iter().map(|f| json!({"name": f.name, "sha256": f.sha256})).collect::<Vec<_>>(), "installed_at": crate::db::now_ms()}))
            .unwrap_or_default(),
    )?;
    crate::jobs::message(prog, format!("{} is installed.", p.name));
    Ok(())
}

/// Delete a pack's files (only inside its own folder).
pub fn remove(base: &Path, id: &str) -> Result<()> {
    if pack(id).is_none() {
        return invalid("unknown pack");
    }
    let d = dir(base, id);
    if d.is_dir() {
        std::fs::remove_dir_all(&d)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalogue_is_well_formed() {
        for p in PACKS {
            for f in p.files {
                assert!(f.url.starts_with(release_base()), "{}", f.url);
                assert!(f.url.ends_with(f.name));
                assert_eq!(f.sha256.len(), 64);
                assert!(!f.name.contains(['/', '\\']) && !f.name.contains(".."));
            }
        }
    }

    fn hex(b: &[u8]) -> String {
        Sha256::digest(b)
            .iter()
            .map(|x| format!("{x:02x}"))
            .collect()
    }

    #[test]
    fn installs_resumes_and_verifies() {
        let t = tempfile::tempdir().unwrap();
        let body: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let sum: &'static str = Box::leak(hex(&body).into_boxed_str());
        let files: &'static [PackFile] = Box::leak(Box::new([PackFile {
            name: "model.bin",
            url: "https://example.test/model.bin",
            size: body.len() as u64,
            sha256: sum,
        }]));
        let p = Pack {
            id: "test-pack",
            name: "Test",
            description: "",
            credits: "",
            files,
        };
        let ctl = crate::scanner::ScanControl::default();
        let prog: crate::jobs::Progress = Default::default();
        // a fake server that appends the rest of the file (resume), 64 KiB at a time
        let serve = |data: Vec<u8>| {
            move |_: &str,
                  dest: &Path,
                  f: &mut dyn FnMut(u64) -> bool|
                  -> std::result::Result<(), String> {
                use std::io::Write;
                let have = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0) as usize;
                let mut out = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(dest)
                    .map_err(|e| e.to_string())?;
                for c in data[have..].chunks(65536) {
                    out.write_all(c).map_err(|e| e.to_string())?;
                    let now = std::fs::metadata(dest).unwrap().len();
                    if !f(now) {
                        break;
                    }
                }
                Ok(())
            }
        };
        // an interrupted earlier download left half the file behind
        let d = dir(t.path(), p.id);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("model.bin.part"), &body[..150_000]).unwrap();
        install(t.path(), &p, &serve(body.clone()), &ctl, &prog).unwrap();
        assert!(installed(t.path(), &p));
        assert_eq!(std::fs::read(d.join("model.bin")).unwrap(), body);
        assert!(!d.join("model.bin.part").exists());
        // a corrupted download is rejected and not installed
        let t2 = tempfile::tempdir().unwrap();
        let mut bad = body.clone();
        bad[1000] ^= 1;
        assert!(install(t2.path(), &p, &serve(bad), &ctl, &prog).is_err());
        assert!(!installed(t2.path(), &p));
        assert!(!dir(t2.path(), p.id).join("model.bin").exists());
        // removing only deletes the pack's own folder
        std::fs::write(t.path().join("keep.txt"), "x").unwrap();
        remove(t.path(), "stems-ai").unwrap();
        assert!(t.path().join("keep.txt").exists());
    }

    #[test]
    fn file_path_needs_an_installed_pack_and_a_catalogue_file() {
        let t = tempfile::tempdir().unwrap();
        assert!(file_path(t.path(), "stems-ai", "htdemucs_embedded.onnx").is_none());
        assert!(file_path(t.path(), "stems-ai", "../../secret").is_none());
        assert!(file_path(t.path(), "nope", "x").is_none());
    }
}
