//! DEVELOPMENT/TEST ONLY. Exposes the same `App::dispatch` used by the desktop
//! app over HTTP on 127.0.0.1 so the real UI + real backend can be exercised
//! with Playwright. It binds to loopback only and is not part of releases.
use dj_core::App;
use serde_json::{json, Value};
use std::io::Read;
use std::path::PathBuf;

fn main() {
    let mut db = PathBuf::from("e2e/.data/catalogue.sqlite3");
    let mut port: u16 = 7878;
    let mut demo_ai = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--db" => db = PathBuf::from(args.next().expect("--db <path>")),
            "--port" => port = args.next().expect("--port <n>").parse().expect("port"),
            "--demo-ai" => demo_ai = true,
            _ => {
                eprintln!("usage: dj-devbridge [--db path] [--port n]");
                std::process::exit(2);
            }
        }
    }
    let app = if demo_ai {
        // A scripted stand-in for the AI model, so the UI flow can be tested
        // without network access or an API key. Never used by the real app.
        App::open_with(
            &db,
            std::sync::Arc::new(DemoAi(std::sync::Mutex::new(0))),
            std::sync::Arc::new(dj_core::online::MemorySecrets::default()),
        )
        .expect("open catalogue")
    } else {
        App::open(&db).expect("open catalogue")
    };
    let server = tiny_http::Server::http(("127.0.0.1", port)).expect("bind 127.0.0.1");
    eprintln!(
        "dj-devbridge (dev only) on http://127.0.0.1:{port}  db={}",
        db.display()
    );
    let cors = [
        tiny_http::Header::from_bytes("Access-Control-Allow-Origin", "*").unwrap(),
        tiny_http::Header::from_bytes("Access-Control-Allow-Headers", "content-type").unwrap(),
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
        let mut body = String::new();
        let _ = req.as_reader().take(4 << 20).read_to_string(&mut body);
        let (status, out) = match serde_json::from_str::<Value>(&body) {
            Ok(v) => {
                let cmd = v["cmd"].as_str().unwrap_or("").to_string();
                match app.dispatch(&cmd, v.get("args").cloned().unwrap_or(json!({}))) {
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
struct DemoAi(std::sync::Mutex<u64>);
impl dj_core::online::Online for DemoAi {
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
        _s: &str,
        _t: &[Value],
        messages: &[Value],
    ) -> Result<Value, String> {
        let last = messages.last().cloned().unwrap_or(Value::Null);
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
