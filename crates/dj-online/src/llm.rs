//! AI model providers for the assistant.
//!
//! * Claude (Anthropic Messages API, raw HTTPS — there is no official Rust SDK).
//!   The DJ's own API key, read from the Windows credential store.
//! * Local (Ollama on this computer). Nothing leaves the machine.
//!
//! The conversation is held in the Messages format; for Ollama it is converted
//! on the way out and the reply converted back.
use serde_json::{json, Value};

pub const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";
pub const ANTHROPIC_VERSION: &str = "2026-10-21";
/// Server-side refusal fallback ("default" form).
pub const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
pub const MAX_TOKENS: u32 = 8000;

/// Models that accept `fallbacks: "default"` on the Claude API.
pub fn supports_fallback(model: &str) -> bool {
    matches!(
        model,
        "claude-opus-5-5" | "claude-sonnet-5-5" | "claude-fable-5-1"
    )
}

/// Request body for the Messages API. The system prompt (the app guide) and the
/// tool list are stable, so they are cached across turns.
pub fn claude_body(model: &str, system: &str, tools: &[Value], messages: &[Value]) -> Value {
    let mut b = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "tools": tools,
        "messages": messages,
        "output_config": {"effort": "medium"},
    });
    if supports_fallback(model) {
        b["fallbacks"] = json!("default");
    }
    b
}

pub fn claude_error(status: u16, body: &Value) -> String {
    let msg = body
        .pointer("/error/message")
        .and_then(|m| m.as_str())
        .unwrap_or("request failed");
    match status {
        401 | 403 => "Anthropic rejected the API key. Check it in Settings → AI assistant.".into(),
        429 => "Anthropic's rate limit was reached. Wait a moment and try again.".into(),
        529 | 503 => "Anthropic is busy right now. Try again shortly.".into(),
        _ => format!("{msg} (HTTP {status})"),
    }
}

/// Messages-format conversation -> Ollama /api/chat messages.
pub fn to_ollama_messages(system: &str, messages: &[Value]) -> Vec<Value> {
    let mut out = vec![json!({"role": "system", "content": system})];
    let mut names: std::collections::HashMap<String, String> = Default::default();
    for m in messages {
        let role = m["role"].as_str().unwrap_or("user");
        let blocks: Vec<Value> = match &m["content"] {
            Value::String(s) => vec![json!({"type": "text", "text": s})],
            Value::Array(a) => a.clone(),
            _ => vec![],
        };
        if role == "assistant" {
            let text: Vec<&str> = blocks
                .iter()
                .filter(|b| b["type"] == "text")
                .filter_map(|b| b["text"].as_str())
                .collect();
            let calls: Vec<Value> = blocks
                .iter()
                .filter(|b| b["type"] == "tool_use")
                .map(|b| {
                    if let (Some(id), Some(n)) = (b["id"].as_str(), b["name"].as_str()) {
                        names.insert(id.to_string(), n.to_string());
                    }
                    json!({"function": {"name": b["name"], "arguments": b["input"]}})
                })
                .collect();
            let mut msg = json!({"role": "assistant", "content": text.join("\n")});
            if !calls.is_empty() {
                msg["tool_calls"] = json!(calls);
            }
            out.push(msg);
        } else {
            let mut text = vec![];
            for b in &blocks {
                match b["type"].as_str() {
                    Some("tool_result") => {
                        let id = b["tool_use_id"].as_str().unwrap_or_default();
                        let content = match &b["content"] {
                            Value::String(s) => s.clone(),
                            other => other.to_string(),
                        };
                        let mut t = json!({"role": "tool", "content": content});
                        if let Some(n) = names.get(id) {
                            t["tool_name"] = json!(n);
                        }
                        out.push(t);
                    }
                    Some("text") => text.push(b["text"].as_str().unwrap_or_default().to_string()),
                    _ => {}
                }
            }
            if !text.is_empty() {
                out.push(json!({"role": "user", "content": text.join("\n\n")}));
            }
        }
    }
    out
}

