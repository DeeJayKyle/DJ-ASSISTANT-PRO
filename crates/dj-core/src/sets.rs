//! Set Studio: builds an editable running order from the library for an
//! event, duration and energy journey. Every pick and transition comes with
//! its reasons. Plans are suggestions, never guaranteed to mix well.
use crate::analysis::camelot_compatible;
use crate::db::now_ms;
use crate::error::{invalid, Error, Result};
use crate::profile::{self, bpm_distance, Tp};
use crate::text::{base_artist, fold};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct SetParams {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub event_type: Option<String>,
    #[serde(default)]
    pub audience: Option<String>,
    pub duration_min: u32,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub must_play: Vec<i64>,
    #[serde(default)]
    pub exclude: Vec<i64>,
    #[serde(default)]
    pub exclude_tags: Vec<String>,
    #[serde(default)]
    pub clean_only: bool,
    /// One of: warmup, peak, journey, wedding, lounge, custom
    #[serde(default)]
    pub curve: Option<String>,
    /// Custom curve points (energy 1-10) spread evenly across the set.
    #[serde(default)]
    pub custom_curve: Vec<f64>,
    #[serde(default)]
    pub bpm_min: Option<f64>,
    #[serde(default)]
    pub bpm_max: Option<f64>,
    #[serde(default)]
    pub crate_id: Option<i64>,
    #[serde(default)]
    pub harmonic: Option<bool>,
    /// Skip tracks shorter than this (jingles, drops). Default 30 s.
    #[serde(default)]
    pub min_track_seconds: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Slot {
    pub track_id: i64,
    pub track: String,
    pub start_ms: i64,
    pub target_energy: f64,
    pub energy: Option<i64>,
    pub bpm: Option<f64>,
    pub key: Option<String>,
    pub must_play: bool,
    pub reasons: Vec<String>,
    pub transition: Vec<String>,
    pub alternatives: Vec<Value>,
}

pub fn curve_points(p: &SetParams) -> Vec<f64> {
    match p.curve.as_deref().unwrap_or("journey") {
        "warmup" => vec![3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0],
        "peak" => vec![7.0, 8.0, 8.5, 9.0, 9.0, 9.5, 8.5],
        "wedding" => vec![4.0, 5.0, 6.0, 7.5, 8.5, 9.0, 8.0, 6.0],
        "lounge" => vec![3.0, 3.5, 4.0, 4.0, 4.5, 4.0, 3.5],
        "custom" if p.custom_curve.len() >= 2 => {
            p.custom_curve.iter().map(|v| v.clamp(1.0, 10.0)).collect()
        }
        _ => vec![4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 8.5, 6.5],
    }
}

fn target_at(points: &[f64], t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0) * (points.len() - 1) as f64;
    let i = t.floor() as usize;
    let j = (i + 1).min(points.len() - 1);
    points[i] + (points[j] - points[i]) * (t - i as f64)
}

fn transition_notes(a: &Tp, b: &Tp) -> (f64, Vec<String>) {
    let mut s = 0.0;
    let mut notes = vec![];
    match (a.bpm, b.bpm) {
        (Some(x), Some(y)) => {
            let d = bpm_distance(y, x);
            if d <= 0.03 {
                s += 2.0;
                notes.push(format!(
                    "BPM {x:.0} → {y:.0} ({:+.1}%)",
                    (y - x) / x * 100.0
                ));
            } else if d <= 0.06 {
                s += 1.0;
                notes.push(format!(
                    "BPM {x:.0} → {y:.0} (needs a {:.0}% pitch change)",
                    d * 100.0
                ));
            } else {
                s -= 3.0;
                notes.push(format!(
                    "BPM jump {x:.0} → {y:.0}: plan a cut, echo-out or bridge track"
                ));
            }
        }
        _ => notes.push("BPM unknown for one of the tracks".into()),
    }
    match (&a.key, &b.key) {
        (Some(x), Some(y)) => match camelot_compatible(x, y) {
            Some(why) => {
                s += 1.5;
                notes.push(format!("Key {x} → {y} ({why})"));
            }
            None => notes.push(format!("Key {x} → {y} is not a standard harmonic move")),
        },
        _ => notes.push("Key unknown for one of the tracks".into()),
    }
    (s, notes)
}

