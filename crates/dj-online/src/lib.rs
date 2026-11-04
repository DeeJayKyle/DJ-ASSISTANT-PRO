//! Optional online services. This crate is the ONLY place DJ Assistant talks
//! to the internet, and dj-core only calls it after the DJ has switched the
//! matching service on. Each provider's rules are respected:
//!
//! * MusicBrainz: max 1 request/second (enforced here and by the caller), a
//!   descriptive User-Agent, data CC0 (core data) — attribution shown in UI.
//! * AcoustID: user-supplied application key; ~3 requests/second max; the
//!   compressed fingerprint and duration are sent, never audio.
//! * Last.fm: user-supplied API key; results credited to Last.fm in the UI.
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
    last_mb: Mutex<Option<Instant>>,
}

impl Default for Http {
    fn default() -> Self {
        Self::new()
    }
}

impl Http {
    pub fn new() -> Self {
        let cfg = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .user_agent(USER_AGENT)
            .http_status_as_error(false)
            .proxy(ureq::Proxy::try_from_env())
            .build();
        Http {
            agent: cfg.into(),
            last_mb: Mutex::new(None),
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
