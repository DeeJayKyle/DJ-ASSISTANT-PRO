//! SQLite catalogue. All statements use bound parameters; user text is never
//! interpolated into SQL. Schema changes go through numbered migrations.
use crate::error::Result;
use rusqlite::functions::FunctionFlags;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const MIGRATIONS: &[&str] = &[
    // 1: initial schema
    r#"
CREATE TABLE library_roots (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    path_key TEXT NOT NULL UNIQUE,
    label TEXT,
    status TEXT NOT NULL DEFAULT 'unknown' CHECK (status IN ('online','offline','unknown')),
    added_at INTEGER NOT NULL,
    last_scan_at INTEGER,
    last_scan_status TEXT
);

CREATE TABLE scans (
    id INTEGER PRIMARY KEY,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    status TEXT NOT NULL CHECK (status IN ('running','completed','cancelled','failed','interrupted')),
    files_seen INTEGER NOT NULL DEFAULT 0,
    tracks_added INTEGER NOT NULL DEFAULT 0,
    tracks_updated INTEGER NOT NULL DEFAULT 0,
    tracks_unchanged INTEGER NOT NULL DEFAULT 0,
    tracks_missing INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    message TEXT
);

CREATE TABLE scan_errors (
    id INTEGER PRIMARY KEY,
    scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
    root_id INTEGER REFERENCES library_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    kind TEXT NOT NULL,
    message TEXT NOT NULL,
    at INTEGER NOT NULL
);
CREATE INDEX idx_scan_errors_scan ON scan_errors(scan_id);

CREATE TABLE tracks (
    id INTEGER PRIMARY KEY,
    uid TEXT NOT NULL UNIQUE,
    root_id INTEGER NOT NULL REFERENCES library_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    path_key TEXT NOT NULL UNIQUE,
    rel_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    extension TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    file_mtime INTEGER,
    read_status TEXT NOT NULL CHECK (read_status IN ('ok','error','unsupported')),
    read_error TEXT,
    presence TEXT NOT NULL DEFAULT 'present' CHECK (presence IN ('present','missing')),
    format TEXT,
    codec TEXT,
    lossless INTEGER,
    duration_ms INTEGER,
    bitrate_kbps INTEGER,
    sample_rate INTEGER,
    bit_depth INTEGER,
    channels INTEGER,
    title TEXT,
    artist TEXT,
    album TEXT,
    album_artist TEXT,
    genre TEXT,
    year INTEGER,
    date_text TEXT,
    original_year INTEGER,
    track_no INTEGER,
    disc_no INTEGER,
    composer TEXT,
    label TEXT,
    comment TEXT,
    isrc TEXT,
    bpm_tag REAL,
    key_tag TEXT,
    version_hint TEXT,
    clean_hint TEXT,
    work_key TEXT,
    search_text TEXT NOT NULL DEFAULT '',
    content_hash TEXT,
    hash_size INTEGER,
    hash_mtime INTEGER,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    last_scan_id INTEGER
);
CREATE INDEX idx_tracks_root ON tracks(root_id);
CREATE INDEX idx_tracks_size ON tracks(file_size);
CREATE INDEX idx_tracks_work ON tracks(work_key);
CREATE INDEX idx_tracks_artist ON tracks(artist);
CREATE INDEX idx_tracks_hash ON tracks(content_hash);

-- Values chosen by the DJ and stored only in this catalogue (never written to files).
CREATE TABLE track_user (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    genre TEXT,
    year INTEGER CHECK (year IS NULL OR (year BETWEEN 1000 AND 9999)),
    bpm REAL CHECK (bpm IS NULL OR (bpm > 0 AND bpm < 1000)),
    musical_key TEXT,
    energy INTEGER CHECK (energy IS NULL OR (energy BETWEEN 1 AND 10)),
    rating INTEGER CHECK (rating IS NULL OR (rating BETWEEN 0 AND 5)),
    mood TEXT,
    color TEXT,
    notes TEXT,
    version_label TEXT,
    clean_explicit TEXT CHECK (clean_explicit IS NULL OR clean_explicit IN ('clean','explicit')),
    updated_at INTEGER NOT NULL
);

CREATE TABLE tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    name_fold TEXT NOT NULL UNIQUE
);
CREATE TABLE track_tags (
    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (track_id, tag_id)
);

CREATE TABLE crates (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('manual','smart')),
    color TEXT,
    category TEXT,
    parent_id INTEGER REFERENCES crates(id) ON DELETE SET NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    rules_json TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE crate_tracks (
    crate_id INTEGER NOT NULL REFERENCES crates(id) ON DELETE CASCADE,
    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    mode TEXT NOT NULL DEFAULT 'include' CHECK (mode IN ('include','exclude')),
    position INTEGER NOT NULL DEFAULT 0,
    added_at INTEGER NOT NULL,
    PRIMARY KEY (crate_id, track_id)
);
CREATE INDEX idx_crate_tracks_track ON crate_tracks(track_id);

