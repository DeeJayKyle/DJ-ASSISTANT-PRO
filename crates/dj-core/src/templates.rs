//! Crate templates, labels and crate hygiene, following the
//! "Crate & Playlist Cheat Sheet": organise by genre, sort by energy, utility
//! crates, event crates, ratings, colour tags and an example folder structure.
use crate::crates::{self, CrateInput};
use crate::db;
use crate::error::{invalid, Result};
use crate::rules::{MatchMode, RuleNode, RuleSet};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Value};

#[derive(Debug, Clone, Serialize)]
pub struct Template {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub crates: Vec<String>,
    pub needs_genre: bool,
}

fn c(field: &str, op: &str, value: Value) -> RuleNode {
    RuleNode::Condition {
        field: field.into(),
        op: op.into(),
        value,
    }
}
fn all(rules: Vec<RuleNode>) -> RuleSet {
    RuleSet {
        match_mode: MatchMode::All,
        rules,
        exclude: vec![],
    }
}

struct Spec {
    name: String,
    color: Option<&'static str>,
    rules: Option<RuleSet>,
}

fn spec(name: &str, color: Option<&'static str>, rules: Option<RuleSet>) -> Spec {
    Spec {
        name: name.into(),
        color,
        rules,
    }
}

const GENRES: &[&str] = &[
    "House",
    "Tech House",
    "Afro House",
    "Hip Hop",
    "R&B",
    "Pop",
    "Latin",
    "Afrobeats",
    "Amapiano",
    "Dancehall",
];
pub const EVENTS: &[&str] = &[
    "Club / Nightclub",
    "Festival",
    "Wedding",
    "Corporate",
    "Private Party",
    "Birthday",
    "Latin Night",
    "House Party",
    "Lounge / Chill",
];

fn energy_specs(extra: Option<RuleNode>) -> Vec<Spec> {
    let with = |lo: i64, hi: i64| {
        let mut r = vec![c("energy", "between", json!([lo, hi]))];
        if let Some(e) = &extra {
            r.insert(0, e.clone());
        }
        Some(all(r))
    };
    vec![
        spec("Peak Time (9–10)", Some("red"), with(9, 10)),
        spec("High Energy (7–8)", Some("orange"), with(7, 8)),
        spec("Mid Energy (5–6)", Some("yellow"), with(5, 6)),
        spec("Warm Up (3–4)", Some("green"), with(3, 4)),
        spec("Cool Down (1–2)", Some("blue"), with(1, 2)),
    ]
}

fn build(id: &str, genre: Option<&str>) -> Option<(String, Vec<Spec>)> {
    Some(match id {
        "genres" => (
            "Genres".into(),
            GENRES
                .iter()
                .map(|g| spec(g, None, Some(all(vec![c("genre", "contains", json!(g))]))))
                .chain([
                    spec(
                        "Throwbacks (pre-2010)",
                        Some("purple"),
                        Some(all(vec![c("year", "lt", json!(2010))])),
                    ),
                    spec("Open Format", None, None),
                ])
                .collect(),
        ),
        "energy" => ("Energy".into(), energy_specs(None)),
        "utility" => (
            "Utility".into(),
            vec![
                spec(
                    "Openers",
                    Some("green"),
                    Some(all(vec![c("tag", "has", json!("opener"))])),
                ),
                spec(
                    "Closers",
                    Some("blue"),
                    Some(all(vec![c("tag", "has", json!("closer"))])),
                ),
                spec(
                    "Bangers",
                    Some("red"),
                    Some(RuleSet {
                        match_mode: MatchMode::Any,
                        rules: vec![
                            c("tag", "has", json!("banger")),
                            c("rating", "eq", json!(5)),
                        ],
                        exclude: vec![],
                    }),
                ),
                spec(
                    "Vocals",
                    None,
                    Some(all(vec![c("tag", "has", json!("vocal"))])),
                ),
                spec(
                    "Acapellas",
                    Some("purple"),
                    Some(all(vec![c("version", "contains", json!("acapella"))])),
                ),
                spec(
                    "Instrumentals",
                    Some("purple"),
                    Some(all(vec![c("version", "contains", json!("instrumental"))])),
                ),
                spec(
                    "Edits",
                    None,
                    Some(all(vec![c("version", "contains", json!("edit"))])),
                ),
                spec(
                    "Mashups",
                    None,
                    Some(all(vec![c("version", "contains", json!("mashup"))])),
                ),
                spec(
                    "Transitions / FX",
                    None,
                    Some(all(vec![c("tag", "has", json!("transition"))])),
                ),
                spec(
                    "Clean Edits",
                    None,
                    Some(all(vec![c("clean_explicit", "equals", json!("clean"))])),
                ),
            ],
        ),
        "events" => (
            "Events".into(),
            EVENTS.iter().map(|e| spec(e, None, None)).collect(),
        ),
        "ratings" => (
            "Ratings".into(),
            vec![
                spec(
                    "★★★★★ Guaranteed",
                    Some("red"),
                    Some(all(vec![c("rating", "eq", json!(5))])),
                ),
                spec(
                    "★★★★ Reliable",
                    Some("orange"),
                    Some(all(vec![c("rating", "eq", json!(4))])),
                ),
                spec(
                    "★★★ Good",
                    Some("yellow"),
                    Some(all(vec![c("rating", "eq", json!(3))])),
                ),
                spec(
                    "★★ Rarely played",
                    Some("blue"),
                    Some(all(vec![c("rating", "eq", json!(2))])),
                ),
                spec(
                    "★ Archive",
                    Some("grey"),
                    Some(all(vec![c("rating", "eq", json!(1))])),
                ),
            ],
        ),
        "decades" => (
            "Decades".into(),
            [1970, 1980, 1990, 2000, 2010, 2020]
                .iter()
                .map(|d| {
                    spec(
                        &format!("{d}s"),
                        None,
                        Some(all(vec![c("decade", "eq", json!(d))])),
                    )
                })
                .collect(),
        ),
        "genre_by_energy" => {
            let g = genre?.trim();
            if g.is_empty() {
                return None;
            }
            let gr = c("genre", "contains", json!(g));
            let v = vec![
                spec(
                    "Warm Up",
                    Some("green"),
                    Some(all(vec![gr.clone(), c("energy", "between", json!([1, 4]))])),
                ),
                spec(
                    "Mid Energy",
                    Some("yellow"),
                    Some(all(vec![gr.clone(), c("energy", "between", json!([5, 6]))])),
                ),
                spec(
                    "Peak Time",
                    Some("red"),
                    Some(all(vec![
                        gr.clone(),
                        c("energy", "between", json!([7, 10])),
                    ])),
                ),
                spec(
                    "Closers",
                    Some("blue"),
                    Some(all(vec![gr.clone(), c("tag", "has", json!("closer"))])),
                ),
                spec(
                    "Tools",
                    Some("purple"),
                    Some(RuleSet {
                        match_mode: MatchMode::Any,
                        rules: vec![
                            c("tag", "has", json!("tool")),
                            c("version", "contains", json!("acapella")),
                            c("version", "contains", json!("instrumental")),
                        ],
                        exclude: vec![],
                    }),
                ),
            ];
            (g.to_string(), v)
        }
        _ => return None,
    })
}

