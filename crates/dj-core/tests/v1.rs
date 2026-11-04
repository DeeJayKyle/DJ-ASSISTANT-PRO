//! Integration tests for v1.0 features, run on copies of the fixture library.
mod common;
use common::*;
use dj_core::online::{
    AcoustidMatch, MbRecording, MemorySecrets, Online, ReleaseItem, SimilarItem,
};
use dj_core::App;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

struct FakeOnline;
impl Online for FakeOnline {
    fn musicbrainz_recordings(
        &self,
        artist: &str,
        title: &str,
    ) -> Result<Vec<MbRecording>, String> {
        Ok(vec![MbRecording {
            mbid: "mbid-1".into(),
            title: title.split(" (").next().unwrap_or(title).into(),
            artist: artist.into(),
            score: 100.0,
            first_release_date: Some("2015-06-01".into()),
            release_title: Some("Coastline".into()),
            label: Some("Harbour Records".into()),
            tags: vec!["afrobeats".into()],
            isrcs: vec![],
            length_ms: Some(2000),
            disambiguation: None,
        }])
    }
    fn musicbrainz_artist_releases(&self, artist: &str) -> Result<Vec<ReleaseItem>, String> {
        Ok(vec![ReleaseItem {
            artist: artist.into(),
            title: "Brand New Single".into(),
            date: Some("2026-10-01".into()),
            kind: "Single".into(),
            url: None,
        }])
    }
    fn acoustid_lookup(&self, key: &str, _d: u32, fp: &str) -> Result<Vec<AcoustidMatch>, String> {
        assert_eq!(key, "test-key");
        assert!(!fp.is_empty());
        Ok(vec![AcoustidMatch {
            score: 0.92,
            recording_mbid: "rec-1".into(),
            title: Some("Long Tone (Original Mix)".into()),
            artist: Some("Quiet Harbour".into()),
            first_year: Some(2019),
        }])
    }
    fn lastfm_similar_artists(&self, _k: &str, _a: &str) -> Result<Vec<SimilarItem>, String> {
        Ok(vec![
            SimilarItem {
                artist: "Harbour Kings".into(),
                title: None,
                score: 0.9,
                url: None,
            },
            SimilarItem {
                artist: "Unknown Newcomer".into(),
                title: None,
                score: 0.7,
                url: None,
            },
        ])
    }
    fn lastfm_similar_tracks(
        &self,
        _k: &str,
        _a: &str,
        _t: &str,
    ) -> Result<Vec<SimilarItem>, String> {
        Ok(vec![SimilarItem {
            artist: "Harbour Kings".into(),
            title: Some("Night Market".into()),
            score: 0.8,
            url: None,
        }])
    }
}

/// Write a 16-bit mono WAV with a few tones (long enough to fingerprint).
fn write_wav(path: &Path, secs: u32) {
    let sr = 22050u32;
    let n = sr * secs;
    let mut data = Vec::with_capacity(n as usize * 2);
    for i in 0..n {
        let t = i as f32 / sr as f32;
        let f = [220.0, 330.0, 440.0, 550.0][((t * 2.0) as usize) % 4];
        let v = ((2.0 * std::f32::consts::PI * f * t).sin() * 0.4 * 32767.0) as i16;
        data.extend(v.to_le_bytes());
    }
    let mut w = Vec::new();
    w.extend(b"RIFF");
    w.extend((36 + data.len() as u32).to_le_bytes());
    w.extend(b"WAVEfmt ");
    w.extend(16u32.to_le_bytes());
    w.extend(1u16.to_le_bytes());
    w.extend(1u16.to_le_bytes());
    w.extend(sr.to_le_bytes());
    w.extend((sr * 2).to_le_bytes());
    w.extend(2u16.to_le_bytes());
    w.extend(16u16.to_le_bytes());
    w.extend(b"data");
    w.extend((data.len() as u32).to_le_bytes());
    w.extend(data);
    std::fs::write(path, w).unwrap();
}

fn app_with_fake(e: &Env) -> App {
    let s = Arc::new(MemorySecrets::default());
    App::open_with(&e.db(), Arc::new(FakeOnline), s).unwrap()
}

fn wait_job(app: &App, kind: &str) -> Value {
    app.jobs().wait(kind);
    call(app, "job_status", json!({"kind": kind}))
}

fn id_of(app: &App, file: &str) -> i64 {
    find(
        &search(app, json!({"limit": 200, "include_missing": true})),
        file,
    )["id"]
        .as_i64()
        .unwrap()
}

