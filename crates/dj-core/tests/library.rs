mod common;
use common::*;
use serde_json::{json, Value};

#[test]
fn scanning_never_modifies_source_files() {
    let e = env();
    let before = snapshot(&e.music);
    // also capture directory listing to prove nothing was added (no sidecar files)
    let app = e.app();
    let st = add_and_scan(&app, &e.music);
    assert_eq!(st["state"], "completed", "{st}");
    call(&app, "start_hash", json!({}));
    app.wait_for_hash();
    let _ = call(&app, "duplicates", json!({}));
    drop(app);
    let after = snapshot(&e.music);
    assert_eq!(
        before, after,
        "source files (bytes, size or modified time) changed during scan/hash"
    );
    // The catalogue lives outside the music folder.
    assert!(!e.db().starts_with(&e.music));
}

#[test]
fn reads_metadata_and_technical_properties() {
    let e = env();
    let app = e.app();
    let st = add_and_scan(&app, &e.music);
    // 22 music-like files (notes.txt is ignored)
    assert_eq!(st["files_found"], 22, "{st}");
    let page = search(&app, json!({"limit": 100}));
    assert_eq!(page["total"], 22);
    let t = find(&page, "Lagos Lights - Sunrise Groove.mp3");
    assert_eq!(t["artist"], "Lagos Lights");
    assert_eq!(t["title"], "Sunrise Groove (feat. Ada)");
    assert_eq!(t["genre"], "Afrobeats");
    assert_eq!(t["year"], 2016);
    assert_eq!(t["bpm"], 104.0);
    assert_eq!(t["key"], "8A");
    let br = t["bitrate_kbps"].as_i64().unwrap();
    assert!((315..=330).contains(&br), "320k CBR reported as {br}"); // container-reported value
    assert_eq!(t["lossless"], false);
    assert_eq!(t["format"], "MP3");
    let d = t["duration_ms"].as_i64().unwrap();
    assert!((1900..=2200).contains(&d), "duration {d}");

    let u = find(&page, "untagged recording.wav");
    assert!(
        u["title"].is_null() && u["artist"].is_null(),
        "unknown values must stay unknown: {u}"
    );
    assert_eq!(u["lossless"], true);

    let alac = find(&page, "Shoreline.m4a");
    assert_eq!(alac["format"], "M4A (ALAC)");
    assert_eq!(alac["lossless"], true);
    let aac = find(&page, "Neon Steps.m4a");
    assert_eq!(aac["format"], "M4A (AAC)");
    assert_eq!(aac["lossless"], false);

    let uni = find(&page, "Beyoncé – Déjà Vu (Medley).mp3");
    assert_eq!(uni["artist"], "Beyoncé Tribute Band");
    assert!(uni["path"].as_str().unwrap().contains("Café Ünïcode"));
}

#[test]
fn low_bitrate_rule_is_honest() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let page = search(&app, json!({"limit": 100}));
    let q = |f: &str| find(&page, f)["quality"].as_str().unwrap().to_string();
    assert_eq!(q("Deep Tenant - Warehouse 94.mp3"), "low_bitrate"); // 96 kbps CBR
    assert_eq!(q("Neon Steps.m4a"), "low_bitrate"); // AAC 64 kbps
    assert_eq!(q("Basement Hours.mp3"), "lossy"); // exactly 128: not below threshold
    assert_eq!(q("Lagos Lights - Sunrise Groove.mp3"), "lossy");
    // Lossless files are never flagged, even when their numeric bitrate is low (sine tones compress well).
    for f in [
        "Low Tide.flac",
        "untagged recording.wav",
        "Driftwood.aiff",
        "Shoreline.m4a",
    ] {
        assert_eq!(q(f), "lossless", "{f}");
    }
    // Unreadable files have unknown quality, not a low-bitrate warning.
    assert_eq!(q("corrupt.mp3"), "unknown");
    assert_eq!(q("old format.wma"), "unknown");

    // Threshold is configurable: at 100 kbps the 96k file is still low, the 64k AAC too, nothing else.
    call(
        &app,
        "set_setting",
        json!({"key": "low_bitrate_kbps", "value": 100}),
    );
    let low = search(
        &app,
        json!({"filters": {"match": "all", "rules": [{"kind": "condition", "field": "quality", "op": "equals", "value": "low_bitrate"}]}}),
    );
    let mut names: Vec<_> = low["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["file_name"].as_str().unwrap())
        .collect();
    names.sort();
    // Opus at 96k and Vorbis q4 may also be under 100: check only that no lossless/unknown file appears.
    for r in low["rows"].as_array().unwrap() {
        assert_eq!(r["lossless"], false);
        assert!(r["bitrate_kbps"].as_i64().unwrap() < 100);
    }
    assert!(names.contains(&"Deep Tenant - Warehouse 94.mp3"));
    assert!(!names.contains(&"Basement Hours.mp3"));
    assert!(app
        .dispatch(
            "set_setting",
            json!({"key": "low_bitrate_kbps", "value": 0})
        )
        .is_err());
}

