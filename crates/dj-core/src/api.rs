//! A single JSON command dispatcher used by both the desktop shell (Tauri)
//! and the development bridge, so both exercise exactly the same code.
use crate::crates::{self, CrateInput};
use crate::db;
use crate::duplicates::{self, HashProgress};
use crate::error::{invalid, Error, Result};
use crate::library::{self, TrackQuery, UserFieldsPatch};
use crate::rules::RuleSet;
use crate::scanner::{self, ScanControl, ScanProgress};
use crate::{assistant, health};
use rusqlite::Connection;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

pub const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

struct Job<P> {
    ctl: Arc<ScanControl>,
    progress: Arc<Mutex<P>>,
    handle: Option<JoinHandle<()>>,
}

impl<P: Default> Job<P> {
    fn new() -> Self {
        Job {
            ctl: Arc::new(ScanControl::default()),
            progress: Arc::new(Mutex::new(P::default())),
            handle: None,
        }
    }
    fn running(&self) -> bool {
        self.handle
            .as_ref()
            .map(|h| !h.is_finished())
            .unwrap_or(false)
    }
}

pub struct App {
    db_path: PathBuf,
    conn: Mutex<Connection>,
    scan: Mutex<Job<ScanProgress>>,
    hash: Mutex<Job<HashProgress>>,
}

