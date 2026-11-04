//! Rule engine shared by search filters and smart crates.
//!
//! Rules are plain data (JSON). They are compiled into SQL using a fixed
//! whitelist of fields and operators; every user-supplied value becomes a
//! bound parameter. User text can never become SQL.
use crate::error::{invalid, Result};
use crate::text::{fold, like_escape};
use rusqlite::types::Value;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchMode {
    All,
    Any,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RuleNode {
    Condition {
        field: String,
        op: String,
        #[serde(default)]
        value: serde_json::Value,
    },
    Group {
        #[serde(rename = "match")]
        match_mode: MatchMode,
        rules: Vec<RuleNode>,
    },
}

/// A complete rule set: `rules` combined with `match`, minus anything that
/// matches any of `exclude`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuleSet {
    #[serde(rename = "match")]
    pub match_mode: MatchMode,
    #[serde(default)]
    pub rules: Vec<RuleNode>,
    #[serde(default)]
    pub exclude: Vec<RuleNode>,
}

impl Default for RuleSet {
    fn default() -> Self {
        RuleSet {
            match_mode: MatchMode::All,
            rules: vec![],
            exclude: vec![],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FieldType {
    Text,
    Number,
    Tag,
    Bool,
    Enum,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct FieldInfo {
    pub id: &'static str,
    pub label: &'static str,
    #[serde(rename = "type")]
    pub kind: &'static str,
}

/// Field id -> (SQL expression, type). Expressions reference the fixed
/// aliases t (tracks), u (track_user) and r (library_roots).
fn field(id: &str, low_kbps: u32) -> Option<(String, FieldType)> {
    use FieldType::*;
    let s = |x: &str| x.to_string();
    Some(match id {
        "title" => (s("COALESCE(u.title, t.title)"), Text),
        "artist" => (s("COALESCE(u.artist, t.artist)"), Text),
        "album" => (s("COALESCE(u.album, t.album)"), Text),
        "album_artist" => (s("t.album_artist"), Text),
        "genre" => (s("COALESCE(u.genre, t.genre)"), Text),
        "file_genre" => (s("t.genre"), Text),
        "label" => (s("COALESCE(u.record_label, t.label)"), Text),
        "composer" => (s("t.composer"), Text),
        "comment" => (s("t.comment"), Text),
        "mood" => (s("u.mood"), Text),
        "notes" => (s("u.notes"), Text),
        "color" => (s("u.color"), Enum),
        "key" => (s("keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))"), Text),
        "camelot" => (s("a.camelot"), Text),
        "version" => (s("COALESCE(u.version_label, t.version_hint)"), Text),
        "clean_explicit" => (s("COALESCE(u.clean_explicit, t.clean_hint)"), Enum),
        "path" => (s("t.path"), Text),
        "file_name" => (s("t.file_name"), Text),
        "format" => (s("t.format"), Text),
        "extension" => (s("t.extension"), Enum),
        "year" => (s("COALESCE(u.year, t.year)"), Number),
        "original_year" => (s("COALESCE(u.original_year, t.original_year)"), Number),
        "decade" => (s("(COALESCE(u.year, t.year) / 10) * 10"), Number),
        "bpm" => (s("COALESCE(u.bpm, t.bpm_tag, a.bpm)"), Number),
        "energy" => (s("COALESCE(u.energy, a.energy)"), Number),
        "my_energy" => (s("u.energy"), Number),
        "loudness" => (s("a.loudness_lufs"), Number),
        "intro_seconds" => (s("((a.intro_end_ms - a.silence_start_ms) / 1000.0)"), Number),
        "outro_seconds" => (s("((a.duration_ms - a.silence_end_ms - a.outro_start_ms) / 1000.0)"), Number),
        "plays" => (s("(SELECT COUNT(*) FROM play_history ph WHERE ph.track_id = t.id) + (SELECT COUNT(*) FROM gig_events ge WHERE ge.track_id = t.id AND ge.kind = 'played')"), Number),
        "analysed" => (s("(a.status = 'ok')"), Bool),
        "rating" => (s("u.rating"), Number),
        "bitrate" => (s("t.bitrate_kbps"), Number),
        "duration" => (s("(t.duration_ms / 1000.0)"), Number),
        "sample_rate" => (s("t.sample_rate"), Number),
        "file_size_mb" => (s("(t.file_size / 1048576.0)"), Number),
        "added" => (s("t.first_seen_at"), Number),
        "lossless" => (s("t.lossless"), Bool),
        "media" => (s("t.media_kind"), Enum),
        "video_codec" => (s("t.video_codec"), Text),
        "video_height" => (s("t.height"), Number),
        "frame_rate" => (s("t.frame_rate"), Number),
        "tag" => (s(""), Tag),
        "quality" => (
            format!(
                "(CASE WHEN t.media_kind='video' THEN 'video' WHEN t.lossless=1 THEN 'lossless' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < {low_kbps} THEN 'low_bitrate' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL THEN 'lossy' ELSE 'unknown' END)"
            ),
            Enum,
        ),
        "status" => (
            s("(CASE WHEN t.presence='missing' AND t.removed_at IS NOT NULL THEN 'removed' WHEN t.presence='missing' THEN 'missing' WHEN r.status='offline' THEN 'offline' WHEN t.read_status<>'ok' THEN t.read_status ELSE 'ok' END)"),
            Enum,
        ),
        _ => return None,
    })
}

pub const FIELD_LIST: &[FieldInfo] = &[
    FieldInfo {
        id: "artist",
        label: "Artist",
        kind: "text",
    },
    FieldInfo {
        id: "title",
        label: "Title",
        kind: "text",
    },
    FieldInfo {
        id: "album",
        label: "Album",
        kind: "text",
    },
    FieldInfo {
        id: "album_artist",
        label: "Album artist",
        kind: "text",
    },
    FieldInfo {
        id: "genre",
        label: "Genre",
        kind: "text",
    },
    FieldInfo {
        id: "year",
        label: "Year",
        kind: "number",
    },
    FieldInfo {
        id: "original_year",
        label: "Original year (tag)",
        kind: "number",
    },
    FieldInfo {
        id: "decade",
        label: "Decade",
        kind: "number",
    },
    FieldInfo {
        id: "bpm",
        label: "BPM",
        kind: "number",
    },
    FieldInfo {
        id: "key",
        label: "Key",
        kind: "text",
    },
    FieldInfo {
        id: "energy",
        label: "Energy (1–10)",
        kind: "number",
    },
    FieldInfo {
        id: "rating",
        label: "Rating (0–5)",
        kind: "number",
    },
    FieldInfo {
        id: "mood",
        label: "Mood",
        kind: "text",
    },
    FieldInfo {
        id: "color",
        label: "Colour",
        kind: "enum",
    },
    FieldInfo {
        id: "tag",
        label: "Tag",
        kind: "tag",
    },
    FieldInfo {
        id: "version",
        label: "Version label",
        kind: "text",
    },
    FieldInfo {
        id: "clean_explicit",
        label: "Clean / explicit",
        kind: "enum",
    },
    FieldInfo {
        id: "label",
        label: "Record label",
        kind: "text",
    },
    FieldInfo {
        id: "composer",
        label: "Composer",
        kind: "text",
    },
    FieldInfo {
        id: "comment",
        label: "Comment (file)",
        kind: "text",
    },
    FieldInfo {
        id: "notes",
        label: "My notes",
        kind: "text",
    },
    FieldInfo {
        id: "format",
        label: "Format",
        kind: "text",
    },
    FieldInfo {
        id: "extension",
        label: "File extension",
        kind: "enum",
    },
    FieldInfo {
        id: "quality",
        label: "Quality",
        kind: "enum",
    },
    FieldInfo {
        id: "bitrate",
        label: "Bitrate (kbps)",
        kind: "number",
    },
    FieldInfo {
        id: "lossless",
        label: "Lossless",
        kind: "bool",
    },
    FieldInfo {
        id: "media",
        label: "Media (audio / video)",
        kind: "enum",
    },
    FieldInfo {
        id: "video_codec",
        label: "Video codec",
        kind: "text",
    },
    FieldInfo {
        id: "video_height",
        label: "Video height (e.g. 1080)",
        kind: "number",
    },
    FieldInfo {
        id: "frame_rate",
        label: "Frame rate (fps)",
        kind: "number",
    },
    FieldInfo {
        id: "duration",
        label: "Duration (seconds)",
        kind: "number",
    },
    FieldInfo {
        id: "sample_rate",
        label: "Sample rate (Hz)",
        kind: "number",
    },
    FieldInfo {
        id: "file_size_mb",
        label: "File size (MB)",
        kind: "number",
    },
    FieldInfo {
        id: "path",
        label: "Location (path)",
        kind: "text",
    },
    FieldInfo {
        id: "file_name",
        label: "File name",
        kind: "text",
    },
    FieldInfo {
        id: "status",
        label: "Status",
        kind: "enum",
    },
];

pub struct Compiled {
    pub sql: String,
    pub params: Vec<Value>,
}

const MAX_DEPTH: usize = 4;
const MAX_NODES: usize = 200;

fn as_text(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn as_num(v: &serde_json::Value) -> Option<f64> {
    match v {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
    .filter(|f| f.is_finite())
}

struct Compiler {
    low_kbps: u32,
    params: Vec<Value>,
    nodes: usize,
}

impl Compiler {
    fn bind(&mut self, v: Value) -> String {
        self.params.push(v);
        format!("?{}", self.params.len())
    }

    fn condition(&mut self, field_id: &str, op: &str, value: &serde_json::Value) -> Result<String> {
        let Some((expr, ty)) = field(field_id, self.low_kbps) else {
            return invalid(format!("unknown field '{field_id}'"));
        };
        let is_key = matches!(field_id, "key" | "camelot");
        // Key values may be typed in either notation; compare as Camelot.
        let key_norm = |t: String| -> String {
            if is_key {
                crate::analysis::normalize_key(&t).unwrap_or(t)
            } else {
                t
            }
        };
        let text_value = || {
            as_text(value).map(key_norm).ok_or_else(|| {
                crate::error::Error::Invalid(format!("'{field_id}' needs a text value"))
            })
        };
        match (ty, op) {
            (FieldType::Tag, "has") | (FieldType::Tag, "not_has") => {
                let p = self.bind(Value::Text(fold(text_value()?.trim())));
                let ex = format!("EXISTS (SELECT 1 FROM track_tags tt JOIN tags g ON g.id = tt.tag_id WHERE tt.track_id = t.id AND g.name_fold = {p})");
                Ok(if op == "has" { ex } else { format!("NOT {ex}") })
            }
            (FieldType::Tag, "is_empty") => {
                Ok("NOT EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id = t.id)".into())
            }
            (FieldType::Tag, "is_not_empty") => {
                Ok("EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id = t.id)".into())
            }
            (_, "is_empty") => Ok(format!(
                "({expr} IS NULL OR TRIM(CAST({expr} AS TEXT)) = '')"
            )),
            (_, "is_not_empty") => Ok(format!(
                "({expr} IS NOT NULL AND TRIM(CAST({expr} AS TEXT)) <> '')"
            )),
            (FieldType::Text, "contains")
            | (FieldType::Text, "not_contains")
            | (FieldType::Text, "starts_with") => {
                let v = fold(&text_value()?);
                let pat = match op {
                    "starts_with" => format!("{}%", like_escape(&v)),
                    _ => format!("%{}%", like_escape(&v)),
                };
                let p = self.bind(Value::Text(pat));
                let m = format!("fold({expr}) LIKE {p} ESCAPE '\\'");
                Ok(if op == "not_contains" {
                    format!("({expr} IS NULL OR NOT ({m}))")
                } else {
                    m
                })
            }
            (FieldType::Text | FieldType::Enum, "equals")
            | (FieldType::Text | FieldType::Enum, "not_equals") => {
                let p = self.bind(Value::Text(fold(text_value()?.trim())));
                Ok(if op == "equals" {
                    format!("fold({expr}) = {p}")
                } else {
                    format!("({expr} IS NULL OR fold({expr}) <> {p})")
                })
            }
            (FieldType::Enum, "in") | (FieldType::Enum, "not_in") | (FieldType::Text, "in") => {
                let arr = value.as_array().ok_or_else(|| {
                    crate::error::Error::Invalid(format!("'{field_id}' needs a list"))
                })?;
                if arr.is_empty() || arr.len() > 100 {
                    return invalid("list must have 1–100 values");
                }
                let mut ps = Vec::new();
                for v in arr {
                    let t = as_text(v).ok_or_else(|| {
                        crate::error::Error::Invalid("list values must be text".into())
                    })?;
                    ps.push(self.bind(Value::Text(fold(key_norm(t).trim()))));
                }
                let list = ps.join(", ");
                Ok(if op == "not_in" {
                    format!("({expr} IS NULL OR fold({expr}) NOT IN ({list}))")
                } else {
                    format!("fold({expr}) IN ({list})")
                })
            }
            (FieldType::Bool, "is_true") => Ok(format!("{expr} = 1")),
            (FieldType::Bool, "is_false") => Ok(format!("{expr} = 0")),
            (FieldType::Number, "between") => {
                let arr = value.as_array().filter(|a| a.len() == 2).ok_or_else(|| {
                    crate::error::Error::Invalid(format!("'{field_id}' between needs [min, max]"))
                })?;
                let (a, b) = (
                    as_num(&arr[0]).ok_or_else(|| {
                        crate::error::Error::Invalid("min must be a number".into())
                    })?,
                    as_num(&arr[1]).ok_or_else(|| {
                        crate::error::Error::Invalid("max must be a number".into())
                    })?,
                );
                let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
                let p1 = self.bind(Value::Real(lo));
                let p2 = self.bind(Value::Real(hi));
                Ok(format!("({expr} BETWEEN {p1} AND {p2})"))
            }
            (FieldType::Number, "eq" | "neq" | "gt" | "gte" | "lt" | "lte") => {
                let n = as_num(value).ok_or_else(|| {
                    crate::error::Error::Invalid(format!("'{field_id}' needs a number"))
                })?;
                let p = self.bind(Value::Real(n));
                let sym = match op {
                    "eq" => "=",
                    "neq" => "<>",
                    "gt" => ">",
                    "gte" => ">=",
                    "lt" => "<",
                    _ => "<=",
                };
                if op == "neq" {
                    Ok(format!("({expr} IS NULL OR {expr} <> {p})"))
                } else {
                    Ok(format!("({expr} {sym} {p})"))
                }
            }
            _ => invalid(format!(
                "operator '{op}' is not valid for field '{field_id}'"
            )),
        }
    }

    fn node(&mut self, n: &RuleNode, depth: usize) -> Result<String> {
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return invalid("too many rules");
        }
        if depth > MAX_DEPTH {
            return invalid("rule groups are nested too deeply");
        }
        match n {
            RuleNode::Condition { field, op, value } => self.condition(field, op, value),
            RuleNode::Group { match_mode, rules } => self.group(*match_mode, rules, depth + 1),
        }
    }

    fn group(&mut self, m: MatchMode, rules: &[RuleNode], depth: usize) -> Result<String> {
        if rules.is_empty() {
            return Ok("1=1".into());
        }
        let parts = rules
            .iter()
            .map(|r| self.node(r, depth))
            .collect::<Result<Vec<_>>>()?;
        let joiner = if m == MatchMode::All { " AND " } else { " OR " };
        Ok(format!("({})", parts.join(joiner)))
    }
}

/// Compile a rule set to a WHERE fragment. `param_offset` is the number of
/// parameters already bound before this fragment.
pub fn compile(rs: &RuleSet, low_kbps: u32, param_offset: usize) -> Result<Compiled> {
    let mut c = Compiler {
        low_kbps,
        params: vec![Value::Null; param_offset],
        nodes: 0,
    };
    let inc = if rs.rules.is_empty() {
        "1=1".to_string()
    } else {
        c.group(rs.match_mode, &rs.rules, 0)?
    };
    let sql = if rs.exclude.is_empty() {
        inc
    } else {
        let exc = c.group(MatchMode::Any, &rs.exclude, 0)?;
        // COALESCE treats "unknown" (NULL) as not excluded.
        format!("({inc} AND NOT COALESCE({exc}, 0))")
    };
    let params = c.params.split_off(param_offset);
    Ok(Compiled { sql, params })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rejects_unknown_fields_and_ops() {
        let rs: RuleSet = serde_json::from_value(json!({"match":"all","rules":[{"kind":"condition","field":"title; DROP TABLE tracks","op":"contains","value":"x"}]})).unwrap();
        assert!(compile(&rs, 128, 0).is_err());
        let rs: RuleSet = serde_json::from_value(json!({"match":"all","rules":[{"kind":"condition","field":"title","op":"OR 1=1 --","value":"x"}]})).unwrap();
        assert!(compile(&rs, 128, 0).is_err());
    }

    #[test]
    fn values_are_bound_not_inlined() {
        let rs: RuleSet = serde_json::from_value(json!({"match":"all","rules":[{"kind":"condition","field":"title","op":"contains","value":"'); DROP TABLE tracks; --"}]})).unwrap();
        let c = compile(&rs, 128, 0).unwrap();
        assert!(!c.sql.contains("DROP"));
        assert_eq!(c.params.len(), 1);
    }

    #[test]
    fn param_offset_numbers_continue() {
        let rs: RuleSet = serde_json::from_value(json!({"match":"any","rules":[
            {"kind":"condition","field":"bpm","op":"between","value":[120,128]},
            {"kind":"condition","field":"genre","op":"equals","value":"House"}]}))
        .unwrap();
        let c = compile(&rs, 128, 3).unwrap();
        assert!(c.sql.contains("?4") && c.sql.contains("?5") && c.sql.contains("?6"));
        assert_eq!(c.params.len(), 3);
    }
}