#[test]
fn corrupt_unsupported_and_empty_files_are_reported_not_fatal() {
    let e = env();
    let app = e.app();
    let st = add_and_scan(&app, &e.music);
    assert_eq!(st["state"], "completed");
    let page = search(&app, json!({"limit": 100}));
    for f in ["corrupt.mp3", "truncated.flac", "empty.mp3"] {
        assert_eq!(find(&page, f)["status"], "error", "{f}");
    }
    assert_eq!(find(&page, "old format.wma")["status"], "unsupported");
    let h = call(&app, "health", json!({}));
    let item = |id: &str| {
        h["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["id"] == id)
            .unwrap()["count"]
            .as_i64()
            .unwrap()
    };
    assert_eq!(item("read_errors"), 3);
    assert_eq!(item("unsupported"), 1);
    assert!(h["recent_errors"].as_array().unwrap().len() >= 3);
    let d = call(
        &app,
        "track_detail",
        json!({"id": find(&page, "corrupt.mp3")["id"]}),
    );
    assert!(d["read_error"].as_str().unwrap().len() > 3);
}

#[test]
fn search_and_filters_return_correct_results() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    // accent-insensitive free text
    assert_eq!(
        titles(&search(&app, json!({"text": "beyonce"}))),
        vec!["Déjà Vu Medley"]
    );
    assert_eq!(
        titles(&search(&app, json!({"text": "DEJA vu"}))),
        vec!["Déjà Vu Medley"]
    );
    // multiple tokens are ANDed
    assert_eq!(search(&app, json!({"text": "sunrise kofi"}))["total"], 1);
    // genre
    let afro = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"genre","op":"equals","value":"afrobeats"}]}}),
    );
    assert_eq!(afro["total"], 8);
    // decade
    let nineties = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"decade","op":"eq","value":1990}]}}),
    );
    assert_eq!(titles(&nineties), vec!["Basement Hours", "Warehouse 94"]);
    // bpm range
    let bpm = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"bpm","op":"between","value":[120,128]}]}}),
    );
    assert_eq!(titles(&bpm), vec!["Warehouse 94"]);
    // OR
    let any = search(
        &app,
        json!({"filters": {"match":"any","rules":[
        {"kind":"condition","field":"genre","op":"equals","value":"disco"},
        {"kind":"condition","field":"genre","op":"equals","value":"ambient"}]}}),
    );
    assert_eq!(any["total"], 4);
    // location
    let loc = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"path","op":"contains","value":"old school"}]}}),
    );
    assert_eq!(loc["total"], 2);
    // sort
    let by_year = search(
        &app,
        json!({"sort": "year", "filters": {"match":"all","rules":[{"kind":"condition","field":"year","op":"is_not_empty"}]}}),
    );
    let years: Vec<i64> = by_year["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["year"].as_i64().unwrap())
        .collect();
    let mut sorted = years.clone();
    sorted.sort();
    assert_eq!(years, sorted);
    // LIKE wildcards in user text are literal
    assert_eq!(search(&app, json!({"text": "%"}))["total"], 0);
    assert_eq!(search(&app, json!({"text": "_"}))["total"], 0);
    // catalogue values are searchable and filterable
    let id = find(
        &search(&app, json!({"text": "warehouse"})),
        "Deep Tenant - Warehouse 94.mp3",
    )["id"]
        .clone();
    call(
        &app,
        "update_user_fields",
        json!({"ids": [id], "patch": {"energy": 8, "mood": "Peak time"}}),
    );
    call(
        &app,
        "set_tags",
        json!({"ids": [id], "add": ["Warm-up", "Vinyl rip"]}),
    );
    assert_eq!(search(&app, json!({"text": "peak"}))["total"], 1);
    assert_eq!(search(&app, json!({"text": "vinyl"}))["total"], 1);
    let tag = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"tag","op":"has","value":"warm-up"}]}}),
    );
    assert_eq!(tag["total"], 1);
    let energy = search(
        &app,
        json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"energy","op":"between","value":[6,8]}]}}),
    );
    assert_eq!(energy["total"], 1);
    // invalid catalogue values are rejected without partial writes
    assert!(app
        .dispatch(
            "update_user_fields",
            json!({"ids": [id], "patch": {"energy": 11}})
        )
        .is_err());
}