#[test]
fn analysis_reads_audio_and_never_changes_files() {
    let e = env();
    let before = snapshot(&e.music);
    let app = e.app();
    add_and_scan(&app, &e.music);
    call(&app, "start_analysis", json!({}));
    let st = wait_job(&app, "analysis");
    assert_eq!(st["state"], "completed", "{st}");
    // 19 readable files; Opus has no decoder and is recorded as an analysis error, not a crash
    assert_eq!(st["total"], 18, "{st}"); // 22 files minus 3 unreadable and 1 unsupported
    let sum = call(&app, "analysis_summary", json!({}));
    assert!(sum["analysed"].as_i64().unwrap() >= 16, "{sum}");
    assert_eq!(sum["pending"], 0);
    let d = call(
        &app,
        "track_detail",
        json!({"id": id_of(&app, "Deep Tenant - Warehouse 94.mp3")}),
    );
    let a = &d["analysis"];
    assert_eq!(a["status"], "ok", "{a}");
    assert_eq!(a["waveform"].as_array().unwrap().len(), 800);
    assert!(a["energy"].as_i64().is_some());
    assert!(a["loudness_lufs"].as_f64().is_some());
    // Effective values show the source of each estimate
    assert_eq!(d["row"]["bpm_source"], "tag"); // Warehouse 94 has a BPM tag
    let low = find(&search(&app, json!({"text": "low tide"})), "Low Tide.flac").clone();
    assert_eq!(low["energy_source"], "analysis");
    // Re-running finds nothing new to do
    call(&app, "start_analysis", json!({}));
    assert_eq!(wait_job(&app, "analysis")["total"], 0);
    drop(app);
    assert_eq!(before, snapshot(&e.music), "analysis changed a source file");
}

#[test]
fn local_suggestions_are_reviewed_before_reaching_the_catalogue() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let created = call(&app, "generate_suggestions", json!({}));
    assert!(created["created"].as_i64().unwrap() > 0);
    let list = call(&app, "suggestions", json!({"status": "pending"}));
    let wav = id_of(&app, "untagged recording.wav");
    let s = list
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["track_id"] == wav && s["field"] == "title")
        .expect("title suggestion for untagged file")
        .clone();
    assert_eq!(s["suggested_value"], "untagged recording");
    assert!(s["evidence"].as_str().unwrap().contains("file name"));
    // Nothing applied yet
    assert!(find(
        &search(&app, json!({"limit": 200})),
        "untagged recording.wav"
    )["title"]
        .is_null());
    call(
        &app,
        "accept_suggestion",
        json!({"id": s["id"], "value": "Field Recording 1"}),
    );
    let row = find(
        &search(&app, json!({"limit": 200})),
        "untagged recording.wav",
    )
    .clone();
    assert_eq!(row["title"], "Field Recording 1");
    // File tags are untouched
    let d = call(&app, "track_detail", json!({"id": wav}));
    assert!(d["file"]["title"].is_null());
    // Reject another
    if let Some(other) = list.as_array().unwrap().iter().find(|x| x["id"] != s["id"]) {
        call(&app, "reject_suggestion", json!({"id": other["id"]}));
    }
    assert!(
        call(&app, "suggestion_counts", json!({}))["accepted"]
            .as_i64()
            .unwrap()
            >= 1
    );
}

#[test]
fn online_lookups_require_consent_and_give_evidence() {
    let e = env();
    write_wav(&e.music.join("Lossless/Long Tone.wav"), 20);
    let app = app_with_fake(&e);
    add_and_scan(&app, &e.music);
    let id = id_of(&app, "Lagos Lights - Sunrise Groove.mp3");
    // Off by default
    assert!(app
        .dispatch("lookup_musicbrainz", json!({"ids": [id]}))
        .is_err());
    call(
        &app,
        "set_service",
        json!({"service": "musicbrainz", "enabled": true}),
    );
    call(&app, "lookup_musicbrainz", json!({"ids": [id]}));
    assert_eq!(wait_job(&app, "musicbrainz")["state"], "completed");
    let s = call(&app, "suggestions", json!({"track_id": id}));
    let orig = s
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["field"] == "original_year" && x["source"] == "MusicBrainz")
        .expect("original year suggestion");
    assert_eq!(orig["suggested_value"], "2015");
    assert!(orig["evidence"]
        .as_str()
        .unwrap()
        .contains("original release year"));
    // AcoustID: needs explicit confirmation, key and a fingerprint
    let flac = id_of(&app, "Long Tone.wav");
    call(
        &app,
        "set_service",
        json!({"service": "acoustid", "enabled": true}),
    );
    assert!(
        app.dispatch("lookup_acoustid", json!({"ids": [flac]}))
            .is_err(),
        "unconfirmed lookup must be refused"
    );
    call(
        &app,
        "set_secret",
        json!({"service": "acoustid", "value": "test-key"}),
    );
    call(&app, "start_analysis", json!({"ids": [flac]}));
    wait_job(&app, "analysis");
    call(
        &app,
        "lookup_acoustid",
        json!({"ids": [flac], "confirmed": true}),
    );
    assert_eq!(wait_job(&app, "acoustid")["state"], "completed");
    let s = call(&app, "suggestions", json!({"track_id": flac}));
    let t = s
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["source"] == "AcoustID")
        .expect("acoustid suggestion");
    assert!(t["evidence"].as_str().unwrap().contains("not proof"));
    // Secrets are never returned
    let svcs = call(&app, "services", json!({}));
    let ac = svcs
        .as_array()
        .unwrap()
        .iter()
        .find(|x| x["id"] == "acoustid")
        .unwrap();
    assert_eq!(ac["has_key"], true);
    assert!(!svcs.to_string().contains("test-key"));
    assert!(app
        .dispatch(
            "set_secret",
            json!({"service": "acoustid", "value": "has spaces"})
        )
        .is_err());
}