-- DJ decisions about duplicate candidates. Recording a decision never touches files.
CREATE TABLE duplicate_reviews (
    pair_key TEXT PRIMARY KEY,
    decision TEXT NOT NULL CHECK (decision IN ('not_duplicate','intentional_version','confirmed_duplicate')),
    decided_at INTEGER NOT NULL
);

CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"#,
    // 2: v1.0 features
    r#"
-- Local analysis estimates (never treated as facts; method + version kept).
CREATE TABLE analysis (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    method TEXT NOT NULL,
    version INTEGER NOT NULL,
    analysed_at INTEGER NOT NULL,
    file_size INTEGER,
    file_mtime INTEGER,
    status TEXT NOT NULL CHECK (status IN ('ok','error')),
    error TEXT,
    bpm REAL, bpm_confidence REAL, bpm_alt REAL,
    musical_key TEXT, camelot TEXT, key_confidence REAL,
    energy INTEGER,
    loudness_lufs REAL, peak_dbfs REAL, clipped_runs INTEGER,
    silence_start_ms INTEGER, silence_end_ms INTEGER,
    intro_end_ms INTEGER, outro_start_ms INTEGER,
    tempo_stable INTEGER,
    cues_json TEXT, warnings_json TEXT,
    waveform BLOB,
    fingerprint BLOB,
    fingerprint_encoded TEXT,
    duration_ms INTEGER
);

-- Suggestions from local heuristics, analysis or online sources. Accepting one
-- writes to track_user only; music files are never changed by this.
CREATE TABLE suggestions (
    id INTEGER PRIMARY KEY,
    track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    field TEXT NOT NULL,
    current_value TEXT,
    suggested_value TEXT NOT NULL,
    source TEXT NOT NULL,
    evidence TEXT,
    confidence REAL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','rejected')),
    created_at INTEGER NOT NULL,
    decided_at INTEGER,
    UNIQUE (track_id, field, suggested_value, source)
);
CREATE INDEX idx_suggestions_status ON suggestions(status);

-- Every change made to a file (opt-in tag writing) with its verified backup.
CREATE TABLE change_log (
    id INTEGER PRIMARY KEY,
    track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    path TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('tag_write','rollback')),
    changes_json TEXT NOT NULL,
    backup_path TEXT,
    before_hash TEXT,
    after_hash TEXT,
    status TEXT NOT NULL CHECK (status IN ('done','failed','rolled_back')),
    error TEXT,
    at INTEGER NOT NULL
);

CREATE TABLE set_plans (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    params_json TEXT NOT NULL,
    slots_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE gigs (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    set_plan_id INTEGER REFERENCES set_plans(id) ON DELETE SET NULL,
    started_at INTEGER NOT NULL,
    ended_at INTEGER
);
CREATE TABLE gig_events (
    id INTEGER PRIMARY KEY,
    gig_id INTEGER NOT NULL REFERENCES gigs(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('played','request','note')),
    track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    text TEXT,
    status TEXT,
    at INTEGER NOT NULL
);

CREATE TABLE play_history (
    id INTEGER PRIMARY KEY,
    source TEXT NOT NULL,
    session TEXT,
    track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    artist TEXT,
    title TEXT,
    played_at INTEGER,
    imported_at INTEGER NOT NULL
);
CREATE INDEX idx_play_history_track ON play_history(track_id);

CREATE TABLE followed (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('artist','label')),
    name TEXT NOT NULL,
    mbid TEXT,
    added_at INTEGER NOT NULL,
    UNIQUE (kind, name)
);

CREATE TABLE discovery (
    id INTEGER PRIMARY KEY,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    artist TEXT,
    title TEXT,
    detail TEXT,
    reason TEXT,
    url TEXT,
    released TEXT,
    fetched_at INTEGER NOT NULL,
    owned_track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    ownership TEXT NOT NULL DEFAULT 'missing' CHECK (ownership IN ('owned','possibly_owned','missing')),
    status TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new','wishlist','dismissed')),
    UNIQUE (source, kind, artist, title)
);

-- Explicit likes/dislikes the DJ gives to recommendations (inspectable, resettable).
CREATE TABLE pref_feedback (
    id INTEGER PRIMARY KEY,
    subject_kind TEXT NOT NULL,
    subject TEXT NOT NULL,
    value INTEGER NOT NULL CHECK (value IN (-1, 1)),
    at INTEGER NOT NULL,
    UNIQUE (subject_kind, subject)
);

-- Files noticed by the folder watcher, waiting for a scan.
CREATE TABLE watch_events (
    id INTEGER PRIMARY KEY,
    root_id INTEGER REFERENCES library_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL,
    at INTEGER NOT NULL
);