#[test]
fn sql_like_input_cannot_execute_sql() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let evil = [
        "'; DROP TABLE tracks; --",
        "\" OR 1=1 --",
        "x') OR ('1'='1",
        "1; DELETE FROM crates",
        "%' UNION SELECT name FROM sqlite_master --",
    ];
    for s in evil {
        assert_eq!(search(&app, json!({"text": s}))["total"], 0, "{s}");
        let r = search(
            &app,
            json!({"filters": {"match":"all","rules":[{"kind":"condition","field":"title","op":"contains","value": s}]}}),
        );
        assert_eq!(r["total"], 0);
        call(&app, "set_tags", json!({"ids": [1], "add": [s]}));
        let c = call(
            &app,
            "create_crate",
            json!({"input": {"name": s, "kind": "smart", "rules": {"match":"all","rules":[{"kind":"condition","field":"artist","op":"equals","value": s}]}}}),
        );
        assert_eq!(c["name"], s);
        assert_eq!(c["track_count"], 0);
        // the assistant also only binds values
        let _ = call(&app, "assistant", json!({"message": s}));
    }
    // field/operator/sort names are whitelisted
    assert!(app
        .dispatch(
            "search",
            json!({"query": {"sort": "title; DROP TABLE tracks"}})
        )
        .is_err());
    assert!(app.dispatch("search", json!({"query": {"filters": {"match":"all","rules":[{"kind":"condition","field":"1=1) OR (1","op":"equals","value":"x"}]}}})).is_err());
    assert!(app.dispatch("search", json!({"query": {"filters": {"match":"all","rules":[{"kind":"condition","field":"title","op":"= '' OR 1=1 --","value":"x"}]}}})).is_err());
    // the catalogue is intact
    assert_eq!(search(&app, json!({}))["total"], 22);
    assert_eq!(
        call(&app, "list_crates", json!({}))
            .as_array()
            .unwrap()
            .len(),
        evil.len()
    );
}

#[test]
fn data_and_crates_persist_after_restart() {
    let e = env();
    {
        let app = e.app();
        add_and_scan(&app, &e.music);
        let id = find(
            &search(&app, json!({"text": "warehouse"})),
            "Deep Tenant - Warehouse 94.mp3",
        )["id"]
            .clone();
        let c = call(
            &app,
            "create_crate",
            json!({"input": {"name": "Warm-up", "kind": "manual", "color": "teal"}}),
        );
        call(&app, "crate_add", json!({"crate_id": c["id"], "ids": [id]}));
        call(
            &app,
            "update_user_fields",
            json!({"ids": [id], "patch": {"rating": 5, "energy": 3, "notes": "Great opener"}}),
        );
        call(
            &app,
            "set_setting",
            json!({"key": "low_bitrate_kbps", "value": 160}),
        );
    }
    let app = e.app();
    assert_eq!(search(&app, json!({}))["total"], 22);
    let crates = call(&app, "list_crates", json!({}));
    assert_eq!(crates[0]["name"], "Warm-up");
    assert_eq!(crates[0]["color"], "teal");
    assert_eq!(crates[0]["track_count"], 1);
    let t = &search(&app, json!({"crate_id": crates[0]["id"]}))["rows"][0];
    assert_eq!(t["rating"], 5);
    assert_eq!(t["energy"], 3);
    assert_eq!(
        call(&app, "get_settings", json!({}))["low_bitrate_kbps"],
        160
    );
    // An unchanged rescan keeps ids stable and reads nothing again.
    let id_before = t["id"].clone();
    let st = scan(&app);
    // Unchanged readable files are skipped; the 3 unreadable files are retried each scan.
    assert_eq!(st["unchanged"], 19, "{st}");
    assert_eq!(st["updated"], 3, "{st}");
    assert_eq!(st["added"], 0);
    let t2 = find(
        &search(&app, json!({"text": "warehouse"})),
        "Deep Tenant - Warehouse 94.mp3",
    )
    .clone();
    assert_eq!(t2["id"], id_before);
}