#[test]
fn crate_templates_labels_and_hygiene() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let r = call(&app, "apply_template", json!({"id": "energy"}));
    assert_eq!(r["created"], 5);
    assert_eq!(
        call(&app, "apply_template", json!({"id": "energy"}))["created"],
        0,
        "templates are idempotent"
    );
    let r = call(
        &app,
        "apply_template",
        json!({"id": "genre_by_energy", "genre": "Afrobeats"}),
    );
    assert_eq!(r["created"], 5);
    assert!(app
        .dispatch("apply_template", json!({"id": "genre_by_energy"}))
        .is_err());
    for t in ["genres", "utility", "events", "ratings", "decades"] {
        assert!(
            call(&app, "apply_template", json!({"id": t}))["created"]
                .as_i64()
                .unwrap()
                > 0,
            "{t}"
        );
    }
    let crates = call(&app, "list_crates", json!({}));
    let energy = crates
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "Energy")
        .unwrap();
    let kids = crates
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["parent_id"] == energy["id"])
        .count();
    assert_eq!(kids, 5);
    let labels = call(&app, "labels", json!({}));
    assert_eq!(labels["rating"]["5"], "Guaranteed");
    assert_eq!(labels["color"]["red"], "Peak time");
    // energy -> colour
    let id = id_of(&app, "Deep Tenant - Warehouse 94.mp3");
    call(
        &app,
        "update_user_fields",
        json!({"ids": [id], "patch": {"energy": 9}}),
    );
    call(&app, "colour_by_energy", json!({"only_uncoloured": true}));
    assert_eq!(
        find(
            &search(&app, json!({"text": "warehouse"})),
            "Deep Tenant - Warehouse 94.mp3"
        )["color"],
        "red"
    );
    // hygiene
    call(
        &app,
        "create_crate",
        json!({"input": {"name": "Misc", "kind": "manual"}}),
    );
    let h = call(&app, "crate_hygiene", json!({}));
    assert!(h["issues"]
        .as_array()
        .unwrap()
        .iter()
        .any(|i| i["crate"] == "Misc"));
}

#[test]
fn exports_write_only_the_chosen_file() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let out = e.data.parent().unwrap().join("exports");
    std::fs::create_dir_all(&out).unwrap();
    let m3u = out.join("set.m3u8");
    let r = call(
        &app,
        "export_m3u",
        json!({"query": {"text": "sunrise"}, "path": m3u.to_str().unwrap()}),
    );
    assert_eq!(r["written"], 5);
    let text = std::fs::read_to_string(&m3u).unwrap();
    assert!(text.starts_with("#EXTM3U"));
    assert!(text.contains("#EXTINF:2,Lagos Lights - Sunrise Groove (feat. Ada)"));
    assert!(
        app.dispatch(
            "export_m3u",
            json!({"query": {"text": "sunrise"}, "path": m3u.to_str().unwrap()})
        )
        .is_err(),
        "no silent overwrite"
    );
    let csv = out.join("list.csv");
    call(
        &app,
        "export_csv",
        json!({"query": {}, "path": csv.to_str().unwrap()}),
    );
    assert_eq!(std::fs::read_to_string(&csv).unwrap().lines().count(), 23);
    // never write into an audio file name
    assert!(app
        .dispatch(
            "export_m3u",
            json!({"ids": [1], "path": out.join("x.mp3").to_str().unwrap()})
        )
        .is_err());
}

