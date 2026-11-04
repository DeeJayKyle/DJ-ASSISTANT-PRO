//! Quick Prep's optional AI help: sharper clean names and genres, and set
//! orders from a request typed in plain words. It uses the model chosen for
//! the AI assistant (Claude with the DJ's key, or a local model), and is off
//! while the assistant is off.
//!
//! Only file names, tag text and the BPM/key/energy DJ Assistant already
//! knows are sent — never audio, paths or listening history. Answers are
//! suggestions: the UI shows them and the DJ's own edits always win.
use crate::error::{Error, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

/// The text of a model reply in the Messages format ({"content": [{"type":"text","text":…}]}).
pub fn reply_text(v: &Value) -> String {
    v["content"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|b| b["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Pulls the JSON object out of a model's answer (it may add ``` fences or prose).
pub fn extract_json(text: &str) -> Option<Value> {
    let t = text
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    serde_json::from_str(t).ok().or_else(|| {
        let (a, b) = (t.find('{')?, t.rfind('}')?);
        (a < b)
            .then(|| serde_json::from_str(&t[a..=b]).ok())
            .flatten()
    })
}

#[derive(Debug, Clone, Deserialize)]
pub struct TidyInput {
    pub id: i64,
    #[serde(default)]
    pub current: Value,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct TidyResult {
    pub id: i64,
    pub artist: String,
    pub title: String,
    pub mix: String,
    pub genre: Option<String>,
}

fn facts(conn: &Connection, id: i64) -> Result<Value> {
    conn.query_row(
        "SELECT t.file_name, t.artist, t.title, t.genre, COALESCE(u.bpm,t.bpm_tag,a.bpm), keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)), COALESCE(u.energy,a.energy)
         FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
        params![id],
        |r| {
            Ok(json!({"file": r.get::<_, String>(0)?, "tags": {"artist": r.get::<_, Option<String>>(1)?, "title": r.get::<_, Option<String>>(2)?, "genre": r.get::<_, Option<String>>(3)?},
                "bpm": r.get::<_, Option<f64>>(4)?.map(|b| (b * 10.0).round() / 10.0), "key": r.get::<_, Option<String>>(5)?, "energy": r.get::<_, Option<i64>>(6)?}))
        },
    )
    .map_err(|_| Error::NotFound(format!("track {id}")))
}

pub fn tidy_prompt(
    conn: &Connection,
    tracks: &[TidyInput],
    genres: &[String],
) -> Result<Vec<(String, String)>> {
    let mut items = vec![];
    for t in tracks {
        let mut f = facts(conn, t.id)?;
        f["id"] = json!(t.id.to_string());
        f["suggestion"] = t.current.clone();
        items.push(f);
    }
    let system = [
        "You help a DJ tidy their music library. For each track, return the real artist, the song title, and the mix/version name (e.g. \"Original Mix\", \"Extended Mix\", \"Joe Remix\", or empty), with normal capitalisation and without junk (track numbers, websites, \"free download\", bitrates, \"final v3\").",
        &format!("Also choose the single best genre from this list: {}.", genres.join(", ")),
        "Use the file name, the tags, the BPM and energy (1-10) as clues. Keep stylised names as the artist writes them (e.g. \"deadmau5\"). If unsure, keep the suggestion you were given.",
        "Answer only with JSON: {\"tracks\":[{\"id\":\"…\",\"artist\":\"…\",\"title\":\"…\",\"mix\":\"…\",\"genre\":\"…\"}]}",
    ]
    .join("\n");
    Ok(vec![
        ("system".into(), system),
        ("user".into(), serde_json::to_string(&items)?),
    ])
}

/// Reads the model's answer; anything malformed or unknown is dropped.
pub fn parse_tidy(text: &str, ids: &HashSet<i64>, genres: &[String]) -> Vec<TidyResult> {
    let Some(v) = extract_json(text) else {
        return vec![];
    };
    let list = v
        .get("tracks")
        .and_then(|t| t.as_array())
        .cloned()
        .or_else(|| v.as_array().cloned())
        .unwrap_or_default();
    let s = |r: &Value, k: &str, max: usize| {
        r.get(k)
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .chars()
            .take(max)
            .collect::<String>()
    };
    let mut out = vec![];
    let mut seen = HashSet::new();
    for r in list {
        let id = match &r["id"] {
            Value::String(s) => s.parse().ok(),
            Value::Number(n) => n.as_i64(),
            _ => None,
        };
        let Some(id) = id.filter(|i| ids.contains(i) && seen.insert(*i)) else {
            continue;
        };
        let title = s(&r, "title", 200);
        if title.is_empty() {
            continue;
        }
        let g = s(&r, "genre", 60).to_lowercase();
        out.push(TidyResult {
            id,
            artist: s(&r, "artist", 200),
            title,
            mix: s(&r, "mix", 100),
            genre: genres.iter().find(|x| x.to_lowercase() == g).cloned(),
        });
    }
    out
}

pub fn order_prompt(
    conn: &Connection,
    request: &str,
    ids: &[i64],
) -> Result<Vec<(String, String)>> {
    let mut items = vec![];
    for id in ids {
        let (artist, title, genre, bpm, key, energy): (String, String, Option<String>, Option<f64>, Option<String>, Option<i64>) = conn.query_row(
            "SELECT COALESCE(u.artist,t.artist,''), COALESCE(u.title,t.title,t.file_name), COALESCE(u.genre,t.genre), COALESCE(u.bpm,t.bpm_tag,a.bpm), keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)), COALESCE(u.energy,a.energy)
             FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
        )?;
        let name = if artist.is_empty() {
            title
        } else {
            format!("{artist} - {title}")
        };
        items.push(json!({"id": id.to_string(), "name": name, "bpm": bpm.map(|b| (b * 10.0).round() / 10.0), "key": key, "energy": energy, "genre": genre}));
    }
    Ok(vec![
        ("system".into(), "You are a DJ planning a set. Reorder the tracks to fit the request. Prefer smooth mixing: close BPMs, harmonic keys on the Camelot wheel (same number, ±1, or A↔B), and an energy arc that suits the request. Use every track exactly once. Answer only with JSON: {\"order\":[\"id\", …],\"note\":\"one short sentence on the idea\"}".into()),
        ("user".into(), format!("Request: {}\nTracks: {}", request.chars().take(500).collect::<String>(), serde_json::to_string(&items)?)),
    ])
}

/// Keeps every track exactly once: unknown ids dropped, forgotten ones appended.
pub fn parse_order(text: &str, ids: &[i64]) -> Option<(Vec<i64>, String)> {
    let v = extract_json(text)?;
    let arr = v.get("order")?.as_array()?;
    let known: HashSet<i64> = ids.iter().copied().collect();
    let mut seen = HashSet::new();
    let mut order = vec![];
    for x in arr {
        let id = match x {
            Value::String(s) => s.parse().ok(),
            Value::Number(n) => n.as_i64(),
            _ => None,
        };
        if let Some(id) = id.filter(|i| known.contains(i) && seen.insert(*i)) {
            order.push(id);
        }
    }
    order.extend(ids.iter().filter(|i| !seen.contains(i)));
    let note = v
        .get("note")
        .and_then(|n| n.as_str())
        .unwrap_or("")
        .chars()
        .take(240)
        .collect();
    Some((order, note))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_answers_defensively() {
        let ids: HashSet<i64> = [1, 2].into_iter().collect();
        let genres = vec!["Deep House".to_string(), "Techno".to_string()];
        let r = parse_tidy("```json\n{\"tracks\":[{\"id\":\"1\",\"artist\":\"DJ Kozi\",\"title\":\"Sunset Drive\",\"mix\":\"Original Mix\",\"genre\":\"deep house\"},{\"id\":\"99\",\"title\":\"x\"},{\"id\":2,\"title\":\"\"},{\"id\":1,\"title\":\"dup\"}]}\n```", &ids, &genres);
        assert_eq!(
            r,
            vec![TidyResult {
                id: 1,
                artist: "DJ Kozi".into(),
                title: "Sunset Drive".into(),
                mix: "Original Mix".into(),
                genre: Some("Deep House".into())
            }]
        );
        assert!(parse_tidy("sorry, I can't", &ids, &genres).is_empty());
        let (order, note) = parse_order(
            "Here you go: {\"order\":[\"3\",\"1\",\"1\",\"42\"],\"note\":\"Deep first.\"}",
            &[1, 2, 3],
        )
        .unwrap();
        assert_eq!(order, vec![3, 1, 2]);
        assert_eq!(note, "Deep first.");
        assert!(parse_order("{\"nope\":1}", &[1]).is_none());
    }

    #[test]
    fn reads_reply_text() {
        let v = json!({"content": [{"type": "text", "text": "{\"order\":[]}"}]});
        assert_eq!(reply_text(&v), "{\"order\":[]}");
        assert_eq!(reply_text(&json!({})), "");
    }
}