#[test]
fn manual_and_smart_crates() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    // Afrobeats AND 2010-2019, excluding live versions
    let rules = json!({"match":"all","rules":[
        {"kind":"condition","field":"genre","op":"equals","value":"Afrobeats"},
        {"kind":"condition","field":"year","op":"between","value":[2010,2019]}],
        "exclude":[{"kind":"condition","field":"version","op":"contains","value":"live"}]});
    let preview = call(&app, "preview_rules", json!({"rules": rules}));
    let mut names: Vec<String> = preview["sample"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["file_name"].as_str().unwrap().to_string())
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "Lagos Lights - Sunrise Groove.mp3",
            "Night Market (Clean).mp3",
            "Sunrise Groove (Kofi Remix).mp3",
            "Sunrise Groove (copy).mp3",
            "Sunrise Groove 192.mp3"
        ]
    );
    let smart = call(
        &app,
        "create_crate",
        json!({"input": {"name": "Afro 2010s", "kind": "smart", "rules": rules}}),
    );
    assert_eq!(smart["track_count"], 5);
    // removing from a smart crate records an exclusion
    let copy_id = find(
        &search(&app, json!({"crate_id": smart["id"], "limit": 50})),
        "Sunrise Groove (copy).mp3",
    )["id"]
        .clone();
    call(
        &app,
        "crate_remove",
        json!({"crate_id": smart["id"], "ids": [copy_id]}),
    );
    assert_eq!(call(&app, "list_crates", json!({}))[0]["track_count"], 4);
    // manual addition to a smart crate
    let ambient = find(&search(&app, json!({"text": "low tide"})), "Low Tide.flac")["id"].clone();
    call(
        &app,
        "crate_add",
        json!({"crate_id": smart["id"], "ids": [ambient]}),
    );
    assert_eq!(search(&app, json!({"crate_id": smart["id"]}))["total"], 5);
    // the same track can live in several manual crates without copies
    let a = call(
        &app,
        "create_crate",
        json!({"input": {"name": "Wedding", "kind": "manual"}}),
    );
    let b = call(
        &app,
        "create_crate",
        json!({"input": {"name": "Sunday chill", "kind": "manual"}}),
    );
    call(
        &app,
        "crate_add",
        json!({"crate_id": a["id"], "ids": [ambient]}),
    );
    call(
        &app,
        "crate_add",
        json!({"crate_id": b["id"], "ids": [ambient]}),
    );
    let d = call(&app, "track_detail", json!({"id": ambient}));
    assert_eq!(d["crates"].as_array().unwrap().len(), 3);
    // rename keeps membership
    call(
        &app,
        "update_crate",
        json!({"id": a["id"], "input": {"name": "Wedding 2026", "kind": "manual", "color": "pink"}}),
    );
    assert_eq!(search(&app, json!({"crate_id": a["id"]}))["total"], 1);
    // add by query
    call(
        &app,
        "crate_add_query",
        json!({"crate_id": b["id"], "query": {"text": "velvet"}}),
    );
    assert_eq!(search(&app, json!({"crate_id": b["id"]}))["total"], 4);
    // invalid rules are rejected before saving
    assert!(app.dispatch("create_crate", json!({"input": {"name": "Bad", "kind": "smart", "rules": {"match":"all","rules":[{"kind":"condition","field":"bpm","op":"contains","value":"x"}]}}})).is_err());
    assert!(app
        .dispatch(
            "create_crate",
            json!({"input": {"name": "  ", "kind": "manual"}})
        )
        .is_err());
    // deleting a crate does not delete tracks
    call(&app, "delete_crate", json!({"id": a["id"]}));
    assert_eq!(search(&app, json!({}))["total"], 22);
}