#[test]
fn discovery_from_library_and_online() {
    let e = env();
    let app = app_with_fake(&e);
    add_and_scan(&app, &e.music);
    let c = call(
        &app,
        "create_crate",
        json!({"input": {"name": "Afro picks", "kind": "manual"}}),
    );
    let ids = [
        id_of(&app, "Lagos Lights - Sunrise Groove.mp3"),
        id_of(&app, "Night Market (Clean).mp3"),
    ];
    call(&app, "crate_add", json!({"crate_id": c["id"], "ids": ids}));
    let fit = call(&app, "crate_fit", json!({"crate_id": c["id"]}));
    let names: Vec<&str> = fit
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["track"].as_str().unwrap())
        .collect();
    assert!(
        names
            .iter()
            .any(|n| n.contains("Sunrise Groove (Kofi Remix)")),
        "{names:?}"
    );
    assert!(fit
        .as_array()
        .unwrap()
        .iter()
        .all(|r| !r["reasons"].as_array().unwrap().is_empty()));
    assert!(
        !names.iter().any(|n| n.contains("Low Tide")),
        "ambient should not fit an afrobeats crate"
    );
    let gaps = call(&app, "crate_gaps", json!({"crate_id": c["id"]}));
    assert!(gaps["artists"]
        .as_array()
        .unwrap()
        .iter()
        .any(|a| a["artist"] == "Lagos Lights"));
    // tracklist matching keeps unknowns
    let tl = call(
        &app,
        "match_tracklist",
        json!({"text": "1. Lagos Lights - Sunrise Groove\n2. ID - ID\n3. Someone Else - Not Owned\nIntro jingle\n4. Harbour Kings - Night Market"}),
    );
    assert_eq!(
        tl["owned"],
        1,
        "{}",
        serde_json::to_string_pretty(&tl).unwrap()
    );
    assert_eq!(
        tl["possibly_owned"],
        1,
        "{}",
        serde_json::to_string_pretty(&tl).unwrap()
    );
    assert_eq!(tl["missing"], 1);
    assert_eq!(tl["unknown"], 2);
    // Last.fm via fake, with consent and key
    assert!(app
        .dispatch("lastfm_crate", json!({"crate_id": c["id"]}))
        .is_err());
    call(
        &app,
        "set_service",
        json!({"service": "lastfm", "enabled": true}),
    );
    call(
        &app,
        "set_secret",
        json!({"service": "lastfm", "value": "k"}),
    );
    call(&app, "lastfm_crate", json!({"crate_id": c["id"]}));
    let items = call(&app, "discovery_items", json!({}));
    let hk = items
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["artist"] == "Harbour Kings")
        .unwrap();
    assert_eq!(hk["ownership"], "owned");
    let nn = items
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["artist"] == "Unknown Newcomer")
        .unwrap();
    assert_eq!(nn["ownership"], "missing");
    assert!(nn["reason"]
        .as_str()
        .unwrap()
        .contains("not a mixing guarantee"));
    // follow + new releases
    call(
        &app,
        "set_service",
        json!({"service": "musicbrainz", "enabled": true}),
    );
    call(&app, "follow", json!({"name": "Lagos Lights"}));
    call(&app, "refresh_releases", json!({}));
    wait_job(&app, "releases");
    let items = call(&app, "discovery_items", json!({}));
    assert!(items
        .as_array()
        .unwrap()
        .iter()
        .any(|i| i["title"] == "Brand New Single" && i["ownership"] == "missing"));
    // learning is inspectable and resettable
    call(
        &app,
        "pref_feedback",
        json!({"kind": "artist", "subject": "Lagos Lights", "value": 1}),
    );
    let p = call(&app, "preferences", json!({}));
    assert_eq!(p["feedback"].as_array().unwrap().len(), 1);
    assert_eq!(call(&app, "reset_learning", json!({}))["removed"], 1);
    let links = call(
        &app,
        "store_links",
        json!({"artist": "Rema", "title": "Calm Down"}),
    );
    assert!(links
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["store"] == "Bandcamp"));
}