pub fn list() -> Vec<Template> {
    let t = |id: &'static str, name: &'static str, description: &'static str, needs_genre: bool| {
        let crates = build(id, Some("House"))
            .map(|(_, v)| v.into_iter().map(|s| s.name).collect())
            .unwrap_or_default();
        Template {
            id,
            name,
            description,
            crates,
            needs_genre,
        }
    };
    vec![
        t("genres", "Organise by genre", "Main genre crates (smart: genre contains…), plus Throwbacks and Open Format.", false),
        t("energy", "Sort by energy", "Peak Time 9–10, High 7–8, Mid 5–6, Warm Up 3–4, Cool Down 1–2. Uses your energy, or the analysis estimate.", false),
        t("utility", "Utility crates", "Openers, Closers, Bangers, Vocals, Acapellas, Instrumentals, Edits, Mashups, Transitions/FX, Clean Edits.", false),
        t("events", "Event crates", "Club, Festival, Wedding, Corporate, Private Party, Birthday, Latin Night, House Party, Lounge/Chill (manual).", false),
        t("ratings", "Rate your tracks", "Guaranteed (5★), Reliable (4★), Good (3★), Rarely played (2★), Archive (1★).", false),
        t("decades", "Decades", "1970s through 2020s.", false),
        t("genre_by_energy", "Genre folder by energy", "Example folder structure: <Genre> → Warm Up, Mid Energy, Peak Time, Closers, Tools.", true),
    ]
}

/// Create a template's crates under a parent crate. Existing crates with the
/// same name under the same parent are left as they are.
pub fn apply(conn: &Connection, id: &str, genre: Option<&str>) -> Result<Value> {
    let Some((parent_name, specs)) = build(id, genre) else {
        return invalid("unknown template, or a genre is needed");
    };
    let find = |name: &str, parent: Option<i64>| -> Result<Option<i64>> {
        Ok(conn
            .query_row(
                "SELECT id FROM crates WHERE name=?1 AND parent_id IS ?2",
                params![name, parent],
                |r| r.get(0),
            )
            .optional()?)
    };
    let parent = match find(&parent_name, None)? {
        Some(p) => p,
        None => {
            crates::create(
                conn,
                &CrateInput {
                    name: parent_name.clone(),
                    kind: "manual".into(),
                    color: None,
                    category: None,
                    parent_id: None,
                    rules: None,
                },
            )?
            .id
        }
    };
    let (mut created, mut skipped) = (0, 0);
    for s in specs {
        if find(&s.name, Some(parent))?.is_some() {
            skipped += 1;
            continue;
        }
        let kind = if s.rules.is_some() { "smart" } else { "manual" };
        crates::create(
            conn,
            &CrateInput {
                name: s.name,
                kind: kind.into(),
                color: s.color.map(|c| c.into()),
                category: None,
                parent_id: Some(parent),
                rules: s.rules,
            },
        )?;
        created += 1;
    }
    Ok(json!({"parent_id": parent, "parent": parent_name, "created": created, "skipped": skipped}))
}