fn arg<T: DeserializeOwned>(args: &Value, key: &str) -> Result<T> {
    let v = args.get(key).cloned().unwrap_or(Value::Null);
    serde_json::from_value(v).map_err(|e| Error::Invalid(format!("argument '{key}': {e}")))
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl App {
    pub fn open(db_path: &Path) -> Result<Self> {
        let conn = db::open(db_path)?;
        Ok(App {
            db_path: db_path.to_path_buf(),
            conn: Mutex::new(conn),
            scan: Mutex::new(Job::new()),
            hash: Mutex::new(Job::new()),
        })
    }

    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    pub fn start_scan(&self, root_ids: Option<Vec<i64>>, start_paused: bool) -> Result<()> {
        let mut job = lock(&self.scan);
        if job.running() {
            return Err(Error::Busy("a scan is already running".into()));
        }
        if lock(&self.hash).running() {
            return Err(Error::Busy(
                "duplicate hashing is running; wait for it to finish or cancel it".into(),
            ));
        }
        let ctl = Arc::new(ScanControl::default());
        ctl.pause.store(start_paused, Ordering::Relaxed);
        let progress = job.progress.clone();
        {
            let mut p = lock(&progress);
            *p = ScanProgress {
                state: "running".into(),
                phase: "starting".into(),
                ..Default::default()
            };
        }
        let db_path = self.db_path.clone();
        let c2 = ctl.clone();
        let handle = std::thread::Builder::new()
            .name("dj-scan".into())
            .spawn(move || {
                if let Err(e) = scanner::run_scan(&db_path, root_ids, &c2, &progress) {
                    let mut p = lock(&progress);
                    p.state = "failed".into();
                    p.message = Some(e.to_string());
                }
            })?;
        job.ctl = ctl;
        job.handle = Some(handle);
        Ok(())
    }

    pub fn wait_for_scan(&self) {
        let h = lock(&self.scan).handle.take();
        if let Some(h) = h {
            let _ = h.join();
        }
    }

    pub fn wait_for_hash(&self) {
        let h = lock(&self.hash).handle.take();
        if let Some(h) = h {
            let _ = h.join();
        }
    }

    fn start_hash(&self) -> Result<()> {
        let mut job = lock(&self.hash);
        if job.running() {
            return Err(Error::Busy("hashing is already running".into()));
        }
        if lock(&self.scan).running() {
            return Err(Error::Busy(
                "a scan is running; hash after it finishes".into(),
            ));
        }
        let ctl = Arc::new(ScanControl::default());
        let progress = job.progress.clone();
        *lock(&progress) = HashProgress {
            state: "running".into(),
            ..Default::default()
        };
        let db_path = self.db_path.clone();
        let c2 = ctl.clone();
        let handle = std::thread::Builder::new()
            .name("dj-hash".into())
            .spawn(move || {
                let res = db::open(&db_path)
                    .and_then(|conn| duplicates::hash_candidates(&conn, &c2, &progress));
                if res.is_err() {
                    lock(&progress).state = "failed".into();
                }
            })?;
        job.ctl = ctl;
        job.handle = Some(handle);
        Ok(())
    }

    /// Dispatch one command. Arguments and results are JSON.
    pub fn dispatch(&self, cmd: &str, args: Value) -> Result<Value> {
        let a = &args;
        Ok(match cmd {
            "app_info" => json!({
                "version": APP_VERSION,
                "db_path": self.db_path.to_string_lossy(),
                "read_only_files": true,
                "network_features": false,
                "schema_version": db::MIGRATIONS.len(),
            }),
            "stats" => json!(library::stats(&lock(&self.conn))?),
            "list_roots" => json!(library::list_roots(&lock(&self.conn))?),
            "add_root" => json!(library::add_root(
                &lock(&self.conn),
                &arg::<String>(a, "path")?
            )?),
            "remove_root" => {
                if lock(&self.scan).running() {
                    return Err(Error::Busy("cannot remove a folder while scanning".into()));
                }
                json!({"removed_tracks": library::remove_root(&lock(&self.conn), arg(a, "id")?)?})
            }
            "start_scan" => {
                self.start_scan(
                    arg::<Option<Vec<i64>>>(a, "root_ids")?,
                    arg::<Option<bool>>(a, "start_paused")?.unwrap_or(false),
                )?;
                json!({"started": true})
            }
            "scan_status" => {
                let job = lock(&self.scan);
                let mut p = lock(&job.progress).clone();
                if p.state.is_empty() {
                    p.state = "idle".into();
                }
                if job.running() && job.ctl.pause.load(Ordering::Relaxed) {
                    p.state = "paused".into();
                }
                json!(p)
            }
            "pause_scan" => {
                let paused: bool = arg(a, "paused")?;
                lock(&self.scan).ctl.pause.store(paused, Ordering::Relaxed);
                json!({"paused": paused})
            }
            "cancel_scan" => {
                let job = lock(&self.scan);
                job.ctl.cancel.store(true, Ordering::Relaxed);
                job.ctl.pause.store(false, Ordering::Relaxed);
                json!({"cancelling": job.running()})
            }
            "search" => json!(library::search(
                &lock(&self.conn),
                &arg::<TrackQuery>(a, "query")?
            )?),
            "track_detail" => json!(library::track_detail(&lock(&self.conn), arg(a, "id")?)?),
            "update_user_fields" => {
                let ids: Vec<i64> = arg(a, "ids")?;
                let patch: UserFieldsPatch = arg(a, "patch")?;
                json!({"updated": library::update_user_fields(&lock(&self.conn), &ids, &patch)?})
            }
            "set_tags" => {
                let ids: Vec<i64> = arg(a, "ids")?;
                let add: Vec<String> = arg::<Option<Vec<String>>>(a, "add")?.unwrap_or_default();
                let remove: Vec<String> =
                    arg::<Option<Vec<String>>>(a, "remove")?.unwrap_or_default();
                library::set_tags(&lock(&self.conn), &ids, &add, &remove)?;
                json!({"ok": true})
            }
            "list_tags" => json!(library::list_tags(&lock(&self.conn))?),
            "facet" => json!(library::facet(
                &lock(&self.conn),
                &arg::<String>(a, "field")?,
                300
            )?),
            "list_crates" => json!(crates::list(&lock(&self.conn))?),
            "create_crate" => json!(crates::create(
                &lock(&self.conn),
                &arg::<CrateInput>(a, "input")?
            )?),
            "update_crate" => json!(crates::update(
                &lock(&self.conn),
                arg(a, "id")?,
                &arg::<CrateInput>(a, "input")?
            )?),
            "delete_crate" => {
                crates::delete(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "crate_add" => {
                json!({"added": crates::add_tracks(&lock(&self.conn), arg(a, "crate_id")?, &arg::<Vec<i64>>(a, "ids")?)?})
            }
            "crate_add_query" => {
                let conn = lock(&self.conn);
                let ids = library::track_ids(&conn, &arg::<TrackQuery>(a, "query")?, 50_000)?;
                json!({"added": crates::add_tracks(&conn, arg(a, "crate_id")?, &ids)?})
            }
            "crate_remove" => {
                json!({"removed": crates::remove_tracks(&lock(&self.conn), arg(a, "crate_id")?, &arg::<Vec<i64>>(a, "ids")?)?})
            }
            "preview_rules" => json!(crates::preview_rules(
                &lock(&self.conn),
                &arg::<RuleSet>(a, "rules")?,
                50
            )?),
            "rule_fields" => json!(crates::fields()),
            "start_hash" => {
                self.start_hash()?;
                json!({"started": true})
            }
            "hash_status" => {
                let job = lock(&self.hash);
                let mut p = lock(&job.progress).clone();
                if p.state.is_empty() {
                    p.state = "idle".into();
                }
                json!(p)
            }
            "cancel_hash" => {
                lock(&self.hash).ctl.cancel.store(true, Ordering::Relaxed);
                json!({"ok": true})
            }
            "duplicates" => json!(duplicates::find_groups(&lock(&self.conn), 2000)?),
            "set_dup_decision" => {
                duplicates::set_decision(
                    &lock(&self.conn),
                    &arg::<String>(a, "key")?,
                    arg::<Option<String>>(a, "decision")?.as_deref(),
                )?;
                json!({"ok": true})
            }
            "health" => json!(health::health(&lock(&self.conn))?),
            "get_settings" => {
                let conn = lock(&self.conn);
                json!({
                    "low_bitrate_kbps": db::low_bitrate_threshold(&conn)?,
                    "theme": db::get_setting(&conn, "theme")?.unwrap_or_else(|| "dark".into()),
                    "chat_open": db::get_setting(&conn, "chat_open")?.map(|v| v == "1").unwrap_or(true),
                    "privacy_acknowledged": db::get_setting(&conn, "privacy_acknowledged")?.map(|v| v == "1").unwrap_or(false),
                })
            }
            "set_setting" => {
                let key: String = arg(a, "key")?;
                let value: Value = arg(a, "value")?;
                let conn = lock(&self.conn);
                match key.as_str() {
                    "low_bitrate_kbps" => {
                        let v = value.as_u64().ok_or_else(|| {
                            Error::Invalid("threshold must be a whole number".into())
                        })?;
                        if !(8..=2000).contains(&v) {
                            return invalid("threshold must be between 8 and 2000 kbps");
                        }
                        db::set_setting(&conn, &key, &v.to_string())?;
                    }
                    "theme" => {
                        let v = value.as_str().unwrap_or("");
                        if v != "dark" && v != "light" {
                            return invalid("theme must be dark or light");
                        }
                        db::set_setting(&conn, &key, v)?;
                    }
                    "chat_open" | "privacy_acknowledged" => {
                        db::set_setting(
                            &conn,
                            &key,
                            if value.as_bool().unwrap_or(false) {
                                "1"
                            } else {
                                "0"
                            },
                        )?;
                    }
                    _ => return invalid("unknown setting"),
                }
                json!({"ok": true})
            }
            "assistant" => json!(assistant::handle(
                &lock(&self.conn),
                &arg::<String>(a, "message")?
            )?),
            _ => return invalid(format!("unknown command '{cmd}'")),
        })
    }
}

impl Drop for App {
    fn drop(&mut self) {
        // Ask background work to stop; rows already written stay consistent.
        if let Ok(j) = self.scan.lock() {
            j.ctl.cancel.store(true, Ordering::Relaxed);
        }
        if let Ok(j) = self.hash.lock() {
            j.ctl.cancel.store(true, Ordering::Relaxed);
        }
        self.wait_for_scan();
        self.wait_for_hash();
    }
}
