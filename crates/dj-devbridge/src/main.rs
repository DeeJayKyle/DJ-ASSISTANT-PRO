//! DEVELOPMENT/TEST ONLY. Exposes the same `App::dispatch` used by the desktop
//! app over HTTP on 127.0.0.1 so the real UI + real backend can be exercised
//! with Playwright. It binds to loopback only and is not part of releases.
use dj_core::accounts::Session;
use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;
use std::sync::Arc;

fn main() {
    let mut data = PathBuf::from("e2e/.data/app");
    let mut online = false;
    let mut port: u16 = 7878;
    let mut demo_ai = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            // Local accounts: a data folder holds accounts.json and one catalogue per account.
            "--data" => data = PathBuf::from(args.next().expect("--data <dir>")),
            "--db" => {
                let db = PathBuf::from(args.next().expect("--db <path>"));
                data = db.parent().map(|p| p.to_path_buf()).unwrap_or_default();
            }
            // Lets tests reach a local stand-in service; off by default.
            "--online" => online = true,
            "--port" => port = args.next().expect("--port <n>").parse().expect("port"),
            "--demo-ai" => demo_ai = true,
            _ => {
                eprintln!("usage: dj-devbridge [--data dir] [--port n] [--demo-ai] [--online]");
                std::process::exit(2);
            }
        }
    }
    // A scripted stand-in for the AI model (--demo-ai) lets the UI flow be
    // tested without network access or an API key. Never used by the real app.
    let net: Arc<dyn dj_core::online::Online> = if demo_ai {
        Arc::new(DemoAi(std::sync::Mutex::new(0), dj_online::Http::new()))
    } else if online {
        Arc::new(dj_online::Http::new())
    } else {
        Arc::new(dj_core::online::NoOnline)
    };
    let session = Session::open(
        &data,
        net,
        Arc::new(dj_core::online::MemorySecrets::default()),
    )
    .expect("open data folder");
    let server = tiny_http::Server::http(("127.0.0.1", port)).expect("bind 127.0.0.1");
    eprintln!(
        "dj-devbridge (dev only) on http://127.0.0.1:{port}  data={}",
        data.display()
    );
    let cors = [
        tiny_http::Header::from_bytes("Access-Control-Allow-Origin", "*").unwrap(),
        tiny_http::Header::from_bytes(
            "Access-Control-Allow-Headers",
            "content-type, x-mode, x-path, x-name, x-overwrite",
        )
        .unwrap(),
        tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap(),
    ];
    for mut req in server.incoming_requests() {
        if req.method() == &tiny_http::Method::Options {
            let mut r = tiny_http::Response::empty(204);
            for h in &cors {
                r.add_header(h.clone());
            }
            let _ = req.respond(r);
            continue;
        }
        // GET /track/<id>: the same read-only preview stream as the desktop app.
        if req.method() == &tiny_http::Method::Get && req.url().starts_with("/track/") {
            let id: Option<i64> = req.url()[7..]
                .split('?')
                .next()
                .and_then(|s| s.parse().ok());
            let range = req
                .headers()
                .iter()
                .find(|h| h.field.equiv("Range"))
                .map(|h| h.value.as_str().to_string());
            let piece = id
                .and_then(|id| session.app()?.playable_path(id))
                .and_then(|p| dj_core::media::serve(&p, range.as_deref()).ok());
            let resp = match piece {
                Some(p) => {
                    let mut r = tiny_http::Response::from_data(p.body).with_status_code(p.status);
                    for (k, v) in p.headers {
                        if k != "Content-Length" {
                            r.add_header(tiny_http::Header::from_bytes(k, v.as_bytes()).unwrap());
                        }
                    }
                    r.add_header(cors[0].clone());
                    r
                }
                None => tiny_http::Response::from_data(Vec::new()).with_status_code(404),
            };
            let _ = req.respond(resp);
            continue;
        }
        // POST /studio-write: the same raw-bytes Studio save as the desktop app.
        if req.method() == &tiny_http::Method::Post && req.url().starts_with("/studio-write") {
            let hv = |k: &'static str| {
                req.headers()
                    .iter()
                    .find(|h| h.field.equiv(k))
                    .map(|h| percent_decode(h.value.as_str()))
                    .unwrap_or_default()
            };
            let (mode, path, rel, overwrite) = (
                hv("x-mode"),
                hv("x-path"),
                hv("x-name"),
                hv("x-overwrite") == "1",
            );
            let mut bytes = Vec::new();
            let _ = req.as_reader().take(1 << 30).read_to_end(&mut bytes);
            let res = match session.app() {
                Some(app) if mode == "into" => {
                    app.studio_write_into(std::path::Path::new(&path), &rel, &bytes)
                }
                Some(app) => app.studio_write_file(std::path::Path::new(&path), &bytes, overwrite),
                None => Err(dj_core::Error::Invalid("create an account first".into())),
            };
            let out = match res {
                Ok(p) => json!({"ok": p}),
                Err(e) => json!({"error": e.to_string()}),
            };
            let mut r = tiny_http::Response::from_string(out.to_string());
            for h in &cors {
                r.add_header(h.clone());
            }
            let _ = req.respond(r);
            continue;
        }
        let mut body = String::new();
        let _ = req.as_reader().take(4 << 20).read_to_string(&mut body);
        let (status, out) = match serde_json::from_str::<Value>(&body) {
            Ok(v) => {
                let cmd = v["cmd"].as_str().unwrap_or("").to_string();
                match session.dispatch(&cmd, v.get("args").cloned().unwrap_or(json!({}))) {
                    Ok(res) => (200, json!({"ok": res})),
                    Err(e) => (200, json!({"error": e.to_string()})),
                }
            }
            Err(e) => (400, json!({"error": format!("bad request: {e}")})),
        };
        let mut r = tiny_http::Response::from_string(out.to_string()).with_status_code(status);
        for h in &cors {
            r.add_header(h.clone());
        }
        let _ = req.respond(r);
    }
}