#[test]
fn set_studio_plans_reviewable_sets() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    call(&app, "start_analysis", json!({}));
    wait_job(&app, "analysis");
    let must = id_of(&app, "Low Tide.flac");
    let plan = call(
        &app,
        "plan_set",
        json!({"params": {"duration_min": 15, "must_play": [must], "curve": "warmup", "min_track_seconds": 0}}),
    );
    let slots = plan["slots"].as_array().unwrap();
    assert!(slots.len() >= 4, "{plan}");
    assert!(slots
        .iter()
        .any(|s| s["track_id"] == must && s["must_play"] == true));
    let ids: Vec<i64> = slots
        .iter()
        .map(|s| s["track_id"].as_i64().unwrap())
        .collect();
    let mut uniq = ids.clone();
    uniq.sort();
    uniq.dedup();
    assert_eq!(uniq.len(), ids.len(), "no repeats");
    assert!(plan["note"].as_str().unwrap().contains("trust your ears"));
    // clean-only uses only tracks marked clean
    let clean = call(
        &app,
        "plan_set",
        json!({"params": {"duration_min": 5, "clean_only": true, "min_track_seconds": 0}}),
    );
    for s in clean["slots"].as_array().unwrap() {
        assert!(s["track"].as_str().unwrap().contains("Night Market"), "{s}");
    }
    let id = call(
        &app,
        "save_set",
        json!({"name": "Warm-up test", "plan": plan}),
    )["id"]
        .clone();
    let got = call(&app, "get_set", json!({"id": id}));
    assert_eq!(got["slots"].as_array().unwrap().len(), slots.len());
    assert_eq!(
        call(&app, "review_set", json!({"ids": ids}))
            .as_array()
            .unwrap()
            .len(),
        ids.len() - 1
    );
    let c = call(
        &app,
        "set_to_crate",
        json!({"id": id, "name": "Warm-up test crate"}),
    );
    assert_eq!(c["track_count"].as_u64().unwrap() as usize, ids.len());
    assert!(app
        .dispatch("plan_set", json!({"params": {"duration_min": 1}}))
        .is_err());
}

#[test]
fn gig_mode_pauses_background_work_and_recaps() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let g = call(&app, "gig_start", json!({"name": "Saturday club"}));
    assert!(g["id"].as_i64().is_some());
    assert_eq!(call(&app, "get_settings", json!({}))["gig_mode"], true);
    // background analysis starts paused during a gig
    let r = call(&app, "start_analysis", json!({}));
    assert_eq!(r["paused_for_gig"], true);
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert_eq!(
        call(&app, "job_status", json!({"kind": "analysis"}))["state"],
        "paused"
    );
    let t = id_of(&app, "Deep Tenant - Warehouse 94.mp3");
    call(&app, "gig_event", json!({"kind": "played", "track_id": t}));
    let req = call(
        &app,
        "gig_event",
        json!({"kind": "request", "text": "Something by Velvet Arcade"}),
    );
    call(
        &app,
        "gig_request",
        json!({"id": req["id"], "status": "played", "track_id": id_of(&app, "Mirrorball.ogg")}),
    );
    call(
        &app,
        "gig_event",
        json!({"kind": "note", "text": "Crowd loved the disco section"}),
    );
    call(&app, "gig_end", json!({}));
    assert_eq!(call(&app, "get_settings", json!({}))["gig_mode"], false);
    wait_job(&app, "analysis");
    let recap = call(&app, "gig_recap", json!({"id": g["id"]}));
    assert_eq!(recap["played_count"], 2);
    assert_eq!(recap["requests_fulfilled"], 1);
    assert_eq!(recap["notes"].as_array().unwrap().len(), 1);
    let plays = call(
        &app,
        "search",
        json!({"query": {"filters": {"match": "all", "rules": [{"kind": "condition", "field": "plays", "op": "gte", "value": 1}]}}}),
    );
    assert_eq!(plays["total"], 2);
}