fn eligible(
    t: &Tp,
    p: &SetParams,
    excluded: &HashSet<i64>,
    allowed: &Option<HashSet<i64>>,
) -> bool {
    if excluded.contains(&t.id)
        || t.duration_ms.unwrap_or(0) < p.min_track_seconds.unwrap_or(30) as i64 * 1000
    {
        return false;
    }
    if let Some(a) = allowed {
        if !a.contains(&t.id) && !p.must_play.contains(&t.id) {
            return false;
        }
    }
    if p.clean_only && t.clean.as_deref() != Some("clean") {
        // explicit or unknown tracks are left out when a clean set is requested
        return false;
    }
    if p.exclude_tags.iter().any(|x| t.tags.contains(&fold(x))) {
        return false;
    }
    if !p.genres.is_empty() && !p.must_play.contains(&t.id) {
        let g = t.genre_fold();
        if !p
            .genres
            .iter()
            .any(|w| !g.is_empty() && g.contains(&fold(w)))
        {
            return false;
        }
    }
    if let Some(b) = t.bpm {
        if p.bpm_min.map(|m| b < m && b * 2.0 < m).unwrap_or(false)
            || p.bpm_max.map(|m| b > m && b / 2.0 > m).unwrap_or(false)
        {
            return false;
        }
    }
    true
}

