//! The local (Ollama) provider against a fake server on 127.0.0.1.
use dj_core::agent::LlmConfig;
use dj_core::online::Online;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

type Seen = Arc<Mutex<Vec<(String, Value)>>>;

fn serve(replies: Vec<(u16, Value)>) -> (String, Seen) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
    let seen = Arc::new(Mutex::new(vec![]));
    let s2 = seen.clone();
    std::thread::spawn(move || {
        for (status, body) in replies {
            let (mut c, _) = l.accept().unwrap();
            let mut r = BufReader::new(c.try_clone().unwrap());
            let mut line = String::new();
            r.read_line(&mut line).unwrap();
            let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
            let mut len = 0;
            loop {
                let mut h = String::new();
                r.read_line(&mut h).unwrap();
                if h == "\r\n" || h.is_empty() {
                    break;
                }
                if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap();
                }
            }
            let mut buf = vec![0; len];
            r.read_exact(&mut buf).unwrap();
            s2.lock()
                .unwrap()
                .push((path, serde_json::from_slice(&buf).unwrap_or(Value::Null)));
            let b = body.to_string();
            write!(c, "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b}", b.len()).unwrap();
        }
    });
    (url, seen)
}

#[test]
fn local_model_chat_and_model_list() {
    let (url, seen) = serve(vec![
        (
            200,
            json!({"model": "qwen2.5:7b", "message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "search_tracks", "arguments": {"text": "house"}}}]}, "done_reason": "stop"}),
        ),
        (404, json!({"error": "model 'nope' not found"})),
        (
            200,
            json!({"models": [{"name": "qwen2.5:7b"}, {"name": "llama3.1:8b"}]}),
        ),
    ]);
    let http = dj_online::Http::new();
    let cfg = LlmConfig {
        provider: "local".into(),
        model: "qwen2.5:7b".into(),
        api_key: None,
        local_url: url.clone(),
    };
    let tools = dj_core::agent::tool_specs();
    let r = http
        .llm_chat(
            &cfg,
            "GUIDE",
            &tools,
            &[json!({"role": "user", "content": [{"type": "text", "text": "show me house"}]})],
        )
        .unwrap();
    assert_eq!(r["stop_reason"], "tool_use");
    assert_eq!(r["content"][0]["name"], "search_tracks");
    let bad = LlmConfig {
        model: "nope".into(),
        ..cfg.clone()
    };
    let e = http
        .llm_chat(
            &bad,
            "G",
            &tools,
            &[json!({"role": "user", "content": "x"})],
        )
        .unwrap_err();
    assert!(e.contains("ollama pull nope"), "{e}");
    assert_eq!(
        http.llm_local_models(&url).unwrap(),
        vec!["qwen2.5:7b", "llama3.1:8b"]
    );
    let s = seen.lock().unwrap();
    assert_eq!(s[0].0, "/api/chat");
    assert_eq!(s[0].1["stream"], false);
    assert_eq!(s[0].1["messages"][0]["role"], "system");
    assert_eq!(s[0].1["tools"].as_array().unwrap().len(), tools.len());
    assert_eq!(s[2].0, "/api/tags");
    // Nothing reachable: a clear message, not a hang.
    let off = LlmConfig {
        local_url: "http://127.0.0.1:9".into(),
        ..cfg
    };
    let e = http
        .llm_chat(&off, "G", &[], &[json!({"role": "user", "content": "x"})])
        .unwrap_err();
    assert!(e.contains("Is Ollama running"), "{e}");
}