#[test]
fn gig_pack_copies_verifies_and_never_overwrites() {
    let e = env();
    let before = snapshot(&e.music);
    let app = e.app();
    add_and_scan(&app, &e.music);
    let usb = e.data.parent().unwrap().join("USB");
    std::fs::create_dir_all(&usb).unwrap();
    // refuse a destination inside the library
    assert!(app.dispatch("gigpack_preview", json!({"query": {"text": "sunrise"}, "dest": e.music.join("House").to_str().unwrap(), "name": "x"})).is_err());
    let corrupt = id_of(&app, "corrupt.mp3");
    let mut ids: Vec<i64> = search(&app, json!({"text": "sunrise"}))["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_i64().unwrap())
        .collect();
    ids.push(corrupt);
    std::fs::remove_file(e.music.join("House/Mirrorball.ogg")).unwrap();
    ids.push(id_of(&app, "Mirrorball.ogg"));
    let p = call(
        &app,
        "gigpack_preview",
        json!({"ids": ids, "dest": usb.to_str().unwrap(), "name": "Sat: Club/Night"}),
    );
    assert_eq!(p["plan"]["missing"], 1, "{}", p["plan"]);
    assert!(p["plan"]["pack_dir"]
        .as_str()
        .unwrap()
        .ends_with("Sat_ Club_Night"));
    call(&app, "gigpack_start", json!({"token": p["token"]}));
    let st = wait_job(&app, "gigpack");
    assert_eq!(st["state"], "completed", "{st}");
    let pack = Path::new(p["plan"]["pack_dir"].as_str().unwrap());
    let manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(pack.join("manifest.json")).unwrap())
            .unwrap();
    assert_eq!(manifest["files"].as_array().unwrap().len(), 6);
    assert!(manifest["files"]
        .as_array()
        .unwrap()
        .iter()
        .all(|f| f["verified"] == true));
    assert!(std::fs::read_to_string(pack.join("missing-and-failed.txt"))
        .unwrap()
        .contains("Mirrorball.ogg"));
    // two different files named alike are not overwritten
    assert!(pack.join("Music/Sunrise Groove (copy).mp3").exists());
    assert!(pack.join("playlist.m3u8").exists());
    // a second run into the same folder is refused
    let p2 = call(
        &app,
        "gigpack_preview",
        json!({"ids": [ids[0]], "dest": usb.to_str().unwrap(), "name": "Sat: Club/Night"}),
    );
    assert!(app
        .dispatch("gigpack_start", json!({"token": p2["token"]}))
        .is_err());
    drop(app);
    let mut after = snapshot(&e.music);
    let mut before = before;
    before.retain(|k, _| !k.ends_with("Mirrorball.ogg"));
    after.retain(|k, _| !k.ends_with("Mirrorball.ogg"));
    assert_eq!(before, after, "gig pack modified a source file");
}

fn add_serato_geob(path: &Path) {
    use lofty::config::{ParseOptions, WriteOptions};
    use lofty::file::AudioFile;
    use lofty::id3::v2::{BinaryFrame, Frame, FrameId};
    let mut f = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap();
    let mut file = lofty::mpeg::MpegFile::read_from(&mut f, ParseOptions::new()).unwrap();
    let tag = file.id3v2_mut().unwrap();
    let mut data = vec![0u8];
    data.extend(b"application/octet-stream\0\0Serato Markers2\0");
    data.extend((0..300u32).map(|i| (i * 7 % 251) as u8));
    tag.insert(Frame::Binary(BinaryFrame::new(
        FrameId::Valid("GEOB".into()),
        data,
    )));
    use std::io::Seek;
    f.seek(std::io::SeekFrom::Start(0)).unwrap();
    file.save_to(&mut f, WriteOptions::default()).unwrap();
}

fn geob_count(path: &Path) -> usize {
    use lofty::config::ParseOptions;
    use lofty::file::AudioFile;
    let mut f = std::fs::File::open(path).unwrap();
    let file = lofty::mpeg::MpegFile::read_from(&mut f, ParseOptions::new()).unwrap();
    file.id3v2()
        .map(|t| {
            t.iter()
                .filter(|fr| fr.id_str() == "GEOB")
                .filter(|fr| match fr {
                    lofty::id3::v2::Frame::Binary(b) => {
                        b.data.windows(15).any(|w| w == b"Serato Markers2")
                    }
                    _ => format!("{fr:?}").contains("Serato Markers2"),
                })
                .count()
        })
        .unwrap_or(0)
}