#[test]
fn exact_possible_and_alternate_duplicates_are_separated() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    // Before hashing there can be no "exact" group.
    let groups = call(&app, "duplicates", json!({}));
    assert!(groups
        .as_array()
        .unwrap()
        .iter()
        .all(|g| g["kind"] != "exact"));
    call(&app, "start_hash", json!({}));
    app.wait_for_hash();
    let hs = call(&app, "hash_status", json!({}));
    assert_eq!(hs["state"], "completed", "{hs}");
    let groups = call(&app, "duplicates", json!({}));
    let groups = groups.as_array().unwrap();
    let names = |g: &Value| {
        let mut v: Vec<String> = g["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["file_name"].as_str().unwrap().to_string())
            .collect();
        v.sort();
        v
    };
    let exact: Vec<_> = groups.iter().filter(|g| g["kind"] == "exact").collect();
    assert_eq!(exact.len(), 1, "{groups:?}");
    assert_eq!(
        names(exact[0]),
        vec![
            "Lagos Lights - Sunrise Groove.mp3",
            "Sunrise Groove (copy).mp3"
        ]
    );
    assert!(exact[0]["reason"].as_str().unwrap().contains("hash"));

    let possible: Vec<_> = groups.iter().filter(|g| g["kind"] == "possible").collect();
    assert_eq!(possible.len(), 1, "{possible:?}");
    assert_eq!(
        names(possible[0]),
        vec![
            "Lagos Lights - Sunrise Groove.mp3",
            "Sunrise Groove (copy).mp3",
            "Sunrise Groove 192.mp3"
        ]
    );
    assert!(possible[0]["reason"]
        .as_str()
        .unwrap()
        .contains("not proven identical"));

    let alt: Vec<_> = groups.iter().filter(|g| g["kind"] == "alternate").collect();
    assert_eq!(alt.len(), 1);
    let an = names(alt[0]);
    assert!(
        an.contains(&"Sunrise Groove (Kofi Remix).mp3".to_string())
            && an.contains(&"Sunrise Groove (Live).mp3".to_string())
    );
    // Same title but very different durations: not a candidate.
    assert!(groups
        .iter()
        .all(|g| !names(g).contains(&"Intro (album A).mp3".to_string())));
    // Review decisions are stored without touching files.
    let key = alt[0]["key"].as_str().unwrap();
    call(
        &app,
        "set_dup_decision",
        json!({"key": key, "decision": "intentional_version"}),
    );
    let again = call(&app, "duplicates", json!({}));
    assert_eq!(
        again
            .as_array()
            .unwrap()
            .iter()
            .find(|g| g["key"] == key)
            .unwrap()["decision"],
        "intentional_version"
    );
    assert!(app
        .dispatch(
            "set_dup_decision",
            json!({"key": key, "decision": "delete"})
        )
        .is_err());
}

#[test]
fn hash_cache_is_invalidated_when_file_changes() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    call(&app, "start_hash", json!({}));
    app.wait_for_hash();
    // Change the copy (test fixture copy only) so it is no longer identical, then rescan.
    let copy = e.music.join("Copies/Sunrise Groove (copy).mp3");
    let mut bytes = std::fs::read(&copy).unwrap();
    bytes.extend_from_slice(b"TAGDIFF");
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(&copy, bytes).unwrap();
    scan(&app);
    call(&app, "start_hash", json!({}));
    app.wait_for_hash();
    let groups = call(&app, "duplicates", json!({}));
    assert!(
        groups
            .as_array()
            .unwrap()
            .iter()
            .all(|g| g["kind"] != "exact"),
        "stale hash produced an exact match"
    );
}

#[test]
fn disconnected_drive_is_offline_not_deleted() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let unplugged = e.music.with_file_name("My Music (unplugged)");
    std::fs::rename(&e.music, &unplugged).unwrap();
    let st = scan(&app);
    assert_eq!(st["state"], "completed");
    assert_eq!(st["offline_roots"], 1);
    assert_eq!(st["missing"], 0);
    let roots = call(&app, "list_roots", json!({}));
    assert_eq!(roots[0]["status"], "offline");
    let page = search(&app, json!({"limit": 100}));
    assert_eq!(
        page["total"], 22,
        "tracks on an offline drive must stay in the catalogue"
    );
    assert!(page["rows"]
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["status"] == "offline"
            || r["status"] == "error"
            || r["status"] == "unsupported"));
    // reconnect
    std::fs::rename(&unplugged, &e.music).unwrap();
    let st = scan(&app);
    assert_eq!(
        st["unchanged"].as_i64().unwrap() + st["updated"].as_i64().unwrap(),
        22
    );
    assert_eq!(st["added"], 0);
    assert_eq!(call(&app, "list_roots", json!({}))[0]["status"], "online");
}

#[test]
fn deleted_files_are_marked_missing_not_removed() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    std::fs::remove_file(e.music.join("House/Mirrorball.ogg")).unwrap();
    let st = scan(&app);
    assert_eq!(st["missing"], 1);
    assert_eq!(search(&app, json!({}))["total"], 21);
    let all = search(&app, json!({"include_missing": true, "limit": 100}));
    assert_eq!(all["total"], 22);
    assert_eq!(find(&all, "Mirrorball.ogg")["status"], "missing");
}

