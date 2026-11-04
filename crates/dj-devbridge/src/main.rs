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
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--data" => data = PathBuf::from(args.next().expect("--data <dir>")),
            // Lets e2e tests reach a local stand-in AI service; off by default.
            "--online" => online = true,
            "--port" => port = args.next().expect("--port <n>").parse().expect("port"),
            _ => {
                eprintln!("usage: dj-devbridge [--data dir] [--port n] [--online]");
                std::process::exit(2);
            }
        }
    }
    let net: Arc<dyn dj_core::online::Online> = if online {
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
