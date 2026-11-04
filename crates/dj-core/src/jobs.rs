//! Generic background jobs (analysis, online lookups, gig packs, document
//! indexing). One job per kind at a time; each can be paused or cancelled and
//! reports progress. Gig mode pauses every pausable job.
use crate::db::now_ms;
use crate::error::{Error, Result};
use crate::scanner::ScanControl;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[derive(Debug, Clone, Default, Serialize)]
pub struct JobState {
    pub kind: String,
    pub state: String,
    pub done: u64,
    pub total: u64,
    pub errors: u64,
    pub message: Option<String>,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
    pub result: Option<serde_json::Value>,
}

pub type Progress = Arc<Mutex<JobState>>;

struct Entry {
    ctl: Arc<ScanControl>,
    state: Progress,
    handle: Option<JoinHandle<()>>,
}

#[derive(Default)]
pub struct Jobs {
    inner: Mutex<HashMap<String, Entry>>,
}

pub fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Jobs {
    /// Whether any background job is still running.
    pub fn any_running(&self) -> bool {
        lock(&self.inner)
            .values()
            .any(|e| e.handle.as_ref().map(|h| !h.is_finished()).unwrap_or(false))
    }

    pub fn running(&self, kind: &str) -> bool {
        lock(&self.inner)
            .get(kind)
            .and_then(|e| e.handle.as_ref())
            .map(|h| !h.is_finished())
            .unwrap_or(false)
    }

    /// Start a job. `f` runs on its own thread and must honour `ctl`.
    pub fn start<F>(&self, kind: &str, paused: bool, f: F) -> Result<()>
    where
        F: FnOnce(&ScanControl, &Progress) -> Result<()> + Send + 'static,
    {
        let mut map = lock(&self.inner);
        if map
            .get(kind)
            .and_then(|e| e.handle.as_ref())
            .map(|h| !h.is_finished())
            .unwrap_or(false)
        {
            return Err(Error::Busy(format!("{kind} is already running")));
        }
        let ctl = Arc::new(ScanControl::default());
        ctl.pause.store(paused, Ordering::Relaxed);
        let state: Progress = Arc::new(Mutex::new(JobState {
            kind: kind.into(),
            state: "running".into(),
            started_at: Some(now_ms()),
            ..Default::default()
        }));
        let (c2, s2) = (ctl.clone(), state.clone());
        let handle = std::thread::Builder::new()
            .name(format!("dj-{kind}"))
            .spawn(move || {
                let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&c2, &s2)));
                let mut st = lock(&s2);
                st.finished_at = Some(now_ms());
                match res {
                    Ok(Ok(())) => {
                        st.state = if c2.cancel.load(Ordering::Relaxed) {
                            "cancelled".into()
                        } else {
                            "completed".into()
                        }
                    }
                    Ok(Err(e)) => {
                        st.state = "failed".into();
                        st.message = Some(e.to_string());
                    }
                    Err(_) => {
                        st.state = "failed".into();
                        st.message = Some("internal error".into());
                    }
                }
            })?;
        map.insert(
            kind.into(),
            Entry {
                ctl,
                state,
                handle: Some(handle),
            },
        );
        Ok(())
    }

    pub fn status(&self, kind: &str) -> JobState {
        let map = lock(&self.inner);
        match map.get(kind) {
            Some(e) => {
                let mut s = lock(&e.state).clone();
                let alive = e.handle.as_ref().map(|h| !h.is_finished()).unwrap_or(false);
                if alive && e.ctl.pause.load(Ordering::Relaxed) {
                    s.state = "paused".into();
                }
                s
            }
            None => JobState {
                kind: kind.into(),
                state: "idle".into(),
                ..Default::default()
            },
        }
    }

    pub fn all(&self) -> Vec<JobState> {
        let kinds: Vec<String> = lock(&self.inner).keys().cloned().collect();
        kinds.iter().map(|k| self.status(k)).collect()
    }

    pub fn cancel(&self, kind: &str) {
        if let Some(e) = lock(&self.inner).get(kind) {
            e.ctl.cancel.store(true, Ordering::Relaxed);
            e.ctl.pause.store(false, Ordering::Relaxed);
        }
    }

    pub fn pause(&self, kind: &str, paused: bool) {
        if let Some(e) = lock(&self.inner).get(kind) {
            e.ctl.pause.store(paused, Ordering::Relaxed);
        }
    }

    pub fn pause_all(&self, paused: bool) {
        for e in lock(&self.inner).values() {
            e.ctl.pause.store(paused, Ordering::Relaxed);
        }
    }

    pub fn wait(&self, kind: &str) {
        let h = lock(&self.inner)
            .get_mut(kind)
            .and_then(|e| e.handle.take());
        if let Some(h) = h {
            let _ = h.join();
        }
    }

    pub fn shutdown(&self) {
        let kinds: Vec<String> = lock(&self.inner).keys().cloned().collect();
        for k in &kinds {
            self.cancel(k);
        }
        for k in &kinds {
            self.wait(k);
        }
    }
}

/// Helper used inside job bodies.
pub fn set_total(p: &Progress, total: u64) {
    lock(p).total = total;
}
pub fn tick(p: &Progress, ok: bool) {
    let mut s = lock(p);
    s.done += 1;
    if !ok {
        s.errors += 1;
    }
}
pub fn message(p: &Progress, m: impl Into<String>) {
    lock(p).message = Some(m.into());
}
pub fn wait_or_cancelled(ctl: &ScanControl) -> bool {
    while ctl.pause.load(Ordering::Relaxed) && !ctl.cancel.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    ctl.cancel.load(Ordering::Relaxed)
}
