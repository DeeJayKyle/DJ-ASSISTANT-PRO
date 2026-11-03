//! Virtual crates stored only in the app catalogue. A track can be in any
//! number of crates; files are never copied or moved.
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use crate::library::{self, TrackQuery};
use crate::rules::{self, RuleSet};
use rusqlite::types::Value;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct Crate {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub color: Option<String>,
    pub category: Option<String>,
    pub parent_id: Option<i64>,
    pub sort_order: i64,
    pub rules: Option<RuleSet>,
    pub track_count: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CrateInput {
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub parent_id: Option<i64>,
    #[serde(default)]
    pub rules: Option<RuleSet>,
}

fn validate(conn: &Connection, input: &CrateInput) -> Result<String> {
    let name = input.name.trim().to_string();
    if name.is_empty() {
        return invalid("crate name is required");
    }
    if name.chars().count() > 120 {
        return invalid("crate name is too long (max 120 characters)");
    }
    if input.kind != "manual" && input.kind != "smart" {
        return invalid("crate type must be manual or smart");
    }
    if let Some(c) = &input.color {
        if !library::COLORS.contains(&c.as_str()) {
            return invalid("unknown colour");
        }
    }
    if input.kind == "smart" {
        let rs = input
            .rules
            .as_ref()
            .ok_or_else(|| Error::Invalid("smart crates need at least one rule".into()))?;
        if rs.rules.is_empty() {
            return invalid("smart crates need at least one rule");
        }
        // Compile once to validate fields, operators and values.
        rules::compile(rs, db::low_bitrate_threshold(conn)?, 0)?;
    }
    Ok(name)
}

pub fn create(conn: &Connection, input: &CrateInput) -> Result<Crate> {
    let name = validate(conn, input)?;
    let now = now_ms();
    let rules_json = if input.kind == "smart" {
        input
            .rules
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?
    } else {
        None
    };
    let order: i64 = conn.query_row(
        "SELECT COALESCE(MAX(sort_order),0)+1 FROM crates",
        [],
        |r| r.get(0),
    )?;
    conn.execute(
        "INSERT INTO crates(name, kind, color, category, parent_id, sort_order, rules_json, created_at, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?8)",
        params![name, input.kind, input.color, input.category.as_deref().map(str::trim).filter(|s| !s.is_empty()), input.parent_id, order, rules_json, now],
    )?;
    get(conn, conn.last_insert_rowid())
}

pub fn update(conn: &Connection, id: i64, input: &CrateInput) -> Result<Crate> {
    let existing = get(conn, id)?;
    if existing.kind != input.kind {
        return invalid("a crate's type cannot be changed; create a new crate instead");
    }
    let name = validate(conn, input)?;
    if input.parent_id == Some(id) {
        return invalid("a crate cannot be inside itself");
    }
    let rules_json = if input.kind == "smart" {
        input
            .rules
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?
    } else {
        None
    };
    conn.execute(
        "UPDATE crates SET name=?1, color=?2, category=?3, parent_id=?4, rules_json=?5, updated_at=?6 WHERE id=?7",
        params![name, input.color, input.category.as_deref().map(str::trim).filter(|s| !s.is_empty()), input.parent_id, rules_json, now_ms(), id],
    )?;
    get(conn, id)
}

pub fn delete(conn: &Connection, id: i64) -> Result<()> {
    let n = conn.execute("DELETE FROM crates WHERE id=?1", params![id])?;
    if n == 0 {
        return Err(Error::NotFound("crate".into()));
    }
    Ok(())
}

fn read_row(r: &rusqlite::Row) -> rusqlite::Result<Crate> {
    let rules_json: Option<String> = r.get(7)?;
    Ok(Crate {
        id: r.get(0)?,
        name: r.get(1)?,
        kind: r.get(2)?,
        color: r.get(3)?,
        category: r.get(4)?,
        parent_id: r.get(5)?,
        sort_order: r.get(6)?,
        rules: rules_json.and_then(|j| serde_json::from_str(&j).ok()),
        track_count: 0,
        created_at: r.get(8)?,
        updated_at: r.get(9)?,
    })
}

pub fn get(conn: &Connection, id: i64) -> Result<Crate> {
    let mut c = conn
        .query_row(
            "SELECT id, name, kind, color, category, parent_id, sort_order, rules_json, created_at, updated_at FROM crates WHERE id=?1",
            params![id],
            read_row,
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("crate".into()))?;
    c.track_count = count(conn, id)?;
    Ok(c)
}

pub fn list(conn: &Connection) -> Result<Vec<Crate>> {
    let mut stmt = conn.prepare("SELECT id, name, kind, color, category, parent_id, sort_order, rules_json, created_at, updated_at FROM crates ORDER BY sort_order, name")?;
    let mut v = stmt
        .query_map([], read_row)?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    for c in v.iter_mut() {
        c.track_count = count(conn, c.id).unwrap_or(0);
    }
    Ok(v)
}

fn count(conn: &Connection, id: i64) -> Result<i64> {
    let q = TrackQuery {
        crate_id: Some(id),
        limit: Some(1),
        ..Default::default()
    };
    let (w, params) = library::where_clause(conn, &q)?;
    Ok(conn.query_row(
        &format!("SELECT COUNT(*) FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN library_roots r ON r.id=t.root_id WHERE {w}"),
        rusqlite::params_from_iter(params.iter()),
        |r| r.get(0),
    )?)
}

/// SQL fragment selecting the members of a crate. Smart crates: rules OR
/// manual additions, minus manual exclusions.
pub fn membership_sql(
    conn: &Connection,
    crate_id: i64,
    low: u32,
    offset: usize,
) -> Result<(String, Vec<Value>)> {
    let (kind, rules_json): (String, Option<String>) = conn
        .query_row(
            "SELECT kind, rules_json FROM crates WHERE id=?1",
            params![crate_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| Error::NotFound("crate".into()))?;
    let mut params = vec![Value::Integer(crate_id)];
    let pid = offset + 1;
    let inc = format!(
        "t.id IN (SELECT track_id FROM crate_tracks WHERE crate_id=?{pid} AND mode='include')"
    );
    if kind == "manual" {
        return Ok((inc, params));
    }
    let rs: RuleSet = rules_json
        .as_deref()
        .map(serde_json::from_str)
        .transpose()?
        .unwrap_or_default();
    let c = rules::compile(&rs, low, offset + 1)?;
    params.extend(c.params);
    Ok((
        format!("(({}) OR {inc}) AND t.id NOT IN (SELECT track_id FROM crate_tracks WHERE crate_id=?{pid} AND mode='exclude')", c.sql),
        params,
    ))
}

/// Add tracks to a crate. For smart crates this records a manual inclusion.
pub fn add_tracks(conn: &Connection, crate_id: i64, ids: &[i64]) -> Result<usize> {
    get(conn, crate_id)?;
    let tx = conn.unchecked_transaction()?;
    let now = now_ms();
    let mut n = 0;
    {
        let mut pos: i64 = tx.query_row(
            "SELECT COALESCE(MAX(position),0) FROM crate_tracks WHERE crate_id=?1",
            params![crate_id],
            |r| r.get(0),
        )?;
        let mut st = tx.prepare_cached(
            "INSERT INTO crate_tracks(crate_id, track_id, mode, position, added_at) SELECT ?1, id, 'include', ?3, ?4 FROM tracks WHERE id=?2
             ON CONFLICT(crate_id, track_id) DO UPDATE SET mode='include'",
        )?;
        for id in ids {
            pos += 1;
            n += st.execute(params![crate_id, id, pos, now])?;
        }
    }
    tx.commit()?;
    Ok(n)
}

/// Remove tracks from a crate. For smart crates this records an exclusion
/// so the rule does not bring them back.
pub fn remove_tracks(conn: &Connection, crate_id: i64, ids: &[i64]) -> Result<usize> {
    let c = get(conn, crate_id)?;
    let tx = conn.unchecked_transaction()?;
    let mut n = 0;
    {
        if c.kind == "manual" {
            let mut st =
                tx.prepare_cached("DELETE FROM crate_tracks WHERE crate_id=?1 AND track_id=?2")?;
            for id in ids {
                n += st.execute(params![crate_id, id])?;
            }
        } else {
            let mut st = tx.prepare_cached(
                "INSERT INTO crate_tracks(crate_id, track_id, mode, added_at) SELECT ?1, id, 'exclude', ?3 FROM tracks WHERE id=?2
                 ON CONFLICT(crate_id, track_id) DO UPDATE SET mode='exclude'",
            )?;
            let now = now_ms();
            for id in ids {
                n += st.execute(params![crate_id, id, now])?;
            }
        }
    }
    tx.commit()?;
    Ok(n)
}

#[derive(Debug, Clone, Serialize)]
pub struct RulePreview {
    pub total: i64,
    pub sample: Vec<library::TrackRow>,
}

/// Preview what a rule set would match before saving it.
pub fn preview_rules(conn: &Connection, rs: &RuleSet, limit: i64) -> Result<RulePreview> {
    let q = TrackQuery {
        filters: Some(rs.clone()),
        limit: Some(limit.clamp(1, 200)),
        ..Default::default()
    };
    let page = library::search(conn, &q)?;
    Ok(RulePreview {
        total: page.total,
        sample: page.rows,
    })
}

pub fn fields() -> &'static [rules::FieldInfo] {
    rules::FIELD_LIST
}