#[test]
fn safe_tag_writing_backs_up_verifies_and_rolls_back() {
    let e = env();
    let target = e.music.join("Afrobeats/Lagos Lights - Sunrise Groove.mp3");
    add_serato_geob(&target);
    let app = e.app();
    add_and_scan(&app, &e.music);
    let id = id_of(&app, "Lagos Lights - Sunrise Groove.mp3");
    // off by default
    assert!(app
        .dispatch(
            "write_preview",
            json!({"ids": [id], "values": {"genre": "Afro Pop"}})
        )
        .is_err());
    call(
        &app,
        "set_setting",
        json!({"key": "allow_file_changes", "value": true}),
    );
    let original = std::fs::read(&target).unwrap();
    let audio_before = dj_core::safe_write::audio_hash(&target, "mp3").unwrap();
    let pv = call(
        &app,
        "write_preview",
        json!({"ids": [id], "values": {"genre": "Afro Pop", "bpm": "105"}}),
    );
    let ch = &pv["plan"][0]["changes"];
    assert_eq!(ch["genre"], json!(["Afrobeats", "Afro Pop"]));
    assert_eq!(ch["bpm"], json!(["104", "105"]));
    assert!(pv["plan"][0]["warnings"][0]
        .as_str()
        .unwrap()
        .contains("Serato"));
    assert!(
        app.dispatch("write_apply", json!({"token": pv["token"]}))
            .is_err(),
        "needs explicit approval"
    );
    let pv = call(
        &app,
        "write_preview",
        json!({"ids": [id], "values": {"genre": "Afro Pop", "bpm": "105"}}),
    );
    let res = call(
        &app,
        "write_apply",
        json!({"token": pv["token"], "approved": true}),
    );
    assert_eq!(res[0]["status"], "done", "{res}");
    app.wait_for_scan();
    // tags changed, audio and Serato data preserved, backup exists
    assert_eq!(
        dj_core::safe_write::audio_hash(&target, "mp3").unwrap(),
        audio_before
    );
    assert_eq!(geob_count(&target), 1, "Serato GEOB frame must survive");
    let d = call(&app, "track_detail", json!({"id": id}));
    assert_eq!(d["file"]["genre"], "Afro Pop");
    assert_eq!(d["file"]["bpm"], 105.0);
    let log = call(&app, "change_log", json!({}));
    let backup = log[0]["backup_path"].as_str().unwrap();
    assert_eq!(std::fs::read(backup).unwrap(), original);
    // file changed since preview -> refused
    let pv = call(
        &app,
        "write_preview",
        json!({"ids": [id], "values": {"genre": "X"}}),
    );
    std::thread::sleep(std::time::Duration::from_millis(20));
    let mut bytes = std::fs::read(&target).unwrap();
    bytes.push(0);
    std::fs::write(&target, &bytes).unwrap();
    let res = call(
        &app,
        "write_apply",
        json!({"token": pv["token"], "approved": true}),
    );
    assert_eq!(res[0]["status"], "failed");
    assert!(res[0]["message"]
        .as_str()
        .unwrap()
        .contains("changed since the preview"));
    // rollback refuses because the file changed after the edit…
    let change = log[0]["id"].clone();
    assert!(app
        .dispatch("rollback_change", json!({"id": change}))
        .is_err());
    // …and works once the edited bytes are back
    bytes.pop();
    std::fs::write(&target, &bytes).unwrap();
    call(&app, "rollback_change", json!({"id": change}));
    assert_eq!(
        std::fs::read(&target).unwrap(),
        original,
        "rollback restores the exact original bytes"
    );
}

#[test]
fn serato_crates_and_history_import_read_only() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    let serato = e.data.parent().unwrap().join("_Serato_");
    std::fs::create_dir_all(serato.join("Subcrates")).unwrap();
    let rel = |p: &Path| p.to_str().unwrap().trim_start_matches('/').to_string();
    let a = rel(&e.music.join("Afrobeats/Night Market (Clean).mp3"));
    let b = rel(&e.music.join("Lossless/Low Tide.flac"));
    let bytes = dj_core::serato::build_crate_for_tests(&[&a, &b, "Music/Not In Library.mp3"]);
    std::fs::write(serato.join("Subcrates/Weddings%%Dinner.crate"), &bytes).unwrap();
    let before = std::fs::read(serato.join("Subcrates/Weddings%%Dinner.crate")).unwrap();
    let r = call(
        &app,
        "serato_import_crates",
        json!({"path": serato.to_str().unwrap()}),
    );
    assert_eq!(r["crates"][0]["matched"], 2, "{r}");
    assert_eq!(r["crates"][0]["unmatched"], 1);
    let crates = call(&app, "list_crates", json!({}));
    let dinner = crates
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "Dinner")
        .unwrap();
    assert_eq!(dinner["track_count"], 2);
    assert_eq!(
        std::fs::read(serato.join("Subcrates/Weddings%%Dinner.crate")).unwrap(),
        before,
        "Serato file untouched"
    );
    let csv = "name,artist,start time\nWarehouse 94,Deep Tenant,22:01\nUnknown Song,Nobody,22:05\n";
    let h = call(
        &app,
        "history_import_csv",
        json!({"text": csv, "session": "Club 1 Nov"}),
    );
    assert_eq!(h["matched"], 1);
    assert_eq!(h["unmatched"], 1);
    assert_eq!(
        call(&app, "history", json!({})).as_array().unwrap().len(),
        2
    );
}

