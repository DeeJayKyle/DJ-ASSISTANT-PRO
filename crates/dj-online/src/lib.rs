//! Optional online services. This crate is the ONLY place DJ Assistant talks
//! to the internet, and dj-core only calls it after the DJ has switched the
//! matching service on. Each provider's rules are respected:
//!
//! * MusicBrainz: max 1 request/second (enforced here and by the caller), a
//!   descriptive User-Agent, data CC0 (core data) — attribution shown in UI.
//! * AcoustID: user-supplied application key; ~3 requests/second max; the
//!   compressed fingerprint and duration are sent, never audio.
//! * Last.fm: user-supplied API key; results credited to Last.fm in the UI.
pub mod llm;

use dj_core::agent::LlmConfig;
use dj_core::online::{AcoustidMatch, MbRecording, Online, ReleaseItem, SimilarItem};
use serde_json::Value;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const USER_AGENT: &str = concat!(
    "DJAssistant/",
    env!("CARGO_PKG_VERSION"),
    " ( https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO )"
);

pub struct Http {
    agent: ureq::Agent,
    /// Long timeout for AI model replies (Claude).
    ai_agent: ureq::Agent,
    /// Loopback only, never through a proxy (local model server).
    local_agent: ureq::Agent,
    last_mb: Mutex<Option<Instant>>,
    call_seq: Mutex<u64>,
}

impl Default for Http {
    fn default() -> Self {
        Self::new()
    }
}

impl Http {
    /// Scans the local model server for every installed model.
    fn local_tags(&self, url: &str) -> Result<Vec<dj_core::online::LocalModel>, String> {
        let mut res = self
            .local_agent
            .get(&format!("{}/api/tags", url.trim_end_matches('/')))
            .call()
            .map_err(|e| local_unreachable(url, &e))?;
        let v: Value = res
            .body_mut()
            .read_json()
            .map_err(|e| format!("unexpected response: {e}"))?;
        Ok(llm::parse_ollama_tags(&v))
    }
    pub fn new() -> Self {
        let cfg = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(ureq::Proxy::try_from_env())
            .build();
        let ai = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(240)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(ureq::Proxy::try_from_env())
            .build();
        let local = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(600)))
            .timeout_connect(Some(Duration::from_secs(3)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(None)
            .build();
        Http {
            agent: cfg.into(),
            ai_agent: ai.into(),
            local_agent: local.into(),
            last_mb: Mutex::new(None),
            call_seq: Mutex::new(0),
        }
    }

    fn mb_throttle(&self) {
        let mut l = self.last_mb.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(t) = *l {
            let el = t.elapsed();
            if el < Duration::from_millis(1050) {
                std::thread::sleep(Duration::from_millis(1050) - el);
            }
        }
        *l = Some(Instant::now());
    }

    fn get_json(&self, url: &str, query: &[(&str, &str)]) -> Result<Value, String> {
        let mut req = self.agent.get(url).header("Accept", "application/json");
        for (k, v) in query {
            req = req.query(*k, *v);
        }
        let mut res = req.call().map_err(|e| format!("network error: {e}"))?;
        let status = res.status().as_u16();
        let body: Value = res
            .body_mut()
            .read_json()
            .map_err(|e| format!("unexpected response ({status}): {e}"))?;
        if status == 503 || status == 429 {
            return Err("the service is busy (rate limited); try again in a minute".into());
        }
        if status >= 400 {
            let msg = body
                .get("message")
                .or_else(|| body.pointer("/error/message"))
                .and_then(|m| m.as_str())
                .unwrap_or("request failed");
            return Err(format!("{msg} (HTTP {status})"));
        }
        Ok(body)
    }
}

fn quote(s: &str) -> String {
    // Lucene phrase: escape backslash and double quote
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn credit(v: &Value) -> String {
    v.get("artist-credit")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .map(|c| {
                    format!(
                        "{}{}",
                        c["name"].as_str().unwrap_or(""),
                        c["joinphrase"].as_str().unwrap_or("")
                    )
                })
                .collect::<String>()
        })
        .unwrap_or_default()
}

