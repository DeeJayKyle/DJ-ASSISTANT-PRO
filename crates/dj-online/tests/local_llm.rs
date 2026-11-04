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
    assert!(e.contains("Ollama") && !e.contains("os error"), "{e}");
}

/// Serve one raw newline-delimited body (Ollama streams /api/pull like this).
fn serve_raw(body: String) -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
    std::thread::spawn(move || {
        let (mut c, _) = l.accept().unwrap();
        let mut r = BufReader::new(c.try_clone().unwrap());
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
        write!(c, "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    });
    url
}

#[test]
fn local_model_download_reports_progress_and_errors() {
    let http = dj_online::Http::new();
    let ok = [
        json!({"status": "pulling manifest"}),
        json!({"status": "pulling abc", "digest": "abc", "total": 1000, "completed": 0}),
        json!({"status": "pulling abc", "digest": "abc", "total": 1000, "completed": 600}),
        json!({"status": "pulling def", "digest": "def", "total": 200, "completed": 200}),
        json!({"status": "pulling abc", "digest": "abc", "total": 1000, "completed": 1000}),
        json!({"status": "verifying sha256 digest"}),
        json!({"status": "success"}),
    ]
    .iter()
    .map(|v| v.to_string() + "\n")
    .collect::<String>();
    let url = serve_raw(ok);
    let mut seen = vec![];
    http.llm_local_pull(&url, "qwen2.5:3b", &mut |d, t, s| {
        seen.push((d, t, s.to_string()));
        true
    })
    .unwrap();
    assert_eq!(seen.last().unwrap().2, "success");
    assert!(seen.iter().any(|x| x.0 == 1200 && x.1 == 1200));
    assert!(
        seen.windows(2).all(|w| w[1].0 >= w[0].0),
        "progress went backwards"
    );

    let bad = json!({"status": "pulling manifest"}).to_string()
        + "\n"
        + &json!({"error": "pull model manifest: file does not exist"}).to_string()
        + "\n";
    let url = serve_raw(bad);
    let e = http
        .llm_local_pull(&url, "nope:1b", &mut |_, _, _| true)
        .unwrap_err();
    assert!(e.contains("does not exist"), "{e}");

    // Stopping is honoured.
    let url = serve_raw(
        json!({"status": "pulling a", "digest": "a", "total": 10, "completed": 1}).to_string()
            + "\n",
    );
    let e = http
        .llm_local_pull(&url, "x:1b", &mut |_, _, _| false)
        .unwrap_err();
    assert_eq!(e, "download stopped");

    // Nothing listening: plain words, no OS error codes.
    let e = http
        .llm_local_pull("http://127.0.0.1:9", "x:1b", &mut |_, _, _| true)
        .unwrap_err();
    assert!(e.contains("Ollama") && !e.contains("os error"), "{e}");
    let p = http.llm_local_probe("http://127.0.0.1:9");
    assert!(!p.running && p.models.is_empty());
}

#[test]
fn models_without_tools_still_answer() {
    let (url, seen) = serve(vec![
        (
            400,
            json!({"error": "registry.ollama.ai/library/gemma2:2b does not support tools"}),
        ),
        (
            200,
            json!({"model": "gemma2:2b", "message": {"role": "assistant", "content": "Your library has 12 tracks."}, "done_reason": "stop"}),
        ),
    ]);
    let http = dj_online::Http::new();
    let cfg = LlmConfig {
        provider: "local".into(),
        model: "gemma2:2b".into(),
        api_key: None,
        local_url: url,
    };
    let r = http
        .llm_chat(
            &cfg,
            "GUIDE",
            &dj_core::agent::tool_specs(),
            &[json!({"role": "user", "content": "how many tracks?"})],
        )
        .unwrap();
    assert_eq!(r["content"][0]["text"], "Your library has 12 tracks.");
    let s = seen.lock().unwrap();
    assert!(s[0].1.get("tools").is_some());
    assert!(s[1].1.get("tools").is_none(), "the retry is a plain chat");
}

#[test]
fn asks_for_a_bigger_context_when_the_request_does_not_fit() {
    let (url, seen) = serve(vec![
        (
            400,
            json!({"error": "request (40000 tokens) exceeds the available context size (16384 tokens), try increasing it"}),
        ),
        (
            200,
            json!({"model": "dj-assistant-brain:latest", "message": {"role": "assistant", "content": "Hello."}, "done_reason": "stop"}),
        ),
    ]);
    let http = dj_online::Http::new();
    let cfg = LlmConfig {
        provider: "local".into(),
        model: "dj-assistant-brain:latest".into(),
        api_key: None,
        local_url: url,
    };
    let tools = dj_core::agent::tool_specs();
    let r = http
        .llm_chat(
            &cfg,
            "GUIDE",
            &tools,
            &[json!({"role": "user", "content": "hi"})],
        )
        .unwrap();
    assert_eq!(r["content"][0]["text"], "Hello.");
    let s = seen.lock().unwrap();
    // the first request already asks for more than Ollama's 4096 default
    assert!(s[0].1["options"]["num_ctx"].as_u64().unwrap() >= 8192);
    assert_eq!(
        s[1].1["options"]["num_ctx"], 65536,
        "retried with a window that fits"
    );
    assert!(s[1].1.get("tools").is_some(), "tools are kept");
}