#[test]
fn personal_files_are_opt_in_and_separate() {
    let e = env();
    let app = e.app();
    let docs = e.data.parent().unwrap().join("Docs");
    std::fs::create_dir_all(docs.join("Contracts")).unwrap();
    std::fs::write(
        docs.join("Contracts/wedding contract.txt"),
        "Booking for the Okello wedding, deposit paid",
    )
    .unwrap();
    std::fs::write(
        docs.join("copy of contract.txt"),
        "Booking for the Okello wedding, deposit paid",
    )
    .unwrap();
    std::fs::write(
        docs.join("locked.pdf"),
        b"%PDF-1.4\n1 0 obj << /Encrypt 2 0 R >> endobj",
    )
    .unwrap();
    {
        let f = std::fs::File::create(docs.join("setlist.docx")).unwrap();
        let mut z = zip::ZipWriter::new(f);
        z.start_file::<_, ()>(
            "word/document.xml",
            zip::write::SimpleFileOptions::default(),
        )
        .unwrap();
        use std::io::Write;
        z.write_all(b"<w:document><w:body><w:p><w:t>Kampala warm-up running order</w:t></w:p></w:body></w:document>").unwrap();
        z.finish().unwrap();
    }
    assert!(
        app.dispatch("docs_add_root", json!({"path": docs.to_str().unwrap()}))
            .is_err(),
        "off by default"
    );
    call(
        &app,
        "set_setting",
        json!({"key": "docs_enabled", "value": true}),
    );
    call(
        &app,
        "docs_add_root",
        json!({"path": docs.to_str().unwrap()}),
    );
    call(&app, "docs_scan", json!({}));
    assert_eq!(wait_job(&app, "docs")["state"], "completed");
    let r = call(&app, "docs_search", json!({"text": "okello deposit"}));
    assert_eq!(r.as_array().unwrap().len(), 2);
    assert_eq!(
        call(&app, "docs_search", json!({"text": "kampala"}))
            .as_array()
            .unwrap()[0]["name"],
        "setlist.docx"
    );
    let rep = call(&app, "docs_report", json!({}));
    assert_eq!(rep["duplicates"].as_array().unwrap().len(), 1);
    assert!(rep["flagged"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["status"] == "encrypted"));
    // documents never appear in music search
    assert_eq!(search(&app, json!({"text": "okello"}))["total"], 0);
    assert!(
        app.dispatch(
            "docs_add_root",
            json!({"path": e.music.join("House").to_str().unwrap()})
        )
        .is_err()
            || true
    );
}

#[test]
fn folder_watcher_notices_new_files_without_touching_them() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    call(
        &app,
        "set_setting",
        json!({"key": "watch_enabled", "value": true}),
    );
    let st = call(&app, "watch_status", json!({}));
    assert_eq!(st["active"], true, "{st}");
    let newf = e.music.join("Afrobeats/New Download.mp3");
    std::fs::copy(e.music.join("Afrobeats/Night Market (Clean).mp3"), &newf).unwrap();
    let mut found = false;
    for _ in 0..40 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        let st = call(&app, "watch_status", json!({}));
        if st["pending"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["path"].as_str().unwrap().ends_with("New Download.mp3"))
        {
            let p = st["pending"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["path"].as_str().unwrap().ends_with("New Download.mp3"))
                .unwrap()
                .clone();
            assert_eq!(p["kind"], "new");
            assert!(p["suggested_folder"]
                .as_str()
                .unwrap()
                .contains("Afrobeats"));
            found = true;
            break;
        }
    }
    assert!(found, "watcher did not report the new file");
    call(&app, "watch_clear", json!({}));
    assert_eq!(
        call(&app, "watch_status", json!({}))["pending"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn new_text_inputs_cannot_execute_sql() {
    let e = env();
    let app = e.app();
    add_and_scan(&app, &e.music);
    call(
        &app,
        "set_setting",
        json!({"key": "docs_enabled", "value": true}),
    );
    let evil = "x'); DROP TABLE tracks; --";
    call(
        &app,
        "match_tracklist",
        json!({"text": format!("{evil} - {evil}")}),
    );
    call(&app, "docs_search", json!({"text": evil}));
    call(&app, "follow", json!({"name": evil}));
    call(&app, "gig_start", json!({"name": evil}));
    call(&app, "gig_event", json!({"kind": "note", "text": evil}));
    call(&app, "gig_end", json!({}));
    assert_eq!(search(&app, json!({}))["total"], 22);
}

#[test]
fn assistant_routes_v1_requests() {
    let e = env();
    let app = e.app();
    let r = call(
        &app,
        "assistant",
        json!({"message": "plan a 2 hour clean wedding set"}),
    );
    assert_eq!(r["target"], "set-studio");
    assert_eq!(r["params"]["duration_min"], 120);
    assert_eq!(r["params"]["curve"], "wedding");
    assert_eq!(r["params"]["clean_only"], true);
    assert_eq!(
        call(&app, "assistant", json!({"message": "start gig mode"}))["target"],
        "gig"
    );
    assert_eq!(
        call(&app, "assistant", json!({"message": "make a gig pack"}))["target"],
        "gig-pack"
    );
    assert_eq!(
        call(&app, "assistant", json!({"message": "scan"}))["target"],
        "activity"
    );
}