/// Labels for energy, rating and colour (defaults from the cheat sheet,
/// overridable in Settings).
pub fn labels(conn: &Connection) -> Result<Value> {
    let defaults = json!({
        "energy": [
            {"min": 9, "max": 10, "label": "Peak time", "hint": "High energy, main stage bangers"},
            {"min": 7, "max": 8, "label": "High energy", "hint": "Uplifting, driving and powerful"},
            {"min": 5, "max": 6, "label": "Mid energy", "hint": "Groove, vibe, steady moments"},
            {"min": 3, "max": 4, "label": "Warm up", "hint": "Build the vibe, early set"},
            {"min": 1, "max": 2, "label": "Cool down", "hint": "Chill, deep, end of night"}
        ],
        "rating": {"5": "Guaranteed", "4": "Reliable", "3": "Good", "2": "Rarely played", "1": "Archive"},
        "rating_hint": {"5": "Crowd reaction every time", "4": "Works in most sets", "3": "Solid tracks / fillers", "2": "Use situationally", "1": "Keep or delete"},
        "color": {"red": "Peak time", "orange": "High energy", "yellow": "Mid energy", "green": "Warm up", "blue": "Cool down", "purple": "Special / unique", "teal": "", "pink": "", "grey": ""},
        "tag_presets": ["Opener", "Closer", "Banger", "Vocal", "Instrumental", "Acapella", "Transition", "Tool", "Wedding", "Throwback", "Sing-along", "Long intro", "Short intro"]
    });
    let mut out = defaults;
    if let Some(over) =
        db::get_setting(conn, "labels_json")?.and_then(|s| serde_json::from_str::<Value>(&s).ok())
    {
        if let (Some(o), Some(d)) = (over.as_object(), out.as_object_mut()) {
            for (k, v) in o {
                d.insert(k.clone(), v.clone());
            }
        }
    }
    Ok(out)
}

pub fn set_labels(conn: &Connection, v: &Value) -> Result<()> {
    if !v.is_object() || v.to_string().len() > 20_000 {
        return invalid("labels must be an object");
    }
    db::set_setting(conn, "labels_json", &v.to_string())
}

/// Colour that matches an energy value according to the colour labels.
pub fn color_for_energy(e: i64) -> &'static str {
    match e {
        9..=10 => "red",
        7..=8 => "orange",
        5..=6 => "yellow",
        3..=4 => "green",
        _ => "blue",
    }
}

/// Set each track's colour from its (catalogue or estimated) energy.
pub fn colour_by_energy(conn: &Connection, only_uncoloured: bool) -> Result<usize> {
    let mut stmt = conn.prepare(
        "SELECT t.id, COALESCE(u.energy, a.energy) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id
         WHERE t.presence='present' AND COALESCE(u.energy, a.energy) IS NOT NULL AND (?1 = 0 OR u.color IS NULL)",
    )?;
    let rows: Vec<(i64, i64)> = stmt
        .query_map(params![only_uncoloured as i64], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
        .collect::<std::result::Result<_, _>>()?;
    let mut n = 0;
    for (id, e) in rows {
        let p = crate::library::UserFieldsPatch {
            color: Some(Some(color_for_energy(e).into())),
            ..Default::default()
        };
        n += crate::library::update_user_fields(conn, &[id], &p)?.min(1);
    }
    Ok(n)
}

/// "Avoid this" from the cheat sheet: vague crate names, huge unfiltered
/// crates, and tracks without tags or ratings.
pub fn hygiene(conn: &Connection) -> Result<Value> {
    let vague = [
        "new music",
        "random",
        "misc",
        "miscellaneous",
        "house stuff",
        "stuff",
        "untitled",
        "temp",
        "test",
    ];
    let mut issues = vec![];
    for c in crates::list(conn)? {
        let f = crate::text::fold(c.name.trim());
        if vague.contains(&f.as_str()) {
            issues.push(json!({"crate_id": c.id, "crate": c.name, "issue": "Vague name", "advice": "Unorganised crates mean missed moments. Rename it by genre, energy, event or role."}));
        }
        if c.kind == "manual" && c.track_count > 300 {
            issues.push(json!({"crate_id": c.id, "crate": c.name, "issue": format!("{} tracks", c.track_count), "advice": "Huge crates with hundreds of unfiltered tracks are hard to play from. Split it by energy or sub-genre."}));
        }
    }
    let untagged: i64 = conn.query_row(
        "SELECT COUNT(*) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok'
           AND u.rating IS NULL AND NOT EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id=t.id)",
        [],
        |r| r.get(0),
    )?;
    Ok(json!({"issues": issues, "untagged_unrated": untagged}))
}