/// Scripted "model": picks tools from keywords so the e2e test can exercise
/// read tools, screen changes and approval cards deterministically.
struct DemoAi(std::sync::Mutex<u64>, dj_online::Http);
impl dj_core::online::Online for DemoAi {
    // Local model setup uses the real code (it only talks to 127.0.0.1).
    fn llm_local_probe(&self, url: &str) -> dj_core::online::LocalProbe {
        self.1.llm_local_probe(url)
    }
    fn llm_local_start(&self) -> Result<(), String> {
        self.1.llm_local_start()
    }
    fn llm_list_models(&self, cfg: &dj_core::agent::LlmConfig) -> Result<Vec<String>, String> {
        self.1.llm_list_models(cfg)
    }
    fn llm_local_pull(
        &self,
        url: &str,
        model: &str,
        p: &mut dyn FnMut(u64, u64, &str) -> bool,
    ) -> Result<(), String> {
        self.1.llm_local_pull(url, model, p)
    }
    fn musicbrainz_recordings(
        &self,
        _: &str,
        _: &str,
    ) -> Result<Vec<dj_core::online::MbRecording>, String> {
        Err("offline demo".into())
    }
    fn musicbrainz_artist_releases(
        &self,
        _: &str,
    ) -> Result<Vec<dj_core::online::ReleaseItem>, String> {
        Err("offline demo".into())
    }
    fn acoustid_lookup(
        &self,
        _: &str,
        _: u32,
        _: &str,
    ) -> Result<Vec<dj_core::online::AcoustidMatch>, String> {
        Err("offline demo".into())
    }
    fn lastfm_similar_artists(
        &self,
        _: &str,
        _: &str,
    ) -> Result<Vec<dj_core::online::SimilarItem>, String> {
        Err("offline demo".into())
    }
    fn lastfm_similar_tracks(
        &self,
        _: &str,
        _: &str,
        _: &str,
    ) -> Result<Vec<dj_core::online::SimilarItem>, String> {
        Err("offline demo".into())
    }
    fn llm_chat(
        &self,
        cfg: &dj_core::agent::LlmConfig,
        system: &str,
        _t: &[Value],
        messages: &[Value],
    ) -> Result<Value, String> {
        let last = messages.last().cloned().unwrap_or(Value::Null);
        // Quick Prep's AI help: one plain request with a JSON answer.
        if let Some(user) = last["content"].as_str() {
            let text = if system.contains("tidy their music library") {
                let items: Vec<Value> = serde_json::from_str(user).unwrap_or_default();
                let out: Vec<Value> = items.iter().map(|t| {
                    if t["file"].as_str().unwrap_or("").contains("deep_house") {
                        json!({"id": t["id"], "artist": "Groove Unit", "title": "Deep House Groove", "mix": "Clean", "genre": "deep house"})
                    } else {
                        let mut v = t["suggestion"].clone();
                        v["id"] = t["id"].clone();
                        v
                    }
                }).collect();
                json!({"tracks": out}).to_string()
            } else if system.contains("planning a set") {
                let list: Vec<Value> =
                    serde_json::from_str(user.split("Tracks: ").nth(1).unwrap_or("[]"))
                        .unwrap_or_default();
                let ids: Vec<Value> = list.iter().rev().map(|t| t["id"].clone()).collect();
                json!({"order": ids, "note": "Reversed by the demo AI."}).to_string()
            } else {
                "{}".to_string()
            };
            return Ok(
                json!({"model": cfg.model, "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}),
            );
        }
        let blocks = last["content"].as_array().cloned().unwrap_or_default();
        let mut n = self.0.lock().unwrap();
        *n += 1;
        let id = |k: &str| format!("demo_{k}_{n}");
        if let Some(r) = blocks.iter().find(|b| b["type"] == "tool_result") {
            let body: Value = serde_json::from_str(r["content"].as_str().unwrap_or("null"))
                .unwrap_or(Value::Null);
            let text = if r["is_error"] == true {
                "Okay, I left that alone.".to_string()
            } else if let Some(t) = body.get("total") {
                format!("You have **{t}** Afrobeats tracks. I can put them in a smart crate that stays up to date — want me to?")
            } else {
                "All done. The crate **Afrobeats (AI)** is in your sidebar and updates itself as you add music.".to_string()
            };
            return Ok(
                json!({"model": cfg.model, "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}),
            );
        }
        let text = blocks
            .iter()
            .filter_map(|b| b["text"].as_str())
            .filter(|t| !t.starts_with("<app_state>"))
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase();
        let afro = json!({"match": "all", "rules": [{"kind": "condition", "field": "genre", "op": "equals", "value": "Afrobeats"}]});
        let content = if text.contains("crate") {
            json!([{"type": "text", "text": "Here's the crate I'd make:"}, {"type": "tool_use", "id": id("c"), "name": "create_crate", "input": {"name": "Afrobeats (AI)", "kind": "smart", "rules": afro, "color": "green"}}])
        } else if text.contains("afrobeats") {
            json!([{"type": "tool_use", "id": id("s"), "name": "search_tracks", "input": {"filters": afro, "limit": 5}}, {"type": "tool_use", "id": id("v"), "name": "show_tracks", "input": {"filters": afro, "label": "Afrobeats"}}])
        } else {
            json!([{"type": "text", "text": "Hi Herbie! I know every corner of DJ Assistant. Ask me about your library, or tell me what to prepare."}])
        };
        let stop = if content
            .as_array()
            .unwrap()
            .iter()
            .any(|b| b["type"] == "tool_use")
        {
            "tool_use"
        } else {
            "end_turn"
        };
        Ok(json!({"model": cfg.model, "stop_reason": stop, "content": content}))
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