pub fn plan(conn: &Connection, p: &SetParams) -> Result<Value> {
    if !(5..=720).contains(&p.duration_min) {
        return invalid("set length must be between 5 minutes and 12 hours");
    }
    let tps = profile::load(conn)?;
    let excluded: HashSet<i64> = p.exclude.iter().copied().collect();
    let allowed: Option<HashSet<i64>> = match p.crate_id {
        Some(cid) => Some(
            crate::library::track_ids(
                conn,
                &crate::library::TrackQuery {
                    crate_id: Some(cid),
                    ..Default::default()
                },
                100_000,
            )?
            .into_iter()
            .collect(),
        ),
        None => None,
    };
    let pool: Vec<&Tp> = tps
        .iter()
        .filter(|t| eligible(t, p, &excluded, &allowed))
        .collect();
    let mut warnings = vec![];
    if pool.is_empty() {
        return invalid("no tracks match these settings. Try fewer genre filters, turn off clean-only, or add energy/BPM data by analysing tracks.");
    }
    let unknown_energy = pool.iter().filter(|t| t.energy.is_none()).count();
    if unknown_energy * 2 > pool.len() {
        warnings.push(format!("{unknown_energy} of {} candidate tracks have no energy value yet; analyse them or rate energy for better journeys.", pool.len()));
    }
    let points = curve_points(p);
    let total_ms = p.duration_min as i64 * 60_000;
    let harmonic = p.harmonic.unwrap_or(true);
    let mut used: HashSet<i64> = HashSet::new();
    let mut slots: Vec<Slot> = vec![];
    let mut elapsed = 0i64;
    let mut must: Vec<&Tp> = p
        .must_play
        .iter()
        .filter_map(|id| tps.iter().find(|t| t.id == *id))
        .collect();
    for id in &p.must_play {
        if !tps.iter().any(|t| t.id == *id) {
            warnings.push(format!(
                "Must-play track #{id} is not available (missing, offline or unreadable)."
            ));
        }
    }
    // Typical mixed length: ~70% of the full track, at least 2:30.
    let played_len =
        |t: &Tp| ((t.duration_ms.unwrap_or(240_000) as f64 * 0.7) as i64).clamp(150_000, 420_000);

    while elapsed < total_ms {
        let t = elapsed as f64 / total_ms as f64;
        let target = target_at(&points, t);
        let prev = slots
            .last()
            .and_then(|s| tps.iter().find(|x| x.id == s.track_id));
        let recent_artists: Vec<String> = slots
            .iter()
            .rev()
            .take(4)
            .filter_map(|s| tps.iter().find(|x| x.id == s.track_id))
            .map(|x| base_artist(&x.artist))
            .collect();
        let remaining_ms = total_ms - elapsed;
        let must_left: i64 = must.iter().map(|m| played_len(m)).sum();
        let mut scored: Vec<(f64, &Tp, Vec<String>, Vec<String>)> = vec![];
        for c in pool.iter().copied().chain(must.iter().copied()) {
            if used.contains(&c.id) {
                continue;
            }
            let is_must = must.iter().any(|m| m.id == c.id);
            let mut s = 0.0;
            let mut why = vec![];
            let e = c.energy.unwrap_or(5) as f64;
            let de = (e - target).abs();
            s += 3.0 - de;
            if let Some(en) = c.energy {
                why.push(format!("Energy {en} for a target of {target:.1}"));
            } else {
                s -= 0.7;
            }
            if let Some(r) = c.rating {
                s += (r as f64 - 3.0) * 0.4;
                if r >= 4 {
                    why.push(format!("Rated {r}★"));
                }
            }
            s -= c.plays.min(10) as f64 * 0.05;
            if recent_artists.contains(&base_artist(&c.artist)) {
                s -= 2.5;
            }
            let mut trans = vec![];
            if let Some(pv) = prev {
                let (ts, notes) = transition_notes(pv, c);
                s += if harmonic { ts } else { ts.min(2.0) };
                trans = notes;
                if pv.genre_fold() == c.genre_fold() && c.genre.is_some() {
                    s += 0.5;
                }
            }
            if is_must {
                s += 1.5;
                why.insert(0, "Must-play".into());
                // make sure every must-play fits before the end
                if must_left >= remaining_ms - played_len(c) {
                    s += 20.0;
                }
            }
            scored.push((s, c, why, trans));
        }
        if scored.is_empty() {
            warnings
                .push("Ran out of suitable tracks before reaching the requested length.".into());
            break;
        }
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let (_, pick, why, trans) = scored[0].clone();
        let alternatives: Vec<Value> = scored
            .iter()
            .skip(1)
            .filter(|x| !must.iter().any(|m| m.id == x.1.id))
            .take(3)
            .map(|(s, a, w, _)| json!({"track_id": a.id, "track": a.label(), "energy": a.energy, "bpm": a.bpm, "key": a.key, "score": (s * 10.0).round() / 10.0, "reasons": w}))
            .collect();
        used.insert(pick.id);
        must.retain(|m| m.id != pick.id);
        slots.push(Slot {
            track_id: pick.id,
            track: pick.label(),
            start_ms: elapsed,
            target_energy: (target * 10.0).round() / 10.0,
            energy: pick.energy,
            bpm: pick.bpm,
            key: pick.key.clone(),
            must_play: p.must_play.contains(&pick.id),
            reasons: why,
            transition: trans,
            alternatives,
        });
        elapsed += played_len(pick);
        if slots.len() > 400 {
            break;
        }
    }
    // Emergency tracks: dependable floor-fillers not in the plan.
    let mut emergency: Vec<&Tp> = pool
        .iter()
        .copied()
        .filter(|t| {
            !used.contains(&t.id)
                && (t.rating.unwrap_or(0) >= 4 || t.tags.iter().any(|g| g == "banger"))
        })
        .collect();
    emergency.sort_by_key(|t| std::cmp::Reverse((t.rating.unwrap_or(0), t.energy.unwrap_or(0))));
    let emergency: Vec<Value> = emergency.iter().take(8).map(|t| json!({"track_id": t.id, "track": t.label(), "rating": t.rating, "energy": t.energy, "bpm": t.bpm})).collect();
    let rough = slots
        .iter()
        .filter(|s| s.transition.iter().any(|n| n.starts_with("BPM jump")))
        .count();
    if rough > 0 {
        warnings.push(format!("{rough} transition(s) have a large tempo jump; consider bridge tracks or a creative cut."));
    }
    Ok(json!({
        "params": p,
        "curve": points,
        "slots": slots,
        "emergency": emergency,
        "warnings": warnings,
        "planned_ms": elapsed,
        "note": "This is a suggested running order. Tempo and key notes describe compatibility on paper only; always trust your ears."
    }))
}

