//! Gig mode: an offline-first session with a set list, a request queue,
//! DJ notes and a play log, followed by a recap. While a gig is running,
//! nonessential background work is paused.
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashMap;

pub fn current(conn: &Connection) -> Result<Option<Value>> {
    let g: Option<(i64, String, Option<i64>, i64)> = conn
        .query_row("SELECT id, name, set_plan_id, started_at FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .optional()?;
    let Some((id, name, plan, started)) = g else {
        return Ok(None);
    };
    Ok(Some(
        json!({"id": id, "name": name, "set_plan_id": plan, "started_at": started, "events": events(conn, id)?}),
    ))
}

pub fn start(conn: &Connection, name: &str, set_plan_id: Option<i64>) -> Result<i64> {
    if current(conn)?.is_some() {
        return invalid("a gig is already running; end it first");
    }
    let name = if name.trim().is_empty() {
        "Gig".to_string()
    } else {
        name.trim().chars().take(120).collect()
    };
    conn.execute(
        "INSERT INTO gigs(name, set_plan_id, started_at) VALUES (?1,?2,?3)",
        params![name, set_plan_id, now_ms()],
    )?;
    // Read the new gig's id before anything else inserts a row.
    let id = conn.last_insert_rowid();
    db::set_setting(conn, "gig_mode", "1")?;
    Ok(id)
}

pub fn end(conn: &Connection) -> Result<Option<i64>> {
    let id: Option<i64> = conn
        .query_row(
            "SELECT id FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = id {
        conn.execute(
            "UPDATE gigs SET ended_at=?2 WHERE id=?1",
            params![id, now_ms()],
        )?;
    }
    db::set_setting(conn, "gig_mode", "0")?;
    Ok(id)
}

pub fn active(conn: &Connection) -> Result<bool> {
    Ok(db::get_setting(conn, "gig_mode")?
        .map(|v| v == "1")
        .unwrap_or(false))
}

pub fn add_event(
    conn: &Connection,
    kind: &str,
    track_id: Option<i64>,
    text: Option<&str>,
) -> Result<i64> {
    if !["played", "request", "note"].contains(&kind) {
        return invalid("unknown event");
    }
    let gid: i64 = conn
        .query_row(
            "SELECT id FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()?
        .ok_or_else(|| Error::Invalid("start a gig first".into()))?;
    let text = text
        .map(|t| t.trim().chars().take(2000).collect::<String>())
        .filter(|t| !t.is_empty());
    if kind != "played" && text.is_none() && track_id.is_none() {
        return invalid("write something first");
    }
    let status = if kind == "request" {
        Some("pending")
    } else {
        None
    };
    conn.execute("INSERT INTO gig_events(gig_id, kind, track_id, text, status, at) VALUES (?1,?2,?3,?4,?5,?6)", params![gid, kind, track_id, text, status, now_ms()])?;
    Ok(conn.last_insert_rowid())
}

pub fn set_request(conn: &Connection, id: i64, status: &str, track_id: Option<i64>) -> Result<()> {
    if !["pending", "played", "declined", "queued"].contains(&status) {
        return invalid("bad status");
    }
    conn.execute("UPDATE gig_events SET status=?2, track_id=COALESCE(?3, track_id) WHERE id=?1 AND kind='request'", params![id, status, track_id])?;
    if status == "played" {
        if let Some(t) = track_id.or_else(|| {
            conn.query_row(
                "SELECT track_id FROM gig_events WHERE id=?1",
                params![id],
                |r| r.get(0),
            )
            .ok()
            .flatten()
        }) {
            add_event(conn, "played", Some(t), Some("Request"))?;
        }
    }
    Ok(())
}

pub fn delete_event(conn: &Connection, id: i64) -> Result<()> {
    conn.execute("DELETE FROM gig_events WHERE id=?1", params![id])?;
    Ok(())
}

fn events(conn: &Connection, gig: i64) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare(
        "SELECT e.id, e.kind, e.track_id, e.text, e.status, e.at, COALESCE(COALESCE(u.artist,t.artist) || ' — ', '') || COALESCE(u.title,t.title,t.file_name)
         FROM gig_events e LEFT JOIN tracks t ON t.id=e.track_id LEFT JOIN track_user u ON u.track_id=t.id WHERE e.gig_id=?1 ORDER BY e.at, e.id",
    )?;
    let v = stmt
        .query_map(params![gig], |r| {
            Ok(json!({"id": r.get::<_, i64>(0)?, "kind": r.get::<_, String>(1)?, "track_id": r.get::<_, Option<i64>>(2)?, "text": r.get::<_, Option<String>>(3)?,
                "status": r.get::<_, Option<String>>(4)?, "at": r.get::<_, i64>(5)?, "track": r.get::<_, Option<String>>(6)?}))
        })?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

pub fn list(conn: &Connection) -> Result<Vec<Value>> {
    let mut stmt = conn.prepare(
        "SELECT g.id, g.name, g.started_at, g.ended_at, (SELECT COUNT(*) FROM gig_events e WHERE e.gig_id=g.id AND e.kind='played') FROM gigs g ORDER BY g.id DESC LIMIT 100",
    )?;
    let v = stmt
        .query_map([], |r| Ok(json!({"id": r.get::<_, i64>(0)?, "name": r.get::<_, String>(1)?, "started_at": r.get::<_, i64>(2)?, "ended_at": r.get::<_, Option<i64>>(3)?, "played": r.get::<_, i64>(4)?})))?
        .collect::<std::result::Result<_, _>>()?;
    Ok(v)
}

/// Post-gig recap: what was played, how energy and genres moved, requests.
pub fn recap(conn: &Connection, id: i64) -> Result<Value> {
    let (name, started, ended): (String, i64, Option<i64>) = conn
        .query_row(
            "SELECT name, started_at, ended_at FROM gigs WHERE id=?1",
            params![id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("gig".into()))?;
    let evs = events(conn, id)?;
    let played: Vec<&Value> = evs.iter().filter(|e| e["kind"] == "played").collect();
    let mut genres: HashMap<String, i64> = HashMap::new();
    let mut energy = vec![];
    for e in &played {
        if let Some(tid) = e["track_id"].as_i64() {
            let (g, en): (Option<String>, Option<i64>) = conn
                .query_row(
                    "SELECT COALESCE(u.genre,t.genre), COALESCE(u.energy,a.energy) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?1",
                    params![tid],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap_or((None, None));
            *genres
                .entry(g.unwrap_or_else(|| "Unknown".into()))
                .or_default() += 1;
            energy.push(json!({"at": e["at"], "energy": en}));
        }
    }
    let requests: Vec<&Value> = evs.iter().filter(|e| e["kind"] == "request").collect();
    let fulfilled = requests.iter().filter(|r| r["status"] == "played").count();
    let notes: Vec<&Value> = evs.iter().filter(|e| e["kind"] == "note").collect();
    let end = ended.unwrap_or_else(now_ms);
    let mut g: Vec<(String, i64)> = genres.into_iter().collect();
    g.sort_by_key(|x| -x.1);
    Ok(json!({
        "id": id, "name": name, "started_at": started, "ended_at": ended, "duration_ms": end - started,
        "played": played, "played_count": played.len(), "genres": g.iter().map(|(k, v)| json!({"genre": k, "count": v})).collect::<Vec<_>>(),
        "energy": energy, "requests": requests, "requests_total": requests.len(), "requests_fulfilled": fulfilled, "notes": notes
    }))
}

pub fn recap_markdown(conn: &Connection, id: i64) -> Result<String> {
    let r = recap(conn, id)?;
    let mut s = format!("# {}\n\n", r["name"].as_str().unwrap_or("Gig"));
    s.push_str(&format!(
        "- Duration: {} min\n- Tracks played: {}\n- Requests: {} ({} played)\n\n## Played\n\n",
        r["duration_ms"].as_i64().unwrap_or(0) / 60000,
        r["played_count"],
        r["requests_total"],
        r["requests_fulfilled"]
    ));
    for (i, p) in r["played"].as_array().into_iter().flatten().enumerate() {
        s.push_str(&format!(
            "{}. {}\n",
            i + 1,
            p["track"].as_str().unwrap_or("(unknown)")
        ));
    }
    s.push_str("\n## Genres\n\n");
    for g in r["genres"].as_array().into_iter().flatten() {
        s.push_str(&format!(
            "- {}: {}\n",
            g["genre"].as_str().unwrap_or(""),
            g["count"]
        ));
    }
    if let Some(n) = r["notes"].as_array().filter(|a| !a.is_empty()) {
        s.push_str("\n## Notes\n\n");
        for x in n {
            s.push_str(&format!("- {}\n", x["text"].as_str().unwrap_or("")));
        }
    }
    Ok(s)
}