pub fn parse_mb_recordings(v: &Value) -> Vec<MbRecording> {
    v["recordings"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|r| {
                    let mut tags: Vec<(i64, String)> = r["tags"]
                        .as_array()
                        .map(|t| {
                            t.iter()
                                .filter_map(|x| {
                                    Some((
                                        x["count"].as_i64().unwrap_or(0),
                                        x["name"].as_str()?.to_string(),
                                    ))
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    tags.sort_by_key(|t| -t.0);
                    let rel = r["releases"].as_array().and_then(|x| {
                        x.iter()
                            .filter(|x| x["date"].is_string())
                            .min_by_key(|x| x["date"].as_str().unwrap_or("9999").to_string())
                            .or(x.first())
                    });
                    MbRecording {
                        mbid: r["id"].as_str().unwrap_or("").into(),
                        title: r["title"].as_str().unwrap_or("").into(),
                        artist: credit(r),
                        score: r["score"].as_f64().unwrap_or(0.0),
                        first_release_date: r["first-release-date"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .map(|s| s.into()),
                        release_title: rel.and_then(|x| x["title"].as_str()).map(|s| s.into()),
                        label: None,
                        tags: tags.into_iter().map(|t| t.1).take(5).collect(),
                        isrcs: r["isrcs"]
                            .as_array()
                            .map(|x| {
                                x.iter()
                                    .filter_map(|i| i.as_str().map(|s| s.into()))
                                    .collect()
                            })
                            .unwrap_or_default(),
                        length_ms: r["length"].as_i64(),
                        disambiguation: r["disambiguation"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .map(|s| s.into()),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn parse_acoustid(v: &Value) -> Result<Vec<AcoustidMatch>, String> {
    if v["status"] != "ok" {
        return Err(v
            .pointer("/error/message")
            .and_then(|m| m.as_str())
            .unwrap_or("AcoustID lookup failed")
            .into());
    }
    let mut out = vec![];
    for r in v["results"].as_array().into_iter().flatten() {
        let score = r["score"].as_f64().unwrap_or(0.0);
        for rec in r["recordings"].as_array().into_iter().flatten() {
            out.push(AcoustidMatch {
                score,
                recording_mbid: rec["id"].as_str().unwrap_or("").into(),
                title: rec["title"].as_str().map(|s| s.into()),
                artist: rec["artists"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|x| x["name"].as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .filter(|s| !s.is_empty()),
                first_year: None,
            });
        }
    }
    out.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Ok(out)
}

pub fn parse_lastfm_artists(v: &Value) -> Result<Vec<SimilarItem>, String> {
    if let Some(e) = v["message"].as_str().filter(|_| v["error"].is_number()) {
        return Err(format!("Last.fm: {e}"));
    }
    Ok(v.pointer("/similarartists/artist")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| {
                    Some(SimilarItem {
                        artist: x["name"].as_str()?.into(),
                        title: None,
                        score: x["match"]
                            .as_str()
                            .and_then(|m| m.parse().ok())
                            .or(x["match"].as_f64())
                            .unwrap_or(0.0),
                        url: x["url"].as_str().map(|s| s.into()),
                    })
                })
                .collect()
        })
        .unwrap_or_default())
}

pub fn parse_lastfm_tracks(v: &Value) -> Result<Vec<SimilarItem>, String> {
    if let Some(e) = v["message"].as_str().filter(|_| v["error"].is_number()) {
        return Err(format!("Last.fm: {e}"));
    }
    Ok(v.pointer("/similartracks/track")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| {
                    Some(SimilarItem {
                        artist: x.pointer("/artist/name")?.as_str()?.into(),
                        title: x["name"].as_str().map(|s| s.into()),
                        score: x["match"]
                            .as_f64()
                            .or(x["match"].as_str().and_then(|m| m.parse().ok()))
                            .unwrap_or(0.0),
                        url: x["url"].as_str().map(|s| s.into()),
                    })
                })
                .collect()
        })
        .unwrap_or_default())
}

/// Today's date as YYYY-MM-DD (UTC) without extra dependencies.
fn days_ago(days: i64) -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
        - days * 86_400;
    let z = secs.div_euclid(86_400) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}")
}

impl Online for Http {
    fn llm_chat(
        &self,
        cfg: &LlmConfig,
        system: &str,
        tools: &[Value],
        messages: &[Value],
    ) -> Result<Value, String> {
        match cfg.provider.as_str() {
            "claude" => {
                let key = cfg
                    .api_key
                    .as_deref()
                    .ok_or("no Anthropic API key is set")?;
                let body = llm::claude_body(&cfg.model, system, tools, messages);
                let mut req = self
                    .ai_agent
                    .post(llm::ANTHROPIC_URL)
                    .header("x-api-key", key)
                    .header("anthropic-version", llm::ANTHROPIC_VERSION)
                    .header("content-type", "application/json");
                if llm::supports_fallback(&cfg.model) {
                    req = req.header("anthropic-beta", llm::FALLBACK_BETA);
                }
                let mut res = req
                    .send_json(&body)
                    .map_err(|e| format!("network error: {e}"))?;
                let status = res.status().as_u16();
                let v: Value = res
                    .body_mut()
                    .with_config()
                    .limit(32 * 1024 * 1024)
                    .read_json()
                    .map_err(|e| format!("unexpected response ({status}): {e}"))?;
                if status >= 400 {
                    return Err(llm::claude_error(status, &v));
                }
                Ok(v)
            }
            "local" => {
                let url = format!("{}/api/chat", cfg.local_url.trim_end_matches('/'));
                let send = |tools: &[Value], ctx: Option<u64>| -> Result<(u16, Value), String> {
                    let body = llm::ollama_body(&cfg.model, system, tools, messages, ctx);
                    let mut res = self
                        .local_agent
                        .post(&url)
                        .send_json(&body)
                        .map_err(|e| local_unreachable(&cfg.local_url, &e))?;
                    let status = res.status().as_u16();
                    let v: Value = res
                        .body_mut()
                        .with_config()
                        .limit(32 * 1024 * 1024)
                        .read_json()
                        .map_err(|e| format!("unexpected response ({status}): {e}"))?;
                    Ok((status, v))
                };
                let mut tools = tools;
                let mut ctx = None;
                let (mut status, mut v) = send(tools, ctx)?;
                for _ in 0..2 {
                    if status != 400 {
                        break;
                    }
                    if !tools.is_empty() && llm::ollama_no_tools(&v) {
                        // Many local models can't call tools: answer as a plain chat instead.
                        tools = &[];
                    } else if let Some(n) = llm::ollama_too_long(&v).filter(|_| ctx.is_none()) {
                        // Still too long for the window we asked for: ask for one that fits.
                        ctx = Some(llm::fit_context(n));
                    } else {
                        break;
                    }
                    (status, v) = send(tools, ctx)?;
                }
                if status == 404 {
                    return Err(format!(
                        "the model '{}' isn't installed. Run: ollama pull {}",
                        cfg.model, cfg.model
                    ));
                }
                if status >= 400 {
                    return Err(format!(
                        "{} (HTTP {status})",
                        v["error"].as_str().unwrap_or("the local model failed")
                    ));
                }
                let mut seq = self.call_seq.lock().unwrap_or_else(|e| e.into_inner());
                Ok(llm::from_ollama(&v, &mut seq))
            }
            other => Err(format!("unknown AI provider '{other}'")),
        }
    }

    fn llm_local_models(&self, url: &str) -> Result<Vec<String>, String> {
        Ok(self.local_tags(url)?.into_iter().map(|m| m.name).collect())
    }

    fn llm_local_probe(&self, url: &str) -> dj_core::online::LocalProbe {
        let tags = self.local_tags(url);
        let details = tags.clone().unwrap_or_default();
        dj_core::online::LocalProbe {
            installed: ollama_exe().is_some() || tags.is_ok(),
            running: tags.is_ok(),
            models: details.iter().map(|m| m.name.clone()).collect(),
            details,
        }
    }

    fn llm_local_start(&self) -> Result<(), String> {
        let exe = ollama_exe()
            .ok_or("Ollama isn't installed on this computer. Download it free from ollama.com.")?;
        // On Windows prefer the tray app (it runs the server and keeps it running);
        // otherwise run "ollama serve" in the background.
        let app = exe.with_file_name("ollama app.exe");
        let mut cmd = if app.is_file() {
            std::process::Command::new(app)
        } else {
            let mut c = std::process::Command::new(&exe);
            c.arg("serve");
            c
        };
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            const DETACHED_PROCESS: u32 = 0x0000_0008;
            cmd.creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS);
        }
        cmd.spawn()
            .map_err(|e| format!("couldn't start Ollama: {e}"))?;
        Ok(())
    }

    fn llm_local_pull(
        &self,
        url: &str,
        model: &str,
        progress: &mut dyn FnMut(u64, u64, &str) -> bool,
    ) -> Result<(), String> {
        use std::io::BufRead;
        // Model downloads take minutes to hours: no overall timeout, only on connecting.
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(None)
            .timeout_connect(Some(Duration::from_secs(3)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(None)
            .build()
            .into();
        let mut res = agent
            .post(&format!("{}/api/pull", url.trim_end_matches('/')))
            .send_json(serde_json::json!({"model": model, "stream": true}))
            .map_err(|e| local_unreachable(url, &e))?;
        let status = res.status().as_u16();
        if status >= 400 {
            let v: Value = res.body_mut().read_json().unwrap_or(Value::Null);
            return Err(v["error"]
                .as_str()
                .map(|e| e.to_string())
                .unwrap_or(format!("download failed (HTTP {status})")));
        }
        let reader = std::io::BufReader::new(res.body_mut().with_config().limit(u64::MAX).reader());
        let mut parts = llm::PullProgress::default();
        for line in reader.lines() {
            let line = line.map_err(|e| format!("download interrupted: {e}"))?;
            let Ok(ev) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let (done, total, status, finished) = parts.update(&ev)?;
            if !progress(done, total, &status) {
                return Err("download stopped".into());
            }
            if finished {
                return Ok(());
            }
        }
        Err("the download ended before it finished; try again to resume".into())
    }

    fn musicbrainz_recordings(
        &self,
        artist: &str,
        title: &str,
    ) -> Result<Vec<MbRecording>, String> {
        self.mb_throttle();
        let q = format!("recording:{} AND artist:{}", quote(title), quote(artist));
        let v = self.get_json(
            "https://musicbrainz.org/ws/2/recording",
            &[("query", &q), ("fmt", "json"), ("limit", "5")],
        )?;
        Ok(parse_mb_recordings(&v))
    }

    fn musicbrainz_artist_releases(&self, artist: &str) -> Result<Vec<ReleaseItem>, String> {
        self.mb_throttle();
        let v = self.get_json(
            "https://musicbrainz.org/ws/2/artist",
            &[
                ("query", &format!("artist:{}", quote(artist))),
                ("fmt", "json"),
                ("limit", "1"),
            ],
        )?;
        let Some(a) = v["artists"]
            .as_array()
            .and_then(|a| a.first())
            .filter(|a| a["score"].as_i64().unwrap_or(0) >= 90)
        else {
            return Ok(vec![]);
        };
        let id = a["id"].as_str().unwrap_or("").to_string();
        let name = a["name"].as_str().unwrap_or(artist).to_string();
        self.mb_throttle();
        let v = self.get_json(
            "https://musicbrainz.org/ws/2/release-group",
            &[("artist", &id), ("fmt", "json"), ("limit", "100")],
        )?;
        let since = days_ago(365);
        Ok(v["release-groups"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|r| {
                r["first-release-date"]
                    .as_str()
                    .map(|d| d >= since.as_str())
                    .unwrap_or(false)
            })
            .map(|r| ReleaseItem {
                artist: name.clone(),
                title: r["title"].as_str().unwrap_or("").into(),
                date: r["first-release-date"].as_str().map(|s| s.into()),
                kind: r["primary-type"].as_str().unwrap_or("Release").into(),
                url: r["id"]
                    .as_str()
                    .map(|i| format!("https://musicbrainz.org/release-group/{i}")),
            })
            .collect())
    }

    fn acoustid_lookup(
        &self,
        api_key: &str,
        duration_s: u32,
        fingerprint: &str,
    ) -> Result<Vec<AcoustidMatch>, String> {
        let mut res = self
            .agent
            .post("https://api.acoustid.org/v2/lookup")
            .send_form([
                ("client", api_key),
                ("meta", "recordings"),
                ("duration", &duration_s.to_string()),
                ("fingerprint", fingerprint),
                ("format", "json"),
            ])
            .map_err(|e| format!("network error: {e}"))?;
        let v: Value = res
            .body_mut()
            .read_json()
            .map_err(|e| format!("unexpected response: {e}"))?;
        parse_acoustid(&v)
    }

    fn lastfm_similar_artists(
        &self,
        api_key: &str,
        artist: &str,
    ) -> Result<Vec<SimilarItem>, String> {
        let v = self.get_json(
            "https://ws.audioscrobbler.com/2.0/",
            &[
                ("method", "artist.getsimilar"),
                ("artist", artist),
                ("api_key", api_key),
                ("format", "json"),
                ("limit", "20"),
                ("autocorrect", "1"),
            ],
        )?;
        parse_lastfm_artists(&v)
    }

    fn lastfm_similar_tracks(
        &self,
        api_key: &str,
        artist: &str,
        title: &str,
    ) -> Result<Vec<SimilarItem>, String> {
        let v = self.get_json(
            "https://ws.audioscrobbler.com/2.0/",
            &[
                ("method", "track.getsimilar"),
                ("artist", artist),
                ("track", title),
                ("api_key", api_key),
                ("format", "json"),
                ("limit", "25"),
                ("autocorrect", "1"),
            ],
        )?;
        parse_lastfm_tracks(&v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_musicbrainz() {
        let v = json!({"recordings": [{"id": "r1", "score": 100, "title": "Essence", "length": 248000, "disambiguation": "",
            "artist-credit": [{"name": "Wizkid", "joinphrase": " feat. "}, {"name": "Tems", "joinphrase": ""}],
            "first-release-date": "2020-10-30", "releases": [{"title": "Made in Lagos", "date": "2020-10-30"}],
            "tags": [{"count": 1, "name": "pop"}, {"count": 3, "name": "afrobeats"}], "isrcs": ["USRC12003456"]}]});
        let r = parse_mb_recordings(&v);
        assert_eq!(r[0].artist, "Wizkid feat. Tems");
        assert_eq!(r[0].first_release_date.as_deref(), Some("2020-10-30"));
        assert_eq!(r[0].release_title.as_deref(), Some("Made in Lagos"));
        assert_eq!(r[0].tags[0], "afrobeats");
        assert_eq!(r[0].length_ms, Some(248000));
        assert!(r[0].disambiguation.is_none());
    }

    #[test]
    fn parses_acoustid_and_errors() {
        let ok = json!({"status": "ok", "results": [{"score": 0.9, "id": "a", "recordings": [{"id": "rec", "title": "T", "artists": [{"name": "A"}, {"name": "B"}]}]}]});
        let r = parse_acoustid(&ok).unwrap();
        assert_eq!(r[0].artist.as_deref(), Some("A, B"));
        let bad = json!({"status": "error", "error": {"code": 4, "message": "invalid API key"}});
        assert_eq!(parse_acoustid(&bad).unwrap_err(), "invalid API key");
    }

    #[test]
    fn parses_lastfm() {
        let a = json!({"similarartists": {"artist": [{"name": "Burna Boy", "match": "0.81", "url": "u"}]}});
        assert_eq!(parse_lastfm_artists(&a).unwrap()[0].score, 0.81);
        let t = json!({"similartracks": {"track": [{"name": "Ye", "match": 0.5, "artist": {"name": "Burna Boy"}}]}});
        assert_eq!(
            parse_lastfm_tracks(&t).unwrap()[0].title.as_deref(),
            Some("Ye")
        );
        let e = json!({"error": 10, "message": "Invalid API key"});
        assert!(parse_lastfm_artists(&e)
            .unwrap_err()
            .contains("Invalid API key"));
    }

    #[test]
    fn lucene_quoting_and_dates() {
        assert_eq!(quote(r#"Say "Hi" \o/"#), r#""Say \"Hi\" \\o/""#);
        assert_eq!(days_ago(0).len(), 10);
        assert!(days_ago(365) < days_ago(0));
    }
}

#[cfg(test)]
mod live {
    use super::*;
    /// Run with: cargo test -p dj-online -- --ignored (needs internet).
    #[test]
    #[ignore]
    fn live_musicbrainz_lookup() {
        let h = Http::new();
        let r = h
            .musicbrainz_recordings("Wizkid", "Essence")
            .expect("musicbrainz reachable");
        assert!(!r.is_empty());
        println!("{:?}", &r[..r.len().min(2)]);
    }
}

/// A plain-language message when nothing answers at the local model address.
fn local_unreachable(url: &str, e: &ureq::Error) -> String {
    let refused = matches!(e, ureq::Error::Io(io) if io.kind() == std::io::ErrorKind::ConnectionRefused)
        || e.to_string().to_ascii_lowercase().contains("refused");
    if refused {
        if ollama_exe().is_some() {
            format!("Ollama is installed but not running (nothing answers at {url}). Start it in Settings → AI assistant, or from the Start menu.")
        } else {
            "Ollama isn't installed on this computer yet. Set it up in Settings → AI assistant (free download from ollama.com).".to_string()
        }
    } else {
        format!("couldn't reach the local model server at {url}: {e}")
    }
}

/// Where the Ollama program is installed, if it is.
pub fn ollama_exe() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    let name = if cfg!(windows) {
        "ollama.exe"
    } else {
        "ollama"
    };
    let mut candidates: Vec<PathBuf> = vec![];
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(
            PathBuf::from(local)
                .join("Programs")
                .join("Ollama")
                .join(name),
        );
    }
    if let Some(pf) = std::env::var_os("ProgramFiles") {
        candidates.push(PathBuf::from(pf).join("Ollama").join(name));
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|d| d.join(name)));
    }
    candidates.extend(
        [
            "/usr/local/bin/ollama",
            "/usr/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        .map(PathBuf::from),
    );
    candidates.into_iter().find(|p| p.is_file())
}