pub fn save(conn: &Connection, id: Option<i64>, name: &str, plan: &Value) -> Result<i64> {
    let name = name.trim();
    if name.is_empty() || name.len() > 120 {
        return invalid("give the set a name");
    }
    let params_json = plan.get("params").cloned().unwrap_or(json!({})).to_string();
    let slots = plan.get("slots").cloned().unwrap_or(json!([]));
    let arr = slots
        .as_array()
        .ok_or_else(|| Error::Invalid("slots must be a list".into()))?;
    for s in arr {
        let tid = s
            .get("track_id")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| Error::Invalid("each slot needs a track".into()))?;
        let ok: Option<i64> = conn
            .query_row("SELECT id FROM tracks WHERE id=?1", params![tid], |r| {
                r.get(0)
            })
            .optional()?;
        if ok.is_none() {
            return invalid(format!("track #{tid} is not in the library"));
        }
    }
    let full = json!({"slots": slots, "emergency": plan.get("emergency").cloned().unwrap_or(json!([])), "curve": plan.get("curve").cloned().unwrap_or(json!([]))}).to_string();
    let now = now_ms();
    match id {
        Some(id) => {
            conn.execute("UPDATE set_plans SET name=?2, params_json=?3, slots_json=?4, updated_at=?5 WHERE id=?1", params![id, name, params_json, full, now])?;
            Ok(id)
        }
        None => {
            conn.execute("INSERT INTO set_plans(name, params_json, slots_json, created_at, updated_at) VALUES (?1,?2,?3,?4,?4)", params![name, params_json, full, now])?;
            Ok(conn.last_insert_rowid())
        }
    }
}

pub fn list(conn: &Connection) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare("SELECT id, name, params_json, slots_json, created_at, updated_at FROM set_plans ORDER BY updated_at DESC")?;
    let v = stmt
        .query_map([], |r| {
            let slots: Value = serde_json::from_str(&r.get::<_, String>(3)?).unwrap_or(json!({}));
            Ok(json!({"id": r.get::<_, i64>(0)?, "name": r.get::<_, String>(1)?, "params": serde_json::from_str::<Value>(&r.get::<_, String>(2)?).unwrap_or(json!({})),
                "count": slots["slots"].as_array().map(|a| a.len()).unwrap_or(0), "created_at": r.get::<_, i64>(4)?, "updated_at": r.get::<_, i64>(5)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn get(conn: &Connection, id: i64) -> Result<Value> {
    let (name, params_json, slots_json): (String, String, String) = conn
        .query_row(
            "SELECT name, params_json, slots_json FROM set_plans WHERE id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("set".into()))?;
    let mut v: Value = serde_json::from_str(&slots_json)?;
    v["id"] = json!(id);
    v["name"] = json!(name);
    v["params"] = serde_json::from_str(&params_json)?;
    Ok(v)
}

pub fn delete(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("DELETE FROM set_plans WHERE id=?1", params![id])?;
    Ok(())
}

pub fn track_ids(conn: &Connection, id: i64) -> Result<Vec<i64>> {
    let v = get(conn, id)?;
    Ok(v["slots"]
        .as_array()
        .map(|a| a.iter().filter_map(|s| s["track_id"].as_i64()).collect())
        .unwrap_or_default())
}

/// Re-evaluate transitions after the DJ reorders or swaps tracks.
pub fn review(conn: &Connection, ids: &[i64]) -> Result<Vec<Value>> {
    let tps = profile::load(conn)?;
    let get = |id: i64| tps.iter().find(|t| t.id == id);
    let mut out = vec![];
    for w in ids.windows(2) {
        match (get(w[0]), get(w[1])) {
            (Some(a), Some(b)) => {
                let (score, notes) = transition_notes(a, b);
                out.push(json!({"from": a.id, "to": b.id, "score": score, "notes": notes}));
            }
            _ => out.push(
                json!({"from": w[0], "to": w[1], "score": 0, "notes": ["Track unavailable"]}),
            ),
        }
    }
    Ok(out)
}