#[test]
fn cancelled_scan_leaves_catalogue_consistent() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    std::fs::remove_file(e.music.join("House/Mirrorball.ogg")).unwrap();
    // Start paused, then cancel: the scan stops before completing.
    call(&app, "start_scan", json!({"start_paused": true}));
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert_eq!(call(&app, "scan_status", json!({}))["state"], "paused");
    call(&app, "cancel_scan", json!({}));
    app.wait_for_scan();
    let st = call(&app, "scan_status", json!({}));
    assert_eq!(st["state"], "cancelled", "{st}");
    // A cancelled scan must not mark anything missing.
    assert_eq!(search(&app, json!({}))["total"], 22);
    drop(app);
    let conn = rusqlite::Connection::open(e.db()).unwrap();
    let ok: String = conn
        .query_row("PRAGMA integrity_check", [], |r| r.get(0))
        .unwrap();
    assert_eq!(ok, "ok");
    let status: String = conn
        .query_row(
            "SELECT status FROM scans ORDER BY id DESC LIMIT 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(status, "cancelled");
}

#[test]
fn interrupted_scan_is_recovered_on_restart() {
    let e = env();
    {
        let app = e.app();
        add_and_scan(&app, &e.music);
    }
    {
        // Simulate a crash mid-scan: a 'running' scan row left behind.
        let conn = rusqlite::Connection::open(e.db()).unwrap();
        conn.execute(
            "INSERT INTO scans(started_at, status) VALUES (1, 'running')",
            [],
        )
        .unwrap();
    }
    let app = e.app();
    let h = call(&app, "health", json!({}));
    assert_eq!(h["last_scan"]["status"], "interrupted");
    assert_eq!(search(&app, json!({}))["total"], 22);
}

#[test]
fn nested_and_invalid_roots_are_rejected() {
    let e = env();
    let app = e.app();
    call(&app, "add_root", json!({"path": e.music.to_str().unwrap()}));
    assert!(app
        .dispatch(
            "add_root",
            json!({"path": e.music.join("House").to_str().unwrap()})
        )
        .is_err());
    assert!(app
        .dispatch(
            "add_root",
            json!({"path": e.music.parent().unwrap().to_str().unwrap()})
        )
        .is_err());
    assert!(app
        .dispatch("add_root", json!({"path": e.music.to_str().unwrap()}))
        .is_err());
    assert!(app
        .dispatch("add_root", json!({"path": "relative/path"}))
        .is_err());
    assert!(app
        .dispatch(
            "add_root",
            json!({"path": e.music.join("does-not-exist").to_str().unwrap()})
        )
        .is_err());
    // removing a root removes catalogue rows only
    add_and_scan(&app, &e.music.parent().unwrap().join("AppData")).get("state"); // empty-ish folder: just exercise
    let roots = call(&app, "list_roots", json!({}));
    let id = roots
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["path"].as_str().unwrap().ends_with("My Music"))
        .unwrap()["id"]
        .clone();
    call(&app, "remove_root", json!({"id": id}));
    assert!(e.music.join("House/Mirrorball.ogg").exists());
}

#[test]
fn symlink_loops_do_not_hang() {
    #[cfg(unix)]
    {
        let e = env();
        std::os::unix::fs::symlink(&e.music, e.music.join("House/loop")).unwrap();
        let app = e.app();
        let st = add_and_scan(&app, &e.music);
        assert_eq!(st["state"], "completed");
        assert_eq!(st["files_found"], 22);
    }
}

#[test]
fn assistant_turns_requests_into_filters() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let r = call(
        &app,
        "assistant",
        json!({"message": "Afrobeats from the 2010s no live"}),
    );
    assert_eq!(r["action"], "search");
    assert_eq!(r["total"], 5, "{r}");
    let r = call(
        &app,
        "assistant",
        json!({"message": "house 120 to 128 bpm"}),
    );
    assert_eq!(r["total"], 1, "{r}");
    let r = call(&app, "assistant", json!({"message": "low bitrate"}));
    // 96k MP3, 64k AAC, and the Vorbis/Opus tones (sine tones encode to low averages)
    assert_eq!(r["total"], 4, "{r}");
    assert!(r["sample"]
        .as_array()
        .unwrap()
        .iter()
        .all(|t| t["lossless"] == false));
    let r = call(&app, "assistant", json!({"message": "show duplicates"}));
    assert_eq!(r["action"], "navigate");
    let r = call(&app, "assistant", json!({"message": "help"}));
    assert!(r["reply"].as_str().unwrap().contains("not an AI model"));
    let r = call(&app, "assistant", json!({"message": "clean"}));
    assert_eq!(r["total"], 1);
}