-- Personal files module (opt-in, separate from music).
CREATE TABLE doc_roots (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    path_key TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'unknown',
    added_at INTEGER NOT NULL,
    last_scan_at INTEGER
);
CREATE TABLE documents (
    id INTEGER PRIMARY KEY,
    root_id INTEGER NOT NULL REFERENCES doc_roots(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    path_key TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    folder TEXT NOT NULL,
    ext TEXT NOT NULL,
    size INTEGER NOT NULL,
    mtime INTEGER,
    content_status TEXT NOT NULL,
    content TEXT,
    search_text TEXT NOT NULL DEFAULT '',
    hash TEXT,
    presence TEXT NOT NULL DEFAULT 'present',
    last_seen_at INTEGER NOT NULL
);
CREATE INDEX idx_documents_size ON documents(size);

ALTER TABLE track_user ADD COLUMN title TEXT;
ALTER TABLE track_user ADD COLUMN artist TEXT;
ALTER TABLE track_user ADD COLUMN album TEXT;
ALTER TABLE track_user ADD COLUMN original_year INTEGER CHECK (original_year IS NULL OR (original_year BETWEEN 1000 AND 9999));
ALTER TABLE track_user ADD COLUMN record_label TEXT;
"#,
    // 3: library-relative energy
    r#"
ALTER TABLE analysis ADD COLUMN energy_raw REAL;
"#,
    // 4: video files (music videos, visuals)
    r#"
ALTER TABLE tracks ADD COLUMN media_kind TEXT NOT NULL DEFAULT 'audio';
ALTER TABLE tracks ADD COLUMN video_codec TEXT;
ALTER TABLE tracks ADD COLUMN width INTEGER;
ALTER TABLE tracks ADD COLUMN height INTEGER;
ALTER TABLE tracks ADD COLUMN frame_rate REAL;
CREATE INDEX idx_tracks_media ON tracks(media_kind);
-- Re-read .mp4 files once so music videos are recognised as video.
UPDATE tracks SET file_mtime = NULL WHERE extension = 'mp4';
"#,
    // 5: file organiser (opt-in renames and restorable removals)
    r#"
ALTER TABLE tracks ADD COLUMN removed_at INTEGER;
CREATE TABLE file_ops (
    id INTEGER PRIMARY KEY,
    batch TEXT NOT NULL,
    op TEXT NOT NULL CHECK (op IN ('rename','move','folder_rename','remove')),
    track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL,
    from_path TEXT NOT NULL,
    to_path TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('done','undone','purged','failed')),
    error TEXT,
    at INTEGER NOT NULL
);
CREATE INDEX idx_file_ops_batch ON file_ops(batch);
"#,
    // 6: online catalogue checks (Deezer, Apple Music), so tracks aren't looked up twice
    r#"
CREATE TABLE catalog_checked (
    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    checked_at INTEGER NOT NULL
);
"#,
];

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Open (creating if needed) the catalogue and apply migrations.
pub fn open(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let conn = Connection::open(path)?;
    configure(&conn)?;
    migrate(&conn)?;
    Ok(conn)
}

pub fn open_in_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    configure(&conn)?;
    migrate(&conn)?;
    Ok(conn)
}

fn configure(conn: &Connection) -> Result<()> {
    conn.busy_timeout(std::time::Duration::from_secs(10))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    // Defence in depth: user text is always bound, but also refuse to let
    // SQL load extensions or run untrusted schema code.
    conn.pragma_update(None, "trusted_schema", "OFF")?;
    conn.create_scalar_function(
        "fold",
        1,
        FunctionFlags::SQLITE_UTF8
            | FunctionFlags::SQLITE_DETERMINISTIC
            | FunctionFlags::SQLITE_INNOCUOUS,
        |ctx| {
            let v: Option<String> = ctx.get(0)?;
            Ok(v.map(|s| crate::text::fold(&s)))
        },
    )?;
    // keynorm(x): any key spelling -> Camelot code, or the text unchanged.
    conn.create_scalar_function(
        "keynorm",
        1,
        FunctionFlags::SQLITE_UTF8
            | FunctionFlags::SQLITE_DETERMINISTIC
            | FunctionFlags::SQLITE_INNOCUOUS,
        |ctx| {
            let v: Option<String> = ctx.get(0)?;
            Ok(v.map(|s| crate::analysis::normalize_key(&s).unwrap_or(s)))
        },
    )?;
    Ok(())
}

fn migrate(conn: &Connection) -> Result<()> {
    let current: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate() {
        let version = (i + 1) as i64;
        if version > current {
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", version)?;
            tx.commit()?;
        }
    }
    // Any scan still marked running belongs to a previous session that was
    // interrupted (crash, power loss). Mark it honestly.
    conn.execute(
        "UPDATE scans SET status='interrupted', finished_at=?1, message=COALESCE(message,'App closed or crashed during scan; rows written before the interruption are intact.') WHERE status='running'",
        params![now_ms()],
    )?;
    Ok(())
}

pub fn get_setting(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT value FROM settings WHERE key=?1",
            params![key],
            |r| r.get(0),
        )
        .optional()?)
}

pub fn set_setting(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO settings(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![key, value],
    )?;
    Ok(())
}

pub const DEFAULT_LOW_BITRATE_KBPS: u32 = 128;

pub fn low_bitrate_threshold(conn: &Connection) -> Result<u32> {
    Ok(get_setting(conn, "low_bitrate_kbps")?
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|v| (8..=2000).contains(v))
        .unwrap_or(DEFAULT_LOW_BITRATE_KBPS))
}
