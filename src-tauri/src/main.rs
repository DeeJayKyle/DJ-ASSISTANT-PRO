// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use dj_core::accounts::Session;
use dj_core::online::Secrets;
use serde_json::Value;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::Manager;

struct State {
    session: Arc<Session>,
    log_path: Option<PathBuf>,
    log_lock: Mutex<()>,
}

impl State {
    /// Local log: command name and error text only. No arguments are logged,
    /// so search text, file paths and API keys typed by the user are not recorded.
    fn log(&self, line: &str) {
        let Some(p) = &self.log_path else { return };
        let _g = self.log_lock.lock();
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(p)
        {
            let _ = writeln!(f, "{} {}", dj_core::db::now_ms(), line);
        }
    }
}

/// API keys live in Windows Credential Manager (never in the catalogue,
/// logs or source). They are never sent back to the UI.
struct CredentialStore;
impl CredentialStore {
    fn entry(service: &str) -> Result<keyring::Entry, String> {
        keyring::Entry::new("DJ Assistant", service).map_err(|e| e.to_string())
    }
}
impl Secrets for CredentialStore {
    fn get(&self, service: &str) -> Option<String> {
        Self::entry(service).ok()?.get_password().ok()
    }
    fn set(&self, service: &str, value: &str) -> Result<(), String> {
        Self::entry(service)?
            .set_password(value)
            .map_err(|e| e.to_string())
    }
    fn delete(&self, service: &str) -> Result<(), String> {
        match Self::entry(service)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}

/// Single entry point for the UI. All commands are implemented (and tested)
/// in dj-core; nothing here reads or writes music files directly.
#[tauri::command]
async fn api(state: tauri::State<'_, State>, cmd: String, args: Value) -> Result<Value, String> {
    let st = state.inner();
    let session = st.session.clone();
    let c = cmd.clone();
    // Run on a blocking worker so the UI thread never waits on the database.
    let res = tauri::async_runtime::spawn_blocking(move || session.dispatch(&c, args))
        .await
        .map_err(|e| format!("internal error: {e}"))?;
    res.map_err(|e| {
        st.log(&format!("command {cmd} failed: {e}"));
        e.to_string()
    })
}

/// Reveal a catalogued file in Explorer (read-only action).
#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err("file not found (drive offline?)".into());
    }
    tauri_plugin_opener::reveal_item_in_dir(p).map_err(|e| e.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let data_dir = app.path().app_data_dir().expect("app data dir");
            std::fs::create_dir_all(&data_dir)?;
            let log_dir = app.path().app_log_dir().ok();
            let log_path = log_dir.and_then(|d| {
                std::fs::create_dir_all(&d)
                    .ok()
                    .map(|_| d.join("dj-assistant.log"))
            });
            // Local accounts, each with its own catalogue; no sign-in.
            let session = Session::open(
                &data_dir,
                Arc::new(dj_online::Http::new()),
                Arc::new(CredentialStore),
            )
            .map_err(|e| {
                format!(
                    "could not open the catalogue in {}: {e}",
                    data_dir.display()
                )
            })?;
            let state = State {
                session: Arc::new(session),
                log_path,
                log_lock: Mutex::new(()),
            };
            state.log(&format!("started v{}", dj_core::api::APP_VERSION));
            app.manage(state);
            Ok(())
        })
        // Previews: `track://localhost/<id>` streams a catalogued track (read-only,
        // range requests). Only tracks in the open account's catalogue resolve.
        .register_asynchronous_uri_scheme_protocol("track", |ctx, req, responder| {
            let session = ctx.app_handle().state::<State>().session.clone();
            let id: Option<i64> = req.uri().path().trim_matches('/').parse().ok();
            let range = req
                .headers()
                .get("range")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            std::thread::spawn(move || {
                let path = id.and_then(|id| session.app()?.playable_path(id));
                let resp = match path.map(|p| dj_core::media::serve(&p, range.as_deref())) {
                    Some(Ok(piece)) => {
                        let mut b = tauri::http::Response::builder().status(piece.status);
                        for (k, v) in piece.headers {
                            b = b.header(k, v);
                        }
                        b.body(piece.body)
                    }
                    _ => tauri::http::Response::builder()
                        .status(404)
                        .body(Vec::new()),
                };
                responder.respond(resp.unwrap_or_else(|_| tauri::http::Response::new(Vec::new())));
            });
        })
        .invoke_handler(tauri::generate_handler![api, reveal])
        .run(tauri::generate_context!())
        .expect("error while running DJ Assistant");
}
