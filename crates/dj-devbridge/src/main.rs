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
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--db" => db = PathBuf::from(args.next().expect("--db <path>")),
            "--port" => port = args.next().expect("--port <n>").parse().expect("port"),
            _ => {
                eprintln!("usage: dj-devbridge [--db path] [--port n]");
                std::process::exit(2);
            }
        }
    }
    let app = App::open(&db).expect("open catalogue");
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
