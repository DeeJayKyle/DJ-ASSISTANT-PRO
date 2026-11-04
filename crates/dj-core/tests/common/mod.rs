#![allow(dead_code)]
use dj_core::App;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/library")
}

pub fn copy_dir(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst).unwrap();
    for e in std::fs::read_dir(src).unwrap() {
        let e = e.unwrap();
        let p = e.path();
        let t = dst.join(e.file_name());
        if p.is_dir() {
            copy_dir(&p, &t);
        } else {
            std::fs::copy(&p, &t).unwrap();
        }
    }
}

/// Working copy of the fixture library + separate app-data dir.
pub struct Env {
    pub _tmp: tempfile::TempDir,
    pub music: PathBuf,
    pub data: PathBuf,
}

pub fn env() -> Env {
    let tmp = tempfile::tempdir().unwrap();
    let music = tmp.path().join("My Music");
    copy_dir(&fixtures(), &music);
    let data = tmp.path().join("AppData").join("dj-assistant");
    Env {
        _tmp: tmp,
        music,
        data,
    }
}

impl Env {
    pub fn db(&self) -> PathBuf {
        self.data.join("catalogue.sqlite3")
    }
    pub fn app(&self) -> App {
        let app = App::open(&self.db()).unwrap();
        // Tests check exact counts, so the automatic post-scan prep stays off
        // unless a test turns it on.
        app.dispatch("set_setting", json!({"key": "auto_prep", "value": false}))
            .unwrap();
        app
    }
}

pub fn call(app: &App, cmd: &str, args: Value) -> Value {
    app.dispatch(cmd, args)
        .unwrap_or_else(|e| panic!("{cmd} failed: {e}"))
}

pub fn scan(app: &App) -> Value {
    call(app, "start_scan", json!({}));
    app.wait_for_scan();
    call(app, "scan_status", json!({}))
}

pub fn add_and_scan(app: &App, dir: &Path) -> Value {
    call(app, "add_root", json!({"path": dir.to_str().unwrap()}));
    scan(app)
}

pub fn search(app: &App, q: Value) -> Value {
    call(app, "search", json!({"query": q}))
}

pub fn titles(page: &Value) -> Vec<String> {
    let mut v: Vec<String> = page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            r["title"]
                .as_str()
                .unwrap_or(r["file_name"].as_str().unwrap())
                .to_string()
        })
        .collect();
    v.sort();
    v
}

pub fn find<'a>(page: &'a Value, file_name: &str) -> &'a Value {
    page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["file_name"] == file_name)
        .unwrap_or_else(|| panic!("{file_name} not found"))
}

/// Snapshot of every file: size, modified time and full content hash.
pub fn snapshot(dir: &Path) -> BTreeMap<PathBuf, (u64, std::time::SystemTime, String)> {
    let mut m = BTreeMap::new();
    for e in walkdir(dir) {
        let md = std::fs::metadata(&e).unwrap();
        let bytes = std::fs::read(&e).unwrap();
        m.insert(
            e,
            (
                md.len(),
                md.modified().unwrap(),
                blake3::hash(&bytes).to_hex().to_string(),
            ),
        );
    }
    m
}

fn walkdir(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            out.extend(walkdir(&p));
        } else {
            out.push(p);
        }
    }
    out
}
