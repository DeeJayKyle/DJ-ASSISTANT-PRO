//! Local rule-based assistant. It is NOT an AI model: it recognises a fixed
//! set of phrases, turns them into the same filters the UI uses, and says
//! exactly what it understood. It never performs file changes.
use crate::error::Result;
use crate::library::{self, TrackQuery};
use crate::rules::{MatchMode, RuleNode, RuleSet};
use crate::text::fold;
use rusqlite::Connection;
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Serialize)]
pub struct AssistantReply {
    pub reply: String,
    pub understood: Vec<String>,
    pub action: String, // search | navigate | help
    pub target: Option<String>,
    pub text: Option<String>,
    pub filters: Option<RuleSet>,
    pub total: Option<i64>,
    pub sample: Vec<library::TrackRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

fn cond(field: &str, op: &str, value: serde_json::Value) -> RuleNode {
    RuleNode::Condition {
        field: field.into(),
        op: op.into(),
        value,
    }
}

const HELP: &str = "I'm a local, rule-based helper (not an AI model). I can turn requests like these into library filters:\n\
• \"afrobeats from the 2010s energy 6-8 no live\"\n\
• \"house 120-128 bpm\"  • \"key 8A\"  • \"clean 90s hip hop\"\n\
• \"low bitrate\"  • \"lossless\"  • \"missing genre\"\n\
• \"show duplicates\"  • \"library health\"  • \"scan\"\n\
• \"plan a 2 hour wedding set\"  • \"gig mode\"  • \"gig pack\"  • \"suggestions\"\n\
Everything stays on this computer. I can't edit files, tags or Serato data.";

fn parse_range(s: &str) -> Option<(f64, f64)> {
    let s = s.replace('–', "-");
    if let Some((a, b)) = s.split_once('-') {
        let (a, b) = (a.trim().parse::<f64>().ok()?, b.trim().parse::<f64>().ok()?);
        return Some((a.min(b), a.max(b)));
    }
    s.trim().parse::<f64>().ok().map(|v| (v, v))
}

fn decade_of(tok: &str) -> Option<i64> {
    let t = tok
        .trim_end_matches("'s")
        .trim_end_matches('s')
        .trim_start_matches('\'');
    if !tok.ends_with('s') || !t.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    match t.len() {
        4 => t
            .parse::<i64>()
            .ok()
            .filter(|y| y % 10 == 0 && (1900..2100).contains(y)),
        2 => t.parse::<i64>().ok().filter(|y| y % 10 == 0).map(|y| {
            if y >= 30 {
                1900 + y
            } else {
                2000 + y
            }
        }),
        _ => None,
    }
}

fn is_camelot(t: &str) -> bool {
    let u = t.to_ascii_uppercase();
    let (n, l) = u.split_at(u.len().saturating_sub(1));
    (l == "A" || l == "B")
        && n.parse::<u8>()
            .map(|v| (1..=12).contains(&v))
            .unwrap_or(false)
}

pub fn handle(conn: &Connection, message: &str) -> Result<AssistantReply> {
    let msg = fold(message.trim());
    let mut understood = Vec::new();
    let nav = |target: &str, reply: &str| AssistantReply {
        reply: reply.into(),
        understood: vec![],
        action: "navigate".into(),
        target: Some(target.into()),
        text: None,
        filters: None,
        total: None,
        sample: vec![],
        params: None,
    };
    if msg.is_empty()
        || ["help", "?", "what can you do", "hi", "hello", "hey"].contains(&msg.as_str())
    {
        return Ok(AssistantReply {
            reply: HELP.into(),
            understood,
            action: "help".into(),
            target: None,
            text: None,
            filters: None,
            total: None,
            sample: vec![],
            params: None,
        });
    }
    // Set planning: "plan a 2 hour wedding set", "90 minute warm up set"
    if msg.contains(" set")
        && (msg.contains("plan")
            || msg.contains("build")
            || msg.contains("make")
            || msg.contains("hour")
            || msg.contains("minute")
            || msg.contains("min "))
    {
        let words: Vec<&str> = msg.split_whitespace().collect();
        let mut minutes: Option<u32> = None;
        for w in words.windows(2) {
            if let Ok(n) = w[0].parse::<f64>() {
                if w[1].starts_with("hour") || w[1] == "h" || w[1] == "hr" || w[1] == "hrs" {
                    minutes = Some((n * 60.0) as u32);
                } else if w[1].starts_with("min") {
                    minutes = Some(n as u32);
                }
            }
        }
        let event = [
            "wedding",
            "club",
            "festival",
            "corporate",
            "birthday",
            "lounge",
            "house party",
            "private party",
            "latin night",
        ]
        .iter()
        .find(|e| msg.contains(*e))
        .map(|e| e.to_string());
        let curve = if msg.contains("warm") {
            "warmup"
        } else if msg.contains("peak") {
            "peak"
        } else if msg.contains("wedding") {
            "wedding"
        } else if msg.contains("lounge") || msg.contains("chill") {
            "lounge"
        } else {
            "journey"
        };
        let clean = msg.contains("clean");
        let mut r = nav("set-studio", "Opening Set Studio with these settings. Review them and press Generate — the plan is a suggestion you can edit.");
        r.understood = vec![
            format!("length {} min", minutes.unwrap_or(60)),
            format!("energy journey: {curve}"),
        ];
        if let Some(e) = &event {
            r.understood.push(format!("event: {e}"));
        }
        if clean {
            r.understood.push("clean tracks only".into());
        }
        r.params = Some(
            serde_json::json!({"duration_min": minutes.unwrap_or(60), "event_type": event, "curve": curve, "clean_only": clean}),
        );
        return Ok(r);
    }
    for (words, target, reply) in [
        (&["gig mode", "start gig", "start a gig", "requests"][..], "gig", "Opening Gig Mode: set list, requests and notes, with background work paused."),
        (&["gig pack", "usb", "copy to drive", "pack"][..], "gig-pack", "Opening Gig Pack: choose tracks and a drive; copies are verified and nothing is overwritten."),
        (&["suggestion", "fix tags", "metadata", "musicbrainz"][..], "suggestions", "Opening Suggestions: review each one before it reaches your catalogue."),
        (&["discover", "recommend", "similar", "tracklist", "gaps"][..], "discovery", "Opening Discovery: recommendations always show their reason and source."),
        (&["analyse", "analyze", "analysis", "detect bpm", "detect key"][..], "activity", "Opening Scan & Analysis. Analysis reads your files and stores estimates you can override."),
        (&["template", "cheat sheet", "organise crates", "organize crates"][..], "crates", "Opening Virtual Crates, where you can add crate templates (genre, energy, utility, events, ratings)."),
        (&["personal files", "documents"][..], "files", "Opening Personal Files (opt-in, separate from music)."),
        (&["update"][..], "settings", "Opening Settings → Updates."),
    ] {
        if words.iter().any(|w| msg.contains(w)) {
            return Ok(nav(target, reply));
        }
    }
    if msg.contains("duplicate") || msg.contains("dupes") {
        return Ok(nav("duplicates", "Opening Duplicate review. Exact matches (identical file contents) are shown separately from possible matches and alternate versions. Nothing is deleted."));
    }
    if msg.contains("health")
        || msg.contains("problems")
        || msg.contains("errors")
        || msg.contains("corrupt")
    {
        return Ok(nav("health", "Opening Library health: missing metadata, unreadable files, low-bitrate warnings, offline drives and missing files."));
    }
    if msg == "scan"
        || msg.starts_with("scan ")
        || msg.starts_with("rescan")
        || msg.contains("add folder")
    {
        return Ok(nav("activity", "Opening Scan & Analysis. Choose a folder to add, then press Scan. Scanning only reads your files."));
    }

    let mut rules: Vec<RuleNode> = Vec::new();
    let mut exclude: Vec<RuleNode> = Vec::new();
    let mut words: Vec<String> = Vec::new();
    let raw: Vec<String> = msg
        .replace(',', " ")
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();
    // Merge "120 to 128" into "120-128" (numbers only, so titles stay intact).
    let mut toks: Vec<String> = Vec::new();
    let mut k = 0;
    while k < raw.len() {
        if k + 2 < raw.len()
            && raw[k + 1] == "to"
            && raw[k].parse::<f64>().is_ok()
            && raw[k + 2].parse::<f64>().is_ok()
        {
            toks.push(format!("{}-{}", raw[k], raw[k + 2]));
            k += 3;
        } else {
            toks.push(raw[k].clone());
            k += 1;
        }
    }
    let stop = [
        "show", "me", "find", "list", "tracks", "songs", "music", "with", "from", "the", "in",
        "of", "and", "some", "all", "my", "a", "for", "era", "please", "that", "are", "is", "only",
    ];
    let mut i = 0;
    let mut negate_next = false;
    while i < toks.len() {
        let t = toks[i].as_str();
        let next = toks.get(i + 1).map(|s| s.as_str());
        if [
            "no",
            "not",
            "without",
            "exclude",
            "excluding",
            "except",
            "minus",
        ]
        .contains(&t)
        {
            negate_next = true;
            i += 1;
            continue;
        }
        let push =
            |node: RuleNode, neg: bool, rules: &mut Vec<RuleNode>, exclude: &mut Vec<RuleNode>| {
                if neg {
                    exclude.push(node)
                } else {
                    rules.push(node)
                }
            };
        // version words
        let version_word = match t.trim_end_matches('s') {
            "live" => Some("live"),
            "remix" => Some("remix"),
            "edit" => Some("edit"),
            "acapella" => Some("acapella"),
            "instrumental" => Some("instrumental"),
            "extended" => Some("extended"),
            "intro" => Some("intro"),
            "dub" => Some("dub"),
            "bootleg" => Some("bootleg"),
            "mashup" => Some("mashup"),
            _ => None,
        };
        if let Some(v) = version_word {
            push(
                cond("version", "contains", json!(v)),
                negate_next,
                &mut rules,
                &mut exclude,
            );
            understood.push(format!(
                "{} version label contains \"{v}\"",
                if negate_next { "excluding" } else { "with" }
            ));
            negate_next = false;
            i += 1;
            continue;
        }
        if t == "clean" || t == "explicit" || t == "dirty" {
            let v = if t == "clean" { "clean" } else { "explicit" };
            if negate_next {
                exclude.push(cond("clean_explicit", "equals", json!(v)));
                understood.push(format!("excluding tracks marked {v}"));
            } else {
                rules.push(cond("clean_explicit", "equals", json!(v)));
                understood.push(format!("marked {v} (from your catalogue or the title)"));
            }
            negate_next = false;
            i += 1;
            continue;
        }
        if let Some(d) = decade_of(t) {
            rules.push(cond("decade", "eq", json!(d)));
            understood.push(format!("decade {d}s"));
            i += 1;
            continue;
        }
        if t == "bpm" {
            if let Some((a, b)) = next.and_then(parse_range) {
                rules.push(cond("bpm", "between", json!([a, b])));
                understood.push(format!("BPM {a}–{b}"));
                i += 2;
                continue;
            }
        }
        if next == Some("bpm") {
            if let Some((a, b)) = parse_range(t) {
                rules.push(cond("bpm", "between", json!([a, b])));
                understood.push(format!("BPM {a}–{b}"));
                i += 2;
                continue;
            }
        }
        if t == "energy" {
            if let Some((a, b)) = next.and_then(parse_range) {
                rules.push(cond("energy", "between", json!([a, b])));
                understood.push(format!("energy {a}–{b}"));
                i += 2;
                continue;
            }
        }
        if (t == "high" || t == "low" || t == "medium") && next == Some("energy") {
            let (a, b) = match t {
                "high" => (7, 10),
                "low" => (1, 4),
                _ => (5, 6),
            };
            rules.push(cond("energy", "between", json!([a, b])));
            understood.push(format!("{t} energy ({a}–{b}, from your ratings)"));
            i += 2;
            continue;
        }
        if t == "low" && next == Some("bitrate") || t == "low-bitrate" {
            rules.push(cond("quality", "equals", json!("low_bitrate")));
            understood.push("low-bitrate lossy files".into());
            i += if t == "low" { 2 } else { 1 };
            continue;
        }
        if t == "lossless" {
            rules.push(cond("quality", "equals", json!("lossless")));
            understood.push("lossless files".into());
            i += 1;
            continue;
        }
        if t == "missing" || t == "no-genre" {
            if let Some(f) =
                next.filter(|n| ["genre", "year", "artist", "title", "bpm", "key"].contains(n))
            {
                rules.push(cond(f, "is_empty", json!(null)));
                understood.push(format!("{f} is unknown"));
                i += 2;
                continue;
            }
        }
        if t == "key" {
            if let Some(k) = next {
                rules.push(cond("key", "equals", json!(k.to_ascii_uppercase())));
                understood.push(format!("key {}", k.to_ascii_uppercase()));
                i += 2;
                continue;
            }
        }
        if is_camelot(t) {
            rules.push(cond("key", "equals", json!(t.to_ascii_uppercase())));
            understood.push(format!("key {}", t.to_ascii_uppercase()));
            i += 1;
            continue;
        }
        if t.contains('-') {
            if let Some((a, b)) = parse_range(t) {
                if (1900.0..2100.0).contains(&a) && (1900.0..2100.0).contains(&b) {
                    rules.push(cond("year", "between", json!([a, b])));
                    understood.push(format!("year {a}–{b}"));
                    i += 1;
                    continue;
                }
            }
        }
        if t.len() == 4 && t.chars().all(|c| c.is_ascii_digit()) {
            let y: i64 = t.parse().unwrap_or(0);
            if (1900..2100).contains(&y) {
                rules.push(cond("year", "eq", json!(y)));
                understood.push(format!("year {y}"));
                i += 1;
                continue;
            }
        }
        if (t.ends_with("star") || t.ends_with("stars"))
            || (next.map(|n| n.starts_with("star")).unwrap_or(false) && t.parse::<i64>().is_ok())
        {
            let n: Option<i64> = t
                .trim_end_matches("stars")
                .trim_end_matches("star")
                .trim_end_matches('+')
                .parse()
                .ok();
            if let Some(n) = n.filter(|n| (0..=5).contains(n)) {
                rules.push(cond("rating", "gte", json!(n)));
                understood.push(format!("rated {n}+ stars"));
                i += if t.parse::<i64>().is_ok() { 2 } else { 1 };
                continue;
            }
        }
        if !stop.contains(&t) {
            if negate_next {
                exclude.push(RuleNode::Group {
                    match_mode: MatchMode::Any,
                    rules: vec![
                        cond("genre", "contains", json!(t)),
                        cond("title", "contains", json!(t)),
                        cond("artist", "contains", json!(t)),
                    ],
                });
                understood.push(format!("excluding \"{t}\" in genre, title or artist"));
                negate_next = false;
            } else {
                words.push(t.to_string());
            }
        }
        i += 1;
    }

    // Leading words that match a genre in the library become a genre rule.
    let genres = library::facet(conn, "genre", 500)?;
    let mut free: Vec<String> = Vec::new();
    let mut gi = 0;
    while gi < words.len() {
        let mut matched = false;
        for len in (1..=3).rev() {
            if gi + len > words.len() {
                continue;
            }
            let phrase = words[gi..gi + len].join(" ");
            let alt = phrase.replace(' ', "");
            if let Some((g, _)) = genres.iter().find(|(g, _)| {
                let fg = fold(g);
                fg == phrase || fg.replace([' ', '-'], "") == alt
            }) {
                rules.push(cond("genre", "equals", json!(g)));
                understood.push(format!("genre \"{g}\""));
                gi += len;
                matched = true;
                break;
            }
        }
        if !matched {
            free.push(words[gi].clone());
            gi += 1;
        }
    }
    let text = if free.is_empty() {
        None
    } else {
        Some(free.join(" "))
    };
    if let Some(t) = &text {
        understood.push(format!(
            "text \"{t}\" anywhere in title, artist, album, genre, label, file name or tags"
        ));
    }
    let filters = RuleSet {
        match_mode: MatchMode::All,
        rules,
        exclude,
    };
    let q = TrackQuery {
        text: text.clone(),
        filters: Some(filters.clone()),
        limit: Some(8),
        ..Default::default()
    };
    let page = library::search(conn, &q)?;
    let reply = if understood.is_empty() {
        "I didn't recognise any filters in that. Type \"help\" to see what I understand."
            .to_string()
    } else if page.total == 0 {
        "No tracks match. Unknown values (for example energy you haven't rated yet) never count as a match.".to_string()
    } else {
        format!(
            "Found {} track{}. I've applied these filters to the library view.",
            page.total,
            if page.total == 1 { "" } else { "s" }
        )
    };
    Ok(AssistantReply {
        reply,
        understood,
        action: "search".into(),
        target: None,
        text,
        filters: Some(filters),
        total: Some(page.total),
        sample: page.rows,
        params: None,
    })
}
