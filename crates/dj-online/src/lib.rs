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
use dj_core::online::{AcoustidMatch, CatalogMatch, MbRecording, Online, ReleaseItem, SimilarItem};
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
    /// Large downloads (packs): no overall time limit, only connect/idle limits.
    dl_agent: ureq::Agent,
    last_mb: Mutex<Option<Instant>>,
    last_deezer: Mutex<Option<Instant>>,
    last_itunes: Mutex<Option<Instant>>,
    last_spotify: Mutex<Option<Instant>>,
    last_gsb: Mutex<Option<Instant>>,
    /// Spotify app token: (credentials it was made for, token, expiry).
    spotify_token: Mutex<Option<(String, String, Instant)>>,
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
        let dl = ureq::Agent::config_builder()
            .timeout_connect(Some(Duration::from_secs(20)))
            .timeout_recv_body(Some(Duration::from_secs(120)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(ureq::Proxy::try_from_env())
            .build();
        Http {
            agent: cfg.into(),
            ai_agent: ai.into(),
            local_agent: local.into(),
            dl_agent: dl.into(),
            last_mb: Mutex::new(None),
            last_deezer: Mutex::new(None),
            last_itunes: Mutex::new(None),
            last_spotify: Mutex::new(None),
            last_gsb: Mutex::new(None),
            spotify_token: Mutex::new(None),
            call_seq: Mutex::new(0),
        }
    }

    /// Waits so calls through `slot` are at least `gap` apart (each service's fair-use limit).
    fn throttle(slot: &Mutex<Option<Instant>>, gap: Duration) {
        let mut l = slot.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(t) = *l {
            let el = t.elapsed();
            if el < gap {
                std::thread::sleep(gap - el);
            }
        }
        *l = Some(Instant::now());
    }

    /// Deezer: search, then the best match's track (BPM, date, ISRC) and album (genres, label).
    fn deezer(&self, artist: &str, title: &str) -> Result<Vec<CatalogMatch>, String> {
        let gap = Duration::from_millis(150); // 50 requests per 5 s allowed
        Self::throttle(&self.last_deezer, gap);
        let q = format!("{artist} {title}");
        let v = self.get_json(
            "https://api.deezer.com/search",
            &[("q", &q), ("limit", "10")],
        )?;
        if let Some(e) = v.pointer("/error/message").and_then(|m| m.as_str()) {
            return Err(format!("Deezer: {e}"));
        }
        let (want_t, want_a) = (
            dj_core::text::base_title(title),
            dj_core::text::base_artist(artist),
        );
        let hits: Vec<&Value> = v["data"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|t| {
                let same_t = dj_core::text::base_title(t["title"].as_str().unwrap_or("")) == want_t
                    || dj_core::text::base_title(t["title_short"].as_str().unwrap_or("")) == want_t;
                let same_a = t
                    .pointer("/artist/name")
                    .and_then(|a| a.as_str())
                    .is_some_and(|a| dj_core::text::base_artist(a) == want_a);
                same_t && same_a
            })
            .take(3)
            .collect();
        if hits.is_empty() {
            return Ok(vec![]);
        }
        // The main edition, with its album (genres, label).
        let mut main: Option<CatalogMatch> = None;
        for (i, hit) in hits.iter().enumerate() {
            Self::throttle(&self.last_deezer, gap);
            let t = self.get_json(
                &format!(
                    "https://api.deezer.com/track/{}",
                    hit["id"].as_i64().unwrap_or(0)
                ),
                &[],
            )?;
            if i == 0 {
                let album_id = t.pointer("/album/id").and_then(|i| i.as_i64()).unwrap_or(0);
                let album = if album_id > 0 {
                    Self::throttle(&self.last_deezer, gap);
                    self.get_json(&format!("https://api.deezer.com/album/{album_id}"), &[])
                        .unwrap_or(Value::Null)
                } else {
                    Value::Null
                };
                main = parse_deezer(&t, &album);
                if main.as_ref().is_some_and(|m| m.bpm.is_some()) {
                    break;
                }
            } else if let Some(other) = parse_deezer(&t, &Value::Null) {
                // Deezer lists a tempo on some editions only: borrow one of the same length.
                let same_len = match (other.duration_ms, main.as_ref().and_then(|m| m.duration_ms))
                {
                    (Some(a), Some(b)) => (a - b).abs() <= 3000,
                    _ => false,
                };
                if same_len && other.bpm.is_some() {
                    if let Some(m) = main.as_mut() {
                        m.bpm = other.bpm;
                    }
                    break;
                }
            }
        }
        Ok(main.into_iter().collect())
    }

    /// Apple Music (iTunes Search API): genre, release date and length.
    fn itunes(&self, artist: &str, title: &str) -> Result<Vec<CatalogMatch>, String> {
        Self::throttle(&self.last_itunes, Duration::from_millis(3100)); // about 20 per minute
        let term = format!("{artist} {title}");
        let v = self.get_json(
            "https://itunes.apple.com/search",
            &[
                ("term", &term),
                ("media", "music"),
                ("entity", "song"),
                ("limit", "8"),
            ],
        )?;
        Ok(parse_itunes(&v))
    }

    /// GET with a bearer token; Ok(None) for 403/404 (a feature this app may not have).
    fn get_bearer(
        &self,
        url: &str,
        query: &[(&str, &str)],
        token: &str,
    ) -> Result<Option<Value>, String> {
        let mut req = self
            .agent
            .get(url)
            .header("Accept", "application/json")
            .header("Authorization", &format!("Bearer {token}"));
        for (k, v) in query {
            req = req.query(*k, *v);
        }
        let mut res = req.call().map_err(|e| format!("network error: {e}"))?;
        let status = res.status().as_u16();
        if status == 403 || status == 404 {
            return Ok(None);
        }
        let body: Value = res.body_mut().read_json().unwrap_or(Value::Null);
        match status {
            401 => Err("Spotify rejected the app's Client ID or secret. Check them in Settings → Online services.".into()),
            429 => Err("Spotify is rate limiting; try again in a minute".into()),
            s if s >= 400 => Err(format!("Spotify error (HTTP {s})")),
            _ => Ok(Some(body)),
        }
    }

    /// A Spotify app token from the client credentials (cached until it expires).
    fn spotify_token(&self, creds: &str) -> Result<String, String> {
        let mut t = self.spotify_token.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((c, tok, exp)) = t.as_ref() {
            if c == creds && Instant::now() < *exp {
                return Ok(tok.clone());
            }
        }
        let mut res = self
            .agent
            .post("https://accounts.spotify.com/api/token")
            .header(
                "Authorization",
                &format!("Basic {}", base64(creds.trim().as_bytes())),
            )
            .send_form([("grant_type", "client_credentials")])
            .map_err(|e| format!("Spotify sign-in failed: {e}"))?;
        let status = res.status().as_u16();
        let v: Value = res.body_mut().read_json().unwrap_or(Value::Null);
        let Some(tok) = v["access_token"].as_str().filter(|_| status < 400) else {
            return Err("Spotify rejected the app's Client ID or secret. Check them in Settings → Online services.".into());
        };
        let secs = v["expires_in"].as_u64().unwrap_or(3600).saturating_sub(60);
        *t = Some((
            creds.to_string(),
            tok.to_string(),
            Instant::now() + Duration::from_secs(secs),
        ));
        Ok(tok.to_string())
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

/// A Deezer track (with its album) as a catalogue match.
pub fn parse_deezer(track: &Value, album: &Value) -> Option<CatalogMatch> {
    let title = track["title"].as_str()?.to_string();
    let artist = track
        .pointer("/artist/name")
        .and_then(|a| a.as_str())?
        .to_string();
    let genres = album
        .pointer("/genres/data")
        .and_then(|g| g.as_array())
        .map(|g| {
            g.iter()
                .filter_map(|x| x["name"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let text = |v: &Value| {
        v.as_str()
            .filter(|s| !s.trim().is_empty() && *s != "0000-00-00")
            .map(str::to_string)
    };
    Some(CatalogMatch {
        source: "Deezer".into(),
        title,
        artist,
        album: text(&track["album"]["title"]),
        duration_ms: track["duration"]
            .as_i64()
            .filter(|d| *d > 0)
            .map(|d| d * 1000),
        bpm: track["bpm"].as_f64().filter(|b| *b > 0.0),
        release_date: text(&track["release_date"]).or_else(|| text(&album["release_date"])),
        genres,
        label: text(&album["label"]),
        isrc: text(&track["isrc"]),
        key: None,
    })
}

fn base64(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for c in b.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                out.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// "afro house" -> "Afro House" (Spotify genres are lower case).
fn title_case(g: &str) -> String {
    g.split(' ')
        .map(|w| {
            let mut c = w.chars();
            c.next()
                .map(|f| f.to_uppercase().chain(c).collect())
                .unwrap_or_default()
        })
        .collect::<Vec<String>>()
        .join(" ")
}

/// A Spotify search result as a catalogue match (genres, tempo and key are added separately).
pub fn parse_spotify_track(t: &Value) -> CatalogMatch {
    CatalogMatch {
        source: "Spotify".into(),
        title: t["name"].as_str().unwrap_or("").to_string(),
        artist: t["artists"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|a| a["name"].as_str())
            .collect::<Vec<_>>()
            .join(", "),
        album: t
            .pointer("/album/name")
            .and_then(|a| a.as_str())
            .map(str::to_string),
        duration_ms: t["duration_ms"].as_i64(),
        bpm: None,
        release_date: t
            .pointer("/album/release_date")
            .and_then(|d| d.as_str())
            .filter(|d| !d.is_empty())
            .map(str::to_string),
        genres: vec![],
        label: None,
        isrc: t
            .pointer("/external_ids/isrc")
            .and_then(|i| i.as_str())
            .map(str::to_string),
        key: None,
    }
}

/// Spotify audio features (tempo, key, mode), when the app is allowed them.
pub fn apply_audio_features(m: &mut CatalogMatch, f: &Value) {
    m.bpm = f["tempo"].as_f64().filter(|t| *t > 0.0);
    if let (Some(k), Some(mode)) = (f["key"].as_i64(), f["mode"].as_i64()) {
        m.key = dj_core::suggest::pitch_class_key(k, mode);
    }
}

/// ISO 8601 duration ("PT4M8S", "PT1H2M") in milliseconds.
fn iso_duration_ms(d: &str) -> Option<i64> {
    let t = d.strip_prefix("PT")?;
    let (mut total, mut num) = (0i64, String::new());
    for c in t.chars() {
        if c.is_ascii_digit() {
            num.push(c);
        } else {
            let n: i64 = num.parse().ok()?;
            num.clear();
            total += n * match c {
                'H' => 3_600_000,
                'M' => 60_000,
                'S' => 1000,
                _ => return None,
            };
        }
    }
    Some(total)
}

/// A YouTube Music release (an auto-generated "Artist - Topic" video). Its description reads:
/// "Provided to YouTube by <label>", "<title> · <artist> · …", "<album>", "℗ …", "Released on: YYYY-MM-DD".
pub fn parse_youtube_release(v: &Value) -> Option<CatalogMatch> {
    let sn = &v["snippet"];
    let channel = sn["channelTitle"]
        .as_str()?
        .strip_suffix(" - Topic")?
        .to_string();
    let desc = sn["description"].as_str().unwrap_or("");
    let label = desc
        .lines()
        .find_map(|l| l.trim().strip_prefix("Provided to YouTube by "))
        .map(|l| l.trim().to_string());
    let released = desc
        .lines()
        .find_map(|l| l.trim().strip_prefix("Released on: "))
        .map(|d| d.trim().to_string());
    // the paragraph after the "title · artist" line is the album
    let paras: Vec<&str> = desc
        .split("\n\n")
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect();
    let credit = paras.iter().position(|p| p.contains(" · "));
    let album = credit
        .and_then(|i| paras.get(i + 1))
        .filter(|p| !p.starts_with('℗') && !p.starts_with("Released on") && !p.contains('\n'))
        .map(|p| p.to_string());
    let artist = credit
        .and_then(|i| paras[i].split(" · ").nth(1))
        .map(str::to_string)
        .unwrap_or(channel);
    Some(CatalogMatch {
        source: "YouTube Music".into(),
        title: sn["title"].as_str()?.to_string(),
        artist,
        album,
        duration_ms: v
            .pointer("/contentDetails/duration")
            .and_then(|d| d.as_str())
            .and_then(iso_duration_ms),
        bpm: None,
        release_date: released,
        genres: vec![],
        label,
        isrc: None,
        key: None,
    })
}

/// GetSongBPM search results as catalogue matches.
pub fn parse_getsongbpm(v: &Value) -> Vec<CatalogMatch> {
    v["search"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            Some(CatalogMatch {
                source: "GetSongBPM".into(),
                title: r["title"].as_str()?.to_string(),
                artist: r
                    .pointer("/artist/name")
                    .and_then(|a| a.as_str())?
                    .to_string(),
                album: r
                    .pointer("/album/title")
                    .and_then(|a| a.as_str())
                    .map(str::to_string),
                duration_ms: None,
                bpm: r["tempo"]
                    .as_str()
                    .and_then(|t| t.trim().parse().ok())
                    .or(r["tempo"].as_f64())
                    .filter(|b: &f64| *b > 0.0),
                release_date: r.pointer("/album/year").and_then(|y| {
                    y.as_str()
                        .map(str::to_string)
                        .or(y.as_i64().map(|y| y.to_string()))
                }),
                genres: r
                    .pointer("/artist/genres")
                    .and_then(|g| g.as_array())
                    .map(|g| {
                        g.iter()
                            .filter_map(|x| x.as_str())
                            .map(title_case)
                            .collect()
                    })
                    .unwrap_or_default(),
                label: None,
                isrc: None,
                key: r["key_of"]
                    .as_str()
                    .filter(|k| !k.trim().is_empty())
                    .map(str::to_string),
            })
        })
        .collect()
}

/// iTunes Search API results as catalogue matches.
pub fn parse_itunes(v: &Value) -> Vec<CatalogMatch> {
    v["results"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["kind"].as_str().is_none_or(|k| k == "song"))
        .filter_map(|r| {
            Some(CatalogMatch {
                source: "Apple Music".into(),
                title: r["trackName"].as_str()?.to_string(),
                artist: r["artistName"].as_str()?.to_string(),
                album: r["collectionName"].as_str().map(str::to_string),
                duration_ms: r["trackTimeMillis"].as_i64(),
                bpm: None,
                release_date: r["releaseDate"]
                    .as_str()
                    .map(|d| d.chars().take(10).collect()),
                genres: r["primaryGenreName"]
                    .as_str()
                    .map(|g| vec![g.to_string()])
                    .unwrap_or_default(),
                label: None,
                isrc: None,
                key: None,
            })
        })
        .collect()
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
            _ if !cfg.base_url.is_empty() => {
                // OpenAI-compatible service (OpenAI, Gemini, Groq, Mistral, DeepSeek, xAI…)
                let url = format!("{}/chat/completions", cfg.base_url.trim_end_matches('/'));
                let send = |tools: &[Value]| -> Result<(u16, Value), String> {
                    let mut req = self
                        .ai_agent
                        .post(&url)
                        .header("content-type", "application/json");
                    if let Some(k) = cfg.api_key.as_deref() {
                        req = req.header("authorization", &format!("Bearer {k}"));
                    }
                    if cfg.provider == "openrouter" {
                        req = req.header("x-title", "DJ Assistant");
                    }
                    let mut res = req
                        .send_json(llm::openai_body(&cfg.model, system, tools, messages))
                        .map_err(|e| format!("{} could not be reached: {e}", cfg.label))?;
                    let status = res.status().as_u16();
                    let v: Value = res
                        .body_mut()
                        .with_config()
                        .limit(32 * 1024 * 1024)
                        .read_json()
                        .unwrap_or(Value::Null);
                    Ok((status, v))
                };
                let (mut status, mut v) = send(tools)?;
                if !tools.is_empty() && llm::openai_no_tools(status, &v) {
                    (status, v) = send(&[])?;
                }
                if status >= 400 {
                    return Err(llm::openai_error(&cfg.label, status, &v));
                }
                let mut seq = self.call_seq.lock().unwrap_or_else(|e| e.into_inner());
                Ok(llm::from_openai(&v, &mut seq))
            }
            other => Err(format!("unknown AI provider '{other}'")),
        }
    }

    fn llm_list_models(&self, cfg: &LlmConfig) -> Result<Vec<String>, String> {
        let mut req = self
            .ai_agent
            .get(&format!("{}/models", cfg.base_url.trim_end_matches('/')));
        if let Some(k) = cfg.api_key.as_deref() {
            req = req.header("authorization", &format!("Bearer {k}"));
        }
        let mut res = req
            .call()
            .map_err(|e| format!("{} could not be reached: {e}", cfg.label))?;
        let status = res.status().as_u16();
        let v: Value = res.body_mut().read_json().unwrap_or(Value::Null);
        if status >= 400 {
            return Err(llm::openai_error(&cfg.label, status, &v));
        }
        let mut ids: Vec<String> = v["data"]
            .as_array()
            .or(v["models"].as_array())
            .into_iter()
            .flatten()
            .filter_map(|m| m["id"].as_str().or(m["name"].as_str()))
            .map(|id| id.trim_start_matches("models/").to_string())
            .collect();
        ids.sort();
        ids.dedup();
        Ok(ids)
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

    fn llm_local_install(&self, progress: &mut dyn FnMut(u64, u64) -> bool) -> Result<(), String> {
        if !cfg!(windows) {
            return Err(
                "one-click install is for Windows; on this system install Ollama from ollama.com"
                    .into(),
            );
        }
        let dir = std::env::temp_dir().join("dj-assistant-ollama");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let setup = dir.join("OllamaSetup.exe");
        // Ollama's official Windows installer (MIT); it redirects to the current GitHub release.
        let url = "https://ollama.com/download/OllamaSetup.exe";
        // the size is only for the progress bar: unknown is fine
        let total = self
            .dl_agent
            .head(url)
            .call()
            .ok()
            .filter(|r| r.status().is_success())
            .and_then(|r| {
                r.headers()
                    .get("content-length")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse().ok())
            })
            .unwrap_or(0u64);
        let mut stopped = false;
        self.download(url, &setup, &mut |now| {
            let go = progress(now, total);
            stopped = !go;
            go
        })?;
        if stopped {
            return Err("stopped".into());
        }
        // Inno Setup: install for this user only, with no windows or questions.
        let mut cmd = std::process::Command::new(&setup);
        cmd.args(["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let status = cmd
            .status()
            .map_err(|e| format!("couldn't run the Ollama installer: {e}"))?;
        let _ = std::fs::remove_file(&setup);
        if !status.success() {
            return Err(format!(
                "the Ollama installer stopped with code {:?}",
                status.code()
            ));
        }
        if ollama_exe().is_none() {
            return Err(
                "Ollama was installed but can't be found yet; restart DJ Assistant and try again"
                    .into(),
            );
        }
        Ok(())
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

    fn download(
        &self,
        url: &str,
        dest: &std::path::Path,
        progress: &mut dyn FnMut(u64) -> bool,
    ) -> Result<(), String> {
        use std::io::{Read, Write};
        let have = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
        let mut req = self.dl_agent.get(url);
        if have > 0 {
            req = req.header("Range", &format!("bytes={have}-"));
        }
        let mut res = req.call().map_err(|e| format!("download failed: {e}"))?;
        let status = res.status().as_u16();
        if status == 416 {
            return Ok(()); // already complete
        }
        if status >= 400 {
            return Err(format!("download failed (HTTP {status})"));
        }
        // 206 resumes; 200 means the server sent the whole file again
        let resumed = status == 206;
        let mut out = std::fs::OpenOptions::new()
            .create(true)
            .append(resumed)
            .write(true)
            .truncate(!resumed)
            .open(dest)
            .map_err(|e| format!("can't write {}: {e}", dest.display()))?;
        let mut written = if resumed { have } else { 0 };
        let mut body = res.body_mut().with_config().limit(u64::MAX).reader();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = body
                .read(&mut buf)
                .map_err(|e| format!("download interrupted: {e}"))?;
            if n == 0 {
                break;
            }
            out.write_all(&buf[..n])
                .map_err(|e| format!("can't write: {e}"))?;
            written += n as u64;
            if !progress(written) {
                break;
            }
        }
        out.flush().map_err(|e| e.to_string())?;
        Ok(())
    }

    fn catalog_lookup(&self, artist: &str, title: &str) -> Result<Vec<CatalogMatch>, String> {
        // Either catalogue on its own is useful; both failing is an error.
        let d = self.deezer(artist, title);
        let i = self.itunes(artist, title);
        match (d, i) {
            (Err(a), Err(b)) => Err(format!("{a}; Apple Music: {b}")),
            (d, i) => Ok(d
                .unwrap_or_default()
                .into_iter()
                .chain(i.unwrap_or_default())
                .collect()),
        }
    }

    fn spotify_lookup(
        &self,
        creds: &str,
        artist: &str,
        title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        let token = self.spotify_token(creds)?;
        let gap = Duration::from_millis(120);
        Self::throttle(&self.last_spotify, gap);
        let q = format!("track:{title} artist:{artist}");
        let Some(v) = self.get_bearer(
            "https://api.spotify.com/v1/search",
            &[("q", &q), ("type", "track"), ("limit", "8")],
            &token,
        )?
        else {
            return Ok(vec![]);
        };
        let (want_t, want_a) = (
            dj_core::text::base_title(title),
            dj_core::text::base_artist(artist),
        );
        let items: Vec<&Value> = v
            .pointer("/tracks/items")
            .and_then(|i| i.as_array())
            .into_iter()
            .flatten()
            .filter(|t| {
                dj_core::text::base_title(t["name"].as_str().unwrap_or("")) == want_t
                    && t.pointer("/artists/0/name")
                        .and_then(|a| a.as_str())
                        .is_some_and(|a| dj_core::text::base_artist(a) == want_a)
            })
            .take(3)
            .collect();
        let mut out = vec![];
        for (i, t) in items.iter().enumerate() {
            let mut m = parse_spotify_track(t);
            if i == 0 {
                // genres live on the artist; tempo and key on audio features (older apps only)
                if let Some(aid) = t.pointer("/artists/0/id").and_then(|a| a.as_str()) {
                    Self::throttle(&self.last_spotify, gap);
                    if let Some(a) = self.get_bearer(
                        &format!("https://api.spotify.com/v1/artists/{aid}"),
                        &[],
                        &token,
                    )? {
                        m.genres = a["genres"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|g| g.as_str())
                            .map(title_case)
                            .collect();
                    }
                }
                if let Some(id) = t["id"].as_str() {
                    Self::throttle(&self.last_spotify, gap);
                    if let Some(f) = self
                        .get_bearer(
                            &format!("https://api.spotify.com/v1/audio-features/{id}"),
                            &[],
                            &token,
                        )
                        .unwrap_or(None)
                    {
                        apply_audio_features(&mut m, &f);
                    }
                }
            }
            out.push(m);
        }
        Ok(out)
    }

    fn youtube_lookup(
        &self,
        api_key: &str,
        artist: &str,
        title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        let q = format!("{artist} {title}");
        let yt = |url: &str, query: &[(&str, &str)]| -> Result<Value, String> {
            let mut req = self
                .agent
                .get(url)
                .header("Accept", "application/json")
                .query("key", api_key);
            for (k, v) in query {
                req = req.query(*k, *v);
            }
            let mut res = req.call().map_err(|e| format!("network error: {e}"))?;
            let status = res.status().as_u16();
            let v: Value = res.body_mut().read_json().unwrap_or(Value::Null);
            if status >= 400 {
                let reason = v
                    .pointer("/error/errors/0/reason")
                    .and_then(|r| r.as_str())
                    .unwrap_or("");
                return Err(match reason {
                    "quotaExceeded" | "dailyLimitExceeded" => {
                        "YouTube: the free daily quota is used up".to_string()
                    }
                    _ if status == 400 || status == 403 => {
                        "YouTube rejected the API key. Check it in Settings → Online services."
                            .to_string()
                    }
                    _ => format!("YouTube error (HTTP {status})"),
                });
            }
            Ok(v)
        };
        // Official releases are uploaded to "Artist - Topic" channels in the Music category.
        let found = yt(
            "https://www.googleapis.com/youtube/v3/search",
            &[
                ("part", "snippet"),
                ("q", &q),
                ("type", "video"),
                ("videoCategoryId", "10"),
                ("maxResults", "5"),
            ],
        )?;
        let ids: Vec<&str> = found["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|i| {
                i.pointer("/snippet/channelTitle")
                    .and_then(|c| c.as_str())
                    .is_some_and(|c| c.ends_with(" - Topic"))
            })
            .filter_map(|i| i.pointer("/id/videoId").and_then(|v| v.as_str()))
            .take(3)
            .collect();
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let v = yt(
            "https://www.googleapis.com/youtube/v3/videos",
            &[("part", "snippet,contentDetails"), ("id", &ids.join(","))],
        )?;
        Ok(v["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(parse_youtube_release)
            .collect())
    }

    fn getsongbpm_lookup(
        &self,
        api_key: &str,
        artist: &str,
        title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        Self::throttle(&self.last_gsb, Duration::from_millis(1300)); // 3000 requests per hour
        let lookup = format!("song:{title} artist:{artist}");
        let v = self.get_json(
            "https://api.getsong.co/search/",
            &[("api_key", api_key), ("type", "both"), ("lookup", &lookup)],
        )?;
        if let Some(e) = v.pointer("/search/error").and_then(|e| e.as_str()) {
            return if e.to_ascii_lowercase().contains("no result") {
                Ok(vec![])
            } else {
                Err(format!("GetSongBPM: {e}"))
            };
        }
        Ok(parse_getsongbpm(&v))
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
    #[test]
    fn parses_youtube_music_releases() {
        use serde_json::json;
        assert_eq!(iso_duration_ms("PT4M8S"), Some(248_000));
        assert_eq!(iso_duration_ms("PT1H2M"), Some(3_720_000));
        let v = json!({"snippet": {"title": "Get Lucky", "channelTitle": "Daft Punk - Topic",
            "description": "Provided to YouTube by Columbia\n\nGet Lucky · Daft Punk · Pharrell Williams · Nile Rodgers\n\nRandom Access Memories\n\n℗ 2013 Daft Life Limited\n\nReleased on: 2013-05-17\n\nAuto-generated by YouTube."},
            "contentDetails": {"duration": "PT6M9S"}});
        let m = parse_youtube_release(&v).unwrap();
        assert_eq!(m.source, "YouTube Music");
        assert_eq!(m.artist, "Daft Punk");
        assert_eq!(m.album.as_deref(), Some("Random Access Memories"));
        assert_eq!(m.label.as_deref(), Some("Columbia"));
        assert_eq!(m.release_date.as_deref(), Some("2013-05-17"));
        assert_eq!(m.duration_ms, Some(369_000));
        // ordinary uploads are not official releases
        assert!(parse_youtube_release(
            &json!({"snippet": {"title": "x", "channelTitle": "Some Uploader"}})
        )
        .is_none());
    }

    #[test]
    fn parses_spotify_and_getsongbpm() {
        use serde_json::json;
        assert_eq!(base64(b"client:secret"), "Y2xpZW50OnNlY3JldA==");
        assert_eq!(base64(b"ab"), "YWI=");
        let mut m = parse_spotify_track(
            &json!({"id": "x1", "name": "Get Lucky", "duration_ms": 248413,
            "artists": [{"name": "Daft Punk", "id": "a1"}, {"name": "Pharrell Williams"}],
            "album": {"name": "Random Access Memories", "release_date": "2013-05-17"}, "external_ids": {"isrc": "USQX91300108"}}),
        );
        assert_eq!(m.artist, "Daft Punk, Pharrell Williams");
        assert_eq!(m.release_date.as_deref(), Some("2013-05-17"));
        apply_audio_features(&mut m, &json!({"tempo": 116.047, "key": 9, "mode": 0}));
        assert_eq!((m.bpm, m.key.as_deref()), (Some(116.047), Some("Am")));
        assert_eq!(title_case("afro house"), "Afro House");
        let g = parse_getsongbpm(
            &json!({"search": [{"id": "1", "title": "Get Lucky", "tempo": "116", "key_of": "F♯m", "open_key": "4m",
            "artist": {"name": "Daft Punk", "genres": ["electronic", "house"]}, "album": {"title": "Random Access Memories", "year": "2013"}}]}),
        );
        assert_eq!(g[0].bpm, Some(116.0));
        assert_eq!(g[0].key.as_deref(), Some("F♯m"));
        assert_eq!(g[0].genres, vec!["Electronic", "House"]);
        assert_eq!(g[0].release_date.as_deref(), Some("2013"));
        assert!(parse_getsongbpm(&json!({"search": {"error": "no result"}})).is_empty());
    }

    #[test]
    fn parses_deezer_and_apple_music_catalogue_entries() {
        use serde_json::json;
        let track = json!({"id": 3135556, "title": "Harder, Better, Faster, Stronger", "duration": 224, "bpm": 123.4,
            "release_date": "2001-03-07", "isrc": "GBDUW0000059", "artist": {"name": "Daft Punk"}, "album": {"id": 302127, "title": "Discovery"}});
        let album = json!({"genres": {"data": [{"name": "Electro"}, {"name": "Dance"}]}, "label": "Parlophone (France)", "release_date": "2001-03-07"});
        let d = parse_deezer(&track, &album).unwrap();
        assert_eq!(
            (d.source.as_str(), d.bpm, d.duration_ms),
            ("Deezer", Some(123.4), Some(224_000))
        );
        assert_eq!(d.genres, vec!["Electro", "Dance"]);
        assert_eq!(d.label.as_deref(), Some("Parlophone (France)"));
        assert_eq!(d.release_date.as_deref(), Some("2001-03-07"));
        // Deezer reports an unknown tempo as 0 and unknown dates as 0000-00-00
        let none = parse_deezer(
            &json!({"title": "x", "artist": {"name": "y"}, "bpm": 0, "release_date": "0000-00-00"}),
            &serde_json::Value::Null,
        )
        .unwrap();
        assert_eq!((none.bpm, none.release_date), (None, None));
        let a = parse_itunes(&json!({"resultCount": 2, "results": [
            {"kind": "song", "trackName": "Harder, Better, Faster, Stronger", "artistName": "Daft Punk", "collectionName": "Discovery",
             "trackTimeMillis": 224693, "releaseDate": "2001-03-07T08:00:00Z", "primaryGenreName": "Electronic"},
            {"kind": "music-video", "trackName": "video", "artistName": "Daft Punk"}]}));
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].genres, vec!["Electronic"]);
        assert_eq!(a[0].release_date.as_deref(), Some("2001-03-07"));
        assert_eq!(a[0].source, "Apple Music");
    }

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