pub fn to_ollama_tools(tools: &[Value]) -> Vec<Value> {
    tools
        .iter()
        .map(|t| json!({"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["input_schema"]}}))
        .collect()
}

/// Ollama reply -> Messages-format reply.
pub fn from_ollama(v: &Value, call_seq: &mut u64) -> Value {
    let msg = &v["message"];
    let mut content = vec![];
    if let Some(t) = msg["content"].as_str().filter(|t| !t.trim().is_empty()) {
        content.push(json!({"type": "text", "text": t}));
    }
    let mut used_tool = false;
    if let Some(calls) = msg["tool_calls"].as_array() {
        for c in calls {
            let f = &c["function"];
            let mut args = f["arguments"].clone();
            if let Some(s) = args.as_str() {
                args = serde_json::from_str(s).unwrap_or(json!({}));
            }
            if !args.is_object() {
                args = json!({});
            }
            *call_seq += 1;
            content.push(json!({"type": "tool_use", "id": format!("local_{}", *call_seq), "name": f["name"], "input": args}));
            used_tool = true;
        }
    }
    let stop = if used_tool {
        "tool_use"
    } else if v["done_reason"] == "length" {
        "max_tokens"
    } else {
        "end_turn"
    };
    json!({"content": content, "stop_reason": stop, "model": v["model"]})
}

pub fn ollama_body(model: &str, system: &str, tools: &[Value], messages: &[Value]) -> Value {
    let mut body =
        json!({"model": model, "messages": to_ollama_messages(system, messages), "stream": false});
    // models without tool support reject any "tools" field, even an empty one
    if !tools.is_empty() {
        body["tools"] = json!(to_ollama_tools(tools));
    }
    body
}

/// Ollama's reply when a model has no tool support (e.g. "gemma2 does not support tools").
pub fn ollama_no_tools(v: &Value) -> bool {
    v["error"]
        .as_str()
        .is_some_and(|e| e.to_ascii_lowercase().contains("does not support tools"))
}

/// Every model in an Ollama `/api/tags` reply (most recently used first); embedding models can't chat.
pub fn parse_ollama_tags(v: &Value) -> Vec<dj_core::online::LocalModel> {
    v["models"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|m| {
                    let name = m["name"].as_str().or(m["model"].as_str())?.to_string();
                    let d = &m["details"];
                    let family = d["family"].as_str().unwrap_or("").to_string();
                    let families: Vec<&str> = d["families"]
                        .as_array()
                        .map(|f| f.iter().filter_map(|x| x.as_str()).collect())
                        .unwrap_or_default();
                    let lower = name.to_ascii_lowercase();
                    let embed = lower.contains("embed")
                        || [family.as_str()]
                            .iter()
                            .chain(families.iter())
                            .any(|f| f.contains("bert"));
                    Some(dj_core::online::LocalModel {
                        name,
                        size: m["size"].as_u64().unwrap_or(0),
                        family,
                        parameters: d["parameter_size"].as_str().unwrap_or("").to_string(),
                        can_chat: !embed,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Sums Ollama's per-layer download progress into one figure.
#[derive(Default)]
pub struct PullProgress {
    layers: std::collections::BTreeMap<String, (u64, u64)>,
}

impl PullProgress {
    /// Returns (done bytes, total bytes, status text, finished).
    pub fn update(&mut self, ev: &Value) -> Result<(u64, u64, String, bool), String> {
        if let Some(e) = ev["error"].as_str() {
            return Err(e.to_string());
        }
        let status = ev["status"].as_str().unwrap_or("").to_string();
        if let Some(d) = ev["digest"].as_str() {
            let total = ev["total"].as_u64().unwrap_or(0);
            let done = ev["completed"].as_u64().unwrap_or(0);
            let e = self.layers.entry(d.to_string()).or_insert((0, 0));
            e.0 = e.0.max(done);
            e.1 = e.1.max(total);
        }
        let done = self.layers.values().map(|l| l.0).sum();
        let total = self.layers.values().map(|l| l.1).sum();
        Ok((done, total, status.clone(), status == "success"))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn scans_installed_models_and_spots_embedding_models() {
        let v = json!({"models": [
            {"name": "mistral:latest", "size": 4_100_000_000u64, "details": {"family": "llama", "parameter_size": "7.2B"}},
            {"name": "nomic-embed-text:latest", "size": 274_000_000u64, "details": {"family": "nomic-bert", "families": ["nomic-bert"]}},
            {"name": "gemma2:2b", "size": 1_600_000_000u64, "details": {"family": "gemma2", "parameter_size": "2.6B"}}
        ]});
        let m = parse_ollama_tags(&v);
        assert_eq!(
            m.iter().map(|m| m.name.as_str()).collect::<Vec<_>>(),
            ["mistral:latest", "nomic-embed-text:latest", "gemma2:2b"]
        );
        assert!(m[0].can_chat && !m[1].can_chat && m[2].can_chat);
        assert_eq!(m[0].parameters, "7.2B");
        assert_eq!(m[0].size, 4_100_000_000);
        assert!(parse_ollama_tags(&json!({})).is_empty());
    }

    #[test]
    fn plain_chat_for_models_without_tools() {
        assert!(ollama_no_tools(
            &json!({"error": "registry.ollama.ai/library/gemma2:2b does not support tools"})
        ));
        assert!(!ollama_no_tools(&json!({"error": "model not found"})));
        let b = ollama_body("gemma2:2b", "sys", &[], &[]);
        assert!(b.get("tools").is_none());
        let b = ollama_body(
            "qwen2.5:7b",
            "sys",
            &[json!({"name": "t", "description": "d", "input_schema": {}})],
            &[],
        );
        assert_eq!(b["tools"].as_array().unwrap().len(), 1);
    }

    use super::*;

    #[test]
    fn pull_progress_sums_layers_and_reports_errors() {
        let mut p = PullProgress::default();
        assert_eq!(
            p.update(&json!({"status": "pulling manifest"})).unwrap(),
            (0, 0, "pulling manifest".into(), false)
        );
        p.update(&json!({"status": "pulling a", "digest": "a", "total": 100, "completed": 40}))
            .unwrap();
        let r = p
            .update(&json!({"status": "pulling b", "digest": "b", "total": 50, "completed": 10}))
            .unwrap();
        assert_eq!((r.0, r.1), (50, 150));
        // completed never goes backwards for a layer
        let r = p
            .update(&json!({"status": "pulling a", "digest": "a", "total": 100}))
            .unwrap();
        assert_eq!(r.0, 50);
        assert!(p.update(&json!({"status": "success"})).unwrap().3);
        assert_eq!(
            p.update(&json!({"error": "pull model manifest: file does not exist"}))
                .unwrap_err(),
            "pull model manifest: file does not exist"
        );
    }

    #[test]
    fn claude_body_caches_the_guide_and_opts_into_fallbacks() {
        let b = claude_body(
            "claude-opus-5-5",
            "GUIDE",
            &[json!({"name": "t"})],
            &[json!({"role": "user", "content": "hi"})],
        );
        assert_eq!(b["system"][0]["cache_control"]["type"], "ephemeral");
        assert_eq!(b["fallbacks"], "default");
        assert_eq!(b["output_config"]["effort"], "medium");
        assert!(
            b.get("temperature").is_none()
                && b.get("thinking").is_none()
                && b.get("tool_choice").is_none()
        );
        let h = claude_body("claude-haiku-5-5", "G", &[], &[]);
        assert!(h.get("fallbacks").is_none());
    }

    #[test]
    fn ollama_round_trip_keeps_tool_calls_and_results_paired() {
        let msgs = vec![
            json!({"role": "user", "content": [{"type": "text", "text": "<app_state>x</app_state>"}, {"type": "text", "text": "show house"}]}),
            json!({"role": "assistant", "content": [{"type": "thinking", "thinking": "", "signature": "s"}, {"type": "text", "text": "Looking"}, {"type": "tool_use", "id": "local_1", "name": "search_tracks", "input": {"text": "house"}}]}),
            json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "local_1", "content": "{\"total\":3}"}]}),
        ];
        let o = to_ollama_messages("SYS", &msgs);
        assert_eq!(o[0]["role"], "system");
        assert_eq!(o[1]["content"], "<app_state>x</app_state>\n\nshow house");
        assert_eq!(o[2]["tool_calls"][0]["function"]["name"], "search_tracks");
        assert_eq!(o[3]["role"], "tool");
        assert_eq!(o[3]["tool_name"], "search_tracks");
        let mut seq = 1;
        let r = from_ollama(
            &json!({"model": "qwen2.5:7b", "message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "show_tracks", "arguments": "{\"text\":\"house\"}"}}]}, "done_reason": "stop"}),
            &mut seq,
        );
        assert_eq!(r["stop_reason"], "tool_use");
        assert_eq!(r["content"][0]["input"]["text"], "house");
        assert_eq!(r["content"][0]["id"], "local_2");
        let t = from_ollama(
            &json!({"message": {"content": "Done."}, "done_reason": "stop"}),
            &mut seq,
        );
        assert_eq!(t["stop_reason"], "end_turn");
    }
}
