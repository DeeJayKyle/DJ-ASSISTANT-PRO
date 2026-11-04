//! v1.0 commands: analysis, suggestions, online services, templates, export,
//! discovery, Set Studio, gig mode, gig packs, safe tag writing, Serato
//! import, personal files and folder watching.
use crate::api::{arg, lock, App};
use crate::db::{self, now_ms};
use crate::error::{invalid, Error, Result};
use crate::library::TrackQuery;
use crate::online::SERVICES;
use crate::{
    analysis_store, discovery, docs, export, gig, gigpack, quick, safe_write, serato, sets,
    suggest, templates, watcher,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn token() -> String {
    crate::scanner::new_uid("token")
}

impl App {
    pub(crate) fn restart_watcher(&self) {
        let conn = lock(&self.conn);
        let mut w = lock(&self.watcher);
        *w = None;
        if watcher::enabled(&conn).unwrap_or(false) {
            *w = watcher::start(&self.db_path, &conn).ok().flatten();
        }
    }

    fn gig_mode(&self) -> bool {
        gig::active(&lock(&self.conn)).unwrap_or(false)
    }

    /// Resolve a list of tracks from `ids`, `crate_id`, `set_id` or `query`.
    fn resolve_ids(&self, a: &Value) -> Result<Vec<i64>> {
        let conn = lock(&self.conn);
        if let Some(ids) = arg::<Option<Vec<i64>>>(a, "ids")? {
            return Ok(ids);
        }
        if let Some(cid) = arg::<Option<i64>>(a, "crate_id")? {
            return crate::library::track_ids(
                &conn,
                &TrackQuery {
                    crate_id: Some(cid),
                    sort: Some("artist".into()),
                    ..Default::default()
                },
                100_000,
            );
        }
        if let Some(sid) = arg::<Option<i64>>(a, "set_id")? {
            return sets::track_ids(&conn, sid);
        }
        if let Some(q) = arg::<Option<TrackQuery>>(a, "query")? {
            return crate::library::track_ids(&conn, &q, 100_000);
        }
        invalid("no tracks given")
    }

    fn start_job<F>(&self, kind: &str, f: F) -> Result<Value>
    where
        F: FnOnce(&crate::scanner::ScanControl, &crate::jobs::Progress) -> Result<()>
            + Send
            + 'static,
    {
        let paused = self.gig_mode() && kind != "gigpack";
        self.jobs.start(kind, paused, f)?;
        Ok(json!({"started": true, "paused_for_gig": paused}))
    }

    pub(crate) fn dispatch_v1(&self, cmd: &str, a: &Value) -> Result<Value> {
        Ok(match cmd {
            // ---------- background jobs ----------
            "jobs" => json!(self.jobs.all()),
            "job_status" => json!(self.jobs.status(&arg::<String>(a, "kind")?)),
            "cancel_job" => {
                self.jobs.cancel(&arg::<String>(a, "kind")?);
                json!({"ok": true})
            }
            "pause_job" => {
                self.jobs
                    .pause(&arg::<String>(a, "kind")?, arg(a, "paused")?);
                json!({"ok": true})
            }

            // ---------- analysis ----------
            "start_analysis" => {
                let only = arg::<Option<Vec<i64>>>(a, "ids")?;
                let force = arg::<Option<bool>>(a, "force")?.unwrap_or(false);
                let db = self.db_path.clone();
                self.start_job("analysis", move |ctl, p| {
                    analysis_store::run_job(&db, only, force, ctl, p)
                })?
            }
            "analysis_summary" => {
                let conn = lock(&self.conn);
                let (done, errors): (i64, i64) = conn.query_row(
                    "SELECT SUM(status='ok'), SUM(status='error') FROM analysis",
                    [],
                    |r| {
                        Ok((
                            r.get::<_, Option<i64>>(0)?.unwrap_or(0),
                            r.get::<_, Option<i64>>(1)?.unwrap_or(0),
                        ))
                    },
                )?;
                let pending = analysis_store::pending_ids(&conn, None, false)?.len();
                json!({"analysed": done, "errors": errors, "pending": pending, "method": crate::analysis::METHOD, "version": crate::analysis::VERSION})
            }

            // ---------- suggestions ----------
            "generate_suggestions" => {
                json!({"created": suggest::generate_local(&lock(&self.conn))?})
            }
            "suggestions" => json!(suggest::list(
                &lock(&self.conn),
                arg::<Option<String>>(a, "status")?.as_deref(),
                arg(a, "track_id")?,
                2000
            )?),
            "suggestion_counts" => suggest::counts(&lock(&self.conn))?,
            "accept_suggestion" => {
                suggest::accept(
                    &lock(&self.conn),
                    arg(a, "id")?,
                    arg::<Option<String>>(a, "value")?.as_deref(),
                )?;
                json!({"ok": true})
            }
            "reject_suggestion" => {
                suggest::reject(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "reset_suggestion" => {
                suggest::reset(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "accept_suggestions_bulk" => {
                let min: f64 = arg::<Option<f64>>(a, "min_confidence")?.unwrap_or(0.8);
                let source: Option<String> = arg(a, "source")?;
                json!({"accepted": suggest::accept_bulk(&lock(&self.conn), min, source.as_deref())?})
            }
            "lookup_musicbrainz" => {
                let ids = self.resolve_ids(a)?;
                suggest::require_service(&lock(&self.conn), "musicbrainz")?;
                let (db, online) = (self.db_path.clone(), self.online.clone());
                self.start_job("musicbrainz", move |ctl, p| {
                    let conn = db::open(&db)?;
                    suggest::musicbrainz_lookup(&conn, online.as_ref(), &ids, ctl, p)
                })?
            }
            "lookup_acoustid" => {
                if !arg::<Option<bool>>(a, "confirmed")?.unwrap_or(false) {
                    return invalid("Each AcoustID lookup must be confirmed: an audio fingerprint (not the audio) will be sent.");
                }
                let ids = self.resolve_ids(a)?;
                suggest::require_service(&lock(&self.conn), "acoustid")?;
                let (db, online, secrets) = (
                    self.db_path.clone(),
                    self.online.clone(),
                    self.secrets.clone(),
                );
                self.start_job("acoustid", move |ctl, p| {
                    let conn = db::open(&db)?;
                    suggest::acoustid_lookup(&conn, online.as_ref(), secrets.as_ref(), &ids, ctl, p)
                })?
            }

            // ---------- AI assistant ----------
            "ai_status" => crate::agent::status(self)?,
            "ai_chat" => json!(crate::agent::chat(
                self,
                arg::<Option<String>>(a, "conversation_id")?,
                &arg::<String>(a, "message")?
            )?),
            "ai_confirm" => json!(crate::agent::confirm(
                self,
                &arg::<String>(a, "conversation_id")?,
                &arg::<std::collections::HashMap<String, bool>>(a, "decisions")?
            )?),
            "ai_reset" => {
                crate::agent::reset(self, &arg::<String>(a, "conversation_id")?);
                json!({"ok": true})
            }
            "ai_local_setup" => {
                let cfg = crate::agent::config(self)?;
                let probe = self.online.llm_local_probe(&cfg.local_url);
                let has_model = probe
                    .models
                    .iter()
                    .any(|m| m == &cfg.model || m.trim_end_matches(":latest") == cfg.model);
                json!({"probe": probe, "model": cfg.model, "has_model": has_model, "local_url": cfg.local_url,
                    "recommended": crate::agent::LOCAL_MODELS.iter().map(|(id, size, note)| json!({"id": id, "size": size, "note": note})).collect::<Vec<_>>(),
                    "download": self.jobs.status("ai_model")})
            }
            "ai_local_start" => {
                self.online.llm_local_start().map_err(Error::Invalid)?;
                // Give the server a moment to come up.
                let url = crate::agent::config(self)?.local_url;
                for _ in 0..40 {
                    if self.online.llm_local_probe(&url).running {
                        return Ok(json!({"running": true}));
                    }
                    std::thread::sleep(std::time::Duration::from_millis(250));
                }
                json!({"running": false})
            }
            "ai_local_pull" => {
                let cfg = crate::agent::config(self)?;
                let model: String = arg::<Option<String>>(a, "model")?.unwrap_or(cfg.model.clone());
                if model.is_empty()
                    || model.len() > 100
                    || !model
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || ":._-/".contains(c))
                {
                    return invalid("that doesn't look like a model name");
                }
                let online = self.online.clone();
                let url = cfg.local_url.clone();
                // Not paused by gig mode: it only talks to this computer's model server.
                self.jobs.start("ai_model", false, move |ctl, p| {
                    crate::jobs::message(p, format!("Downloading {model}…"));
                    let mut last = std::time::Instant::now() - std::time::Duration::from_secs(1);
                    let r = online.llm_local_pull(&url, &model, &mut |done, total, status| {
                        if last.elapsed() >= std::time::Duration::from_millis(250)
                            || status == "success"
                        {
                            last = std::time::Instant::now();
                            let mut s = crate::jobs::lock(p);
                            s.done = done;
                            s.total = total;
                            s.message = Some(match status {
                                "success" => format!("{model} is ready"),
                                st if st.starts_with("pulling") && total > 0 => {
                                    format!("Downloading {model}")
                                }
                                st => format!("{model}: {st}"),
                            });
                        }
                        !crate::jobs::wait_or_cancelled(ctl)
                    });
                    r.map_err(Error::Invalid)
                })?;
                json!({"started": true})
            }
            "ai_list_models" => {
                // the models an online AI service offers with the saved key
                let cfg = crate::agent::config(self)?;
                if cfg.base_url.is_empty() {
                    return invalid("choose an online AI service first");
                }
                json!(self.online.llm_list_models(&cfg).map_err(Error::Invalid)?)
            }
            "ai_local_models" => {
                let url = crate::agent::config(self)?.local_url;
                json!(self.online.llm_local_models(&url).map_err(Error::Invalid)?)
            }

            // ---------- online services & credentials ----------
            "services" => {
                let conn = lock(&self.conn);
                let mut out = vec![];
                for (id, name, provides, sends) in SERVICES {
                    let enabled = if *id == "updates" {
                        db::get_setting(&conn, "auto_update")?
                            .map(|v| v == "1")
                            .unwrap_or(true)
                    } else {
                        suggest::service_enabled(&conn, id)?
                    };
                    let provider = db::get_setting(&conn, "ai_provider")?;
                    let enabled = if *id == "anthropic" {
                        // the online AI assistant, whichever service it uses
                        matches!(provider.as_deref(), Some(p) if p != "off" && p != "local")
                    } else {
                        enabled
                    };
                    let needs_key = ["acoustid", "lastfm", "anthropic"].contains(id);
                    out.push(json!({"id": id, "name": name, "provides": provides, "sends": sends, "enabled": enabled, "needs_key": needs_key, "has_key": needs_key && self.secrets.get(id).is_some()}));
                }
                json!(out)
            }
            "set_service" => {
                let svc: String = arg(a, "service")?;
                let on: bool = arg(a, "enabled")?;
                if !SERVICES.iter().any(|s| s.0 == svc) {
                    return invalid("unknown service");
                }
                if svc == "anthropic" {
                    let conn = lock(&self.conn);
                    let last = db::get_setting(&conn, "ai_online_last")?
                        .filter(|p| crate::agent::is_provider(p))
                        .unwrap_or_else(|| "claude".into());
                    db::set_setting(&conn, "ai_provider", if on { &last } else { "off" })?;
                    return Ok(json!({"ok": true}));
                }
                let key = if svc == "updates" {
                    "auto_update".to_string()
                } else {
                    format!("svc_{svc}")
                };
                db::set_setting(&lock(&self.conn), &key, if on { "1" } else { "0" })?;
                json!({"ok": true})
            }
            "set_secret" => {
                let svc: String = arg(a, "service")?;
                let v: String = arg(a, "value")?;
                let ai_key = svc
                    .strip_prefix("ai_")
                    .is_some_and(|id| crate::agent::ai_service(id).is_some());
                if !["acoustid", "lastfm", "anthropic"].contains(&svc.as_str()) && !ai_key {
                    return invalid("unknown service");
                }
                if svc == "anthropic" && !v.trim().starts_with("sk-ant-") {
                    return invalid("Anthropic API keys start with sk-ant-");
                }
                let v = v.trim();
                if v.is_empty()
                    || v.len() > 200
                    || v.chars().any(|c| c.is_whitespace() || c.is_control())
                {
                    return invalid("that does not look like an API key");
                }
                self.secrets.set(&svc, v).map_err(Error::Invalid)?;
                json!({"ok": true})
            }
            "delete_secret" => {
                self.secrets
                    .delete(&arg::<String>(a, "service")?)
                    .map_err(Error::Invalid)?;
                json!({"ok": true})
            }

            // ---------- templates, labels, hygiene ----------
            "crate_templates" => json!(templates::list()),
            "apply_template" => templates::apply(
                &lock(&self.conn),
                &arg::<String>(a, "id")?,
                arg::<Option<String>>(a, "genre")?.as_deref(),
            )?,
            "labels" => templates::labels(&lock(&self.conn))?,
            "set_labels" => {
                templates::set_labels(&lock(&self.conn), &arg::<Value>(a, "labels")?)?;
                json!({"ok": true})
            }
            "colour_by_energy" => {
                json!({"updated": templates::colour_by_energy(&lock(&self.conn), arg::<Option<bool>>(a, "only_uncoloured")?.unwrap_or(true))?})
            }
            "crate_hygiene" => templates::hygiene(&lock(&self.conn))?,
            "move_crate" => {
                let conn = lock(&self.conn);
                let id: i64 = arg(a, "id")?;
                let parent: Option<i64> = arg(a, "parent_id")?;
                if parent == Some(id) {
                    return invalid("a crate cannot be inside itself");
                }
                // refuse cycles
                let mut cur = parent;
                while let Some(p) = cur {
                    if p == id {
                        return invalid("that would put a crate inside its own sub-crate");
                    }
                    cur = conn
                        .query_row(
                            "SELECT parent_id FROM crates WHERE id=?1",
                            rusqlite::params![p],
                            |r| r.get(0),
                        )
                        .unwrap_or(None);
                }
                conn.execute(
                    "UPDATE crates SET parent_id=?2, updated_at=?3 WHERE id=?1",
                    rusqlite::params![id, parent, now_ms()],
                )?;
                json!({"ok": true})
            }

            // ---------- export ----------
            "export_m3u" | "export_csv" => {
                let ids = self.resolve_ids(a)?;
                let path = PathBuf::from(arg::<String>(a, "path")?);
                let overwrite = arg::<Option<bool>>(a, "overwrite")?.unwrap_or(false);
                let conn = lock(&self.conn);
                let n = if cmd == "export_m3u" {
                    export::write_m3u(&conn, &ids, &path, overwrite)?
                } else {
                    export::write_csv(&conn, &ids, &path, overwrite)?
                };
                json!({"written": n, "path": path})
            }

            // ---------- discovery ----------
            "crate_fit" => json!(discovery::crate_fit(
                &lock(&self.conn),
                arg(a, "crate_id")?,
                60
            )?),
            "crate_gaps" => discovery::gaps(&lock(&self.conn), arg(a, "crate_id")?)?,
            "overplayed" => json!(discovery::overplayed(&lock(&self.conn), 20)?),
            "match_tracklist" => {
                discovery::match_tracklist(&lock(&self.conn), &arg::<String>(a, "text")?)?
            }
            "preferences" => discovery::preferences(&lock(&self.conn))?,
            "pref_feedback" => {
                discovery::feedback(
                    &lock(&self.conn),
                    &arg::<String>(a, "kind")?,
                    &arg::<String>(a, "subject")?,
                    arg(a, "value")?,
                )?;
                json!({"ok": true})
            }
            "reset_learning" => json!({"removed": discovery::reset_learning(&lock(&self.conn))?}),
            "lastfm_crate" => {
                json!({"found": discovery::lastfm_for_crate(&lock(&self.conn), self.online.as_ref(), self.secrets.as_ref(), arg(a, "crate_id")?)?})
            }
            "lastfm_track" => {
                json!({"found": discovery::lastfm_for_track(&lock(&self.conn), self.online.as_ref(), self.secrets.as_ref(), arg(a, "track_id")?)?})
            }
            "follow" => {
                discovery::follow(
                    &lock(&self.conn),
                    &arg::<Option<String>>(a, "kind")?.unwrap_or_else(|| "artist".into()),
                    &arg::<String>(a, "name")?,
                )?;
                json!({"ok": true})
            }
            "unfollow" => {
                discovery::unfollow(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "followed" => json!(discovery::followed(&lock(&self.conn))?),
            "refresh_releases" => {
                suggest::require_service(&lock(&self.conn), "musicbrainz")?;
                let (db, online) = (self.db_path.clone(), self.online.clone());
                self.start_job("releases", move |_ctl, p| {
                    let conn = db::open(&db)?;
                    let n = discovery::refresh_releases(&conn, online.as_ref())?;
                    lock(p).result = Some(json!({"found": n}));
                    Ok(())
                })?
            }
            "discovery_items" => json!(discovery::items(
                &lock(&self.conn),
                arg::<Option<String>>(a, "status")?.as_deref()
            )?),
            "discovery_status" => {
                discovery::set_item_status(
                    &lock(&self.conn),
                    arg(a, "id")?,
                    &arg::<String>(a, "status")?,
                )?;
                json!({"ok": true})
            }
            "store_links" => json!(discovery::store_links(
                &arg::<String>(a, "artist")?,
                &arg::<String>(a, "title")?
            )),

            // ---------- Set Studio ----------
            "plan_set" => sets::plan(&lock(&self.conn), &arg::<sets::SetParams>(a, "params")?)?,
            "save_set" => {
                json!({"id": sets::save(&lock(&self.conn), arg(a, "id")?, &arg::<String>(a, "name")?, &arg::<Value>(a, "plan")?)?})
            }
            "list_sets" => json!(sets::list(&lock(&self.conn))?),
            "get_set" => sets::get(&lock(&self.conn), arg(a, "id")?)?,
            "delete_set" => {
                sets::delete(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "review_set" => json!(sets::review(
                &lock(&self.conn),
                &arg::<Vec<i64>>(a, "ids")?
            )?),
            "set_to_crate" => {
                let conn = lock(&self.conn);
                let ids = sets::track_ids(&conn, arg(a, "id")?)?;
                let c = crate::crates::create(
                    &conn,
                    &crate::crates::CrateInput {
                        name: arg(a, "name")?,
                        kind: "manual".into(),
                        color: Some("teal".into()),
                        category: Some("Sets".into()),
                        parent_id: None,
                        rules: None,
                    },
                )?;
                crate::crates::add_tracks(&conn, c.id, &ids)?;
                json!(crate::crates::get(&conn, c.id)?)
            }

            // ---------- gig mode ----------
            "gig_current" => json!(gig::current(&lock(&self.conn))?),
            "gig_start" => {
                let id = gig::start(
                    &lock(&self.conn),
                    &arg::<Option<String>>(a, "name")?.unwrap_or_default(),
                    arg(a, "set_plan_id")?,
                )?;
                self.jobs.pause_all(true);
                *lock(&self.watcher) = None;
                json!({"id": id})
            }
            "gig_end" => {
                let id = gig::end(&lock(&self.conn))?;
                self.jobs.pause_all(false);
                self.restart_watcher();
                json!({"id": id})
            }
            "gig_event" => {
                json!({"id": gig::add_event(&lock(&self.conn), &arg::<String>(a, "kind")?, arg(a, "track_id")?, arg::<Option<String>>(a, "text")?.as_deref())?})
            }
            "gig_request" => {
                gig::set_request(
                    &lock(&self.conn),
                    arg(a, "id")?,
                    &arg::<String>(a, "status")?,
                    arg(a, "track_id")?,
                )?;
                json!({"ok": true})
            }
            "gig_delete_event" => {
                gig::delete_event(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "gigs" => json!(gig::list(&lock(&self.conn))?),
            "gig_recap" => gig::recap(&lock(&self.conn), arg(a, "id")?)?,
            "export_recap" => {
                let conn = lock(&self.conn);
                let md = gig::recap_markdown(&conn, arg(a, "id")?)?;
                export::write_text(
                    &PathBuf::from(arg::<String>(a, "path")?),
                    &md,
                    arg::<Option<bool>>(a, "overwrite")?.unwrap_or(false),
                )?;
                json!({"ok": true})
            }

            // ---------- Quick Prep: AI help with the assistant's model ----------
            // ---------- Studio ----------
            "studio_new_folder" => {
                let dir = export::new_folder(
                    &PathBuf::from(arg::<String>(a, "parent")?),
                    &arg::<String>(a, "name")?,
                )?;
                lock(&self.studio_folders).insert(dir.clone());
                json!({"path": dir.to_string_lossy()})
            }
            "ai_complete" => {
                // One plain request to the assistant's model (Studio sound design); no tools.
                let cfg = crate::agent::config(self)?;
                if cfg.provider == "off" {
                    return invalid(
                        "turn on the AI assistant in Settings first (Claude or a local model)",
                    );
                }
                let system: String = arg(a, "system")?;
                let user: String = arg(a, "user")?;
                let reply = self
                    .online
                    .llm_chat(&cfg, &system.chars().take(8000).collect::<String>(), &[], &[json!({"role": "user", "content": user.chars().take(8000).collect::<String>()})])
                    .map_err(Error::Invalid)?;
                json!({"text": quick::reply_text(&reply)})
            }
            "ai_tidy" | "ai_order" => {
                // Uses the AI model chosen for the assistant (Claude or a local
                // model); one plain request, no tools. Results are suggestions.
                let cfg = crate::agent::config(self)?;
                if cfg.provider == "off" {
                    return invalid(
                        "turn on the AI assistant in Settings first (Claude or a local model)",
                    );
                }
                let (msgs, ids, genres) = {
                    let conn = lock(&self.conn);
                    if cmd == "ai_tidy" {
                        let tracks: Vec<quick::TidyInput> = arg(a, "tracks")?;
                        if tracks.is_empty() || tracks.len() > 25 {
                            return invalid("send between 1 and 25 tracks at a time");
                        }
                        let genres: Vec<String> = arg::<Option<Vec<String>>>(a, "genres")?
                            .unwrap_or_default()
                            .into_iter()
                            .take(300)
                            .collect();
                        let msgs = quick::tidy_prompt(&conn, &tracks, &genres)?;
                        (
                            msgs,
                            tracks.iter().map(|t| t.id).collect::<Vec<_>>(),
                            genres,
                        )
                    } else {
                        let ids: Vec<i64> = arg(a, "ids")?;
                        if ids.len() < 2 || ids.len() > 300 {
                            return invalid("an AI order needs between 2 and 300 tracks");
                        }
                        let request: String = arg(a, "request")?;
                        if request.trim().is_empty() {
                            return invalid("say how you'd like the tracks ordered");
                        }
                        (quick::order_prompt(&conn, &request, &ids)?, ids, vec![])
                    }
                };
                // The model call happens without holding the catalogue lock.
                let reply = self
                    .online
                    .llm_chat(
                        &cfg,
                        &msgs[0].1,
                        &[],
                        &[json!({"role": "user", "content": msgs[1].1})],
                    )
                    .map_err(Error::Invalid)?;
                let text = quick::reply_text(&reply);
                if cmd == "ai_tidy" {
                    json!(quick::parse_tidy(
                        &text,
                        &ids.iter().copied().collect(),
                        &genres
                    ))
                } else {
                    match quick::parse_order(&text, &ids) {
                        Some((order, note)) => json!({"order": order, "note": note}),
                        None => {
                            return invalid("the AI didn't return a usable order; try rephrasing")
                        }
                    }
                }
            }

            // ---------- gig packs ----------
            "gigpack_preview" => {
                // Quick Prep sends a layout (folders, clean names, playlists,
                // ZIP, tagged copies); a plain gig pack sends only the tracks.
                let opts = arg::<Option<gigpack::PackOptions>>(a, "options")?.unwrap_or_default();
                let ids = if opts.items.is_some() {
                    vec![]
                } else {
                    self.resolve_ids(a)?
                };
                let plan = gigpack::preview_with(
                    &lock(&self.conn),
                    &ids,
                    &PathBuf::from(arg::<String>(a, "dest")?),
                    &arg::<String>(a, "name")?,
                    &opts,
                )?;
                let t = token();
                lock(&self.pack_previews).insert(t.clone(), plan.clone());
                json!({"token": t, "plan": plan})
            }
            "export_serato" => crate::dj_export::export_serato(
                &lock(&self.conn),
                Path::new(&arg::<String>(a, "serato_dir")?),
                arg::<Option<Vec<i64>>>(a, "crate_ids")?.as_deref(),
            )?,
            "export_rekordbox" => crate::dj_export::export_rekordbox(
                &lock(&self.conn),
                Path::new(&arg::<String>(a, "path")?),
                arg::<Option<Vec<i64>>>(a, "crate_ids")?.as_deref(),
                env!("CARGO_PKG_VERSION"),
            )?,
            "export_crate_folders" => {
                let dest = PathBuf::from(arg::<String>(a, "dest")?);
                if !dest.is_dir() {
                    return invalid("choose a destination folder or drive that exists");
                }
                let ids: Option<Vec<i64>> = arg(a, "crate_ids")?;
                let db = self.db_path.clone();
                self.start_job("crate_export", move |ctl, p| {
                    crate::dj_export::export_folders(&db, &dest, ids, ctl, p)
                })?
            }
            "gigpack_start" => {
                let t: String = arg(a, "token")?;
                let plan = lock(&self.pack_previews)
                    .remove(&t)
                    .ok_or_else(|| Error::Invalid("preview again first".into()))?;
                if PathBuf::from(&plan.pack_dir).exists() {
                    return invalid("the pack folder already exists; nothing was copied");
                }
                let db = self.db_path.clone();
                self.start_job("gigpack", move |ctl, p| {
                    let conn = db::open(&db)?;
                    gigpack::execute(&conn, &plan, ctl, p)
                })?
            }

            // ---------- safe tag writing ----------
            "write_preview" => {
                let ids = self.resolve_ids(a)?;
                let values: BTreeMap<String, Option<String>> = arg(a, "values")?;
                let plan = safe_write::preview(&lock(&self.conn), &ids, &values)?;
                let t = token();
                lock(&self.write_previews).insert(t.clone(), plan.clone());
                json!({"token": t, "plan": plan})
            }
            "fix_files_preview" => {
                // Write catalogue fixes into the files' own tags (opt-in, previewed).
                let ids: Vec<i64> = if arg::<Option<bool>>(a, "all")?.unwrap_or(false) {
                    let conn = lock(&self.conn);
                    let v: Vec<i64> = conn
                        .prepare("SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.presence='present' AND t.read_status='ok' AND t.media_kind='audio' AND (u.track_id IS NOT NULL OR a.track_id IS NOT NULL) LIMIT 5000")?
                        .query_map([], |r| r.get(0))?
                        .collect::<std::result::Result<_, _>>()?;
                    v
                } else {
                    self.resolve_ids(a)?
                };
                if ids.is_empty() {
                    return invalid("nothing to write: no catalogue fixes or analysis yet");
                }
                let conn = lock(&self.conn);
                if !safe_write::enabled(&conn)? {
                    return invalid("Writing to music files is turned off. Turn it on in Settings → Safety first.");
                }
                let plan = safe_write::preview_from_catalogue(
                    &conn,
                    &ids,
                    arg::<Option<bool>>(a, "include_estimates")?.unwrap_or(true),
                )?;
                drop(conn);
                let t = token();
                lock(&self.write_previews).insert(t.clone(), plan.clone());
                json!({"token": t, "plan": plan})
            }
            "run_auto_prep" => {
                let db = self.db_path.clone();
                let online = self.online.clone();
                self.start_job("auto_prep", move |ctl, p| {
                    crate::autoprep::run(&db, online.as_ref(), ctl, p)
                })?
            }
            "bad_files" => {
                let conn = lock(&self.conn);
                let ids = crate::organize::bad_files(&conn)?;
                drop(conn);
                let rows = if ids.is_empty() {
                    json!([])
                } else {
                    library_rows(self, &ids)?
                };
                json!({"ids": ids, "rows": rows})
            }
            "organize_preview" => {
                let kind: String = arg(a, "kind")?;
                let conn = lock(&self.conn);
                let mut merge = None;
                let plan = match kind.as_str() {
                    "rename" => {
                        drop(conn);
                        let ids = self.resolve_ids(a)?;
                        crate::organize::preview_rename(
                            &lock(&self.conn),
                            &ids,
                            &arg::<Option<String>>(a, "template")?
                                .unwrap_or_else(|| "{artist} - {title}".into()),
                        )?
                    }
                    "move" => {
                        drop(conn);
                        let ids = self.resolve_ids(a)?;
                        crate::organize::preview_move(
                            &lock(&self.conn),
                            &ids,
                            &arg::<Option<String>>(a, "template")?
                                .unwrap_or_else(|| "{genre}/{artist}".into()),
                        )?
                    }
                    "folder_rename" => crate::organize::preview_folder_rename(
                        &conn,
                        &arg::<String>(a, "folder")?,
                        &arg::<String>(a, "new_name")?,
                    )?,
                    "remove" => {
                        drop(conn);
                        let ids = self.resolve_ids(a)?;
                        crate::organize::preview_remove(&lock(&self.conn), &self.data_dir(), &ids)?
                    }
                    "bad_files" => {
                        let ids = crate::organize::bad_files(&conn)?;
                        crate::organize::preview_remove(&conn, &self.data_dir(), &ids)?
                    }
                    "replace" => {
                        let keep: i64 = arg(a, "keep")?;
                        let others: Vec<i64> = arg(a, "others")?;
                        merge = Some((keep, others.clone()));
                        crate::organize::preview_replace(&conn, &self.data_dir(), keep, &others)?
                    }
                    _ => return invalid("unknown organiser action"),
                };
                let t = token();
                lock(&self.org_previews).insert(t.clone(), (plan.ops.clone(), merge));
                json!({"token": t, "plan": plan})
            }
            "organize_apply" => {
                let t: String = arg(a, "token")?;
                if !arg::<Option<bool>>(a, "approved")?.unwrap_or(false) {
                    return invalid("changes must be explicitly approved");
                }
                let (ops, merge) = lock(&self.org_previews)
                    .remove(&t)
                    .ok_or_else(|| Error::Invalid("preview again first".into()))?;
                let conn = lock(&self.conn);
                if let Some((keep, others)) = &merge {
                    crate::organize::merge_into(&conn, *keep, others)?;
                }
                json!(crate::organize::apply(&conn, &self.data_dir(), &ops)?)
            }
            "organize_undo" => json!({"undone": crate::organize::undo(
                &lock(&self.conn),
                arg::<Option<String>>(a, "batch")?.as_deref(),
                arg(a, "id")?
            )?}),
            "organize_history" => json!(crate::organize::history(&lock(&self.conn), 500)?),
            "removed_summary" => crate::organize::removed_summary(&lock(&self.conn))?,
            "empty_removed" => {
                if !arg::<Option<bool>>(a, "confirmed")?.unwrap_or(false) {
                    return invalid("permanently deleting removed files must be confirmed");
                }
                json!({"deleted": crate::organize::empty_removed(&lock(&self.conn), &self.data_dir())?})
            }
            "write_apply" => {
                let t: String = arg(a, "token")?;
                if !arg::<Option<bool>>(a, "approved")?.unwrap_or(false) {
                    return invalid("changes must be explicitly approved");
                }
                let plan = lock(&self.write_previews)
                    .remove(&t)
                    .ok_or_else(|| Error::Invalid("preview again first".into()))?;
                let res = safe_write::apply(&lock(&self.conn), &self.data_dir(), &plan)?;
                // re-read changed files so the catalogue shows the new tags
                let roots: Vec<i64> = {
                    let conn = lock(&self.conn);
                    let mut v = vec![];
                    for pc in &plan {
                        if let Ok(r) = conn.query_row(
                            "SELECT root_id FROM tracks WHERE id=?1",
                            rusqlite::params![pc.track_id],
                            |r| r.get::<_, i64>(0),
                        ) {
                            if !v.contains(&r) {
                                v.push(r);
                            }
                        }
                    }
                    v
                };
                let _ = self.start_scan(Some(roots), false);
                json!(res)
            }
            "change_log" => json!(safe_write::log(&lock(&self.conn), 500)?),
            "rollback_change" => {
                let conn = lock(&self.conn);
                if !safe_write::enabled(&conn)? {
                    return invalid("turn on file changes in Settings to roll back");
                }
                safe_write::rollback(&conn, arg(a, "id")?)?;
                json!({"ok": true})
            }

            // ---------- Serato & history ----------
            "serato_import_crates" => {
                serato::import_crates(&lock(&self.conn), &PathBuf::from(arg::<String>(a, "path")?))?
            }
            "history_import_csv" => {
                let text: String = match arg::<Option<String>>(a, "text")? {
                    Some(t) => t,
                    None => {
                        let p = PathBuf::from(arg::<String>(a, "path")?);
                        if std::fs::metadata(&p)?.len() > 20_000_000 {
                            return invalid("file is too large");
                        }
                        String::from_utf8_lossy(&std::fs::read(&p)?).to_string()
                    }
                };
                serato::import_history_csv(
                    &lock(&self.conn),
                    &text,
                    &arg::<Option<String>>(a, "session")?
                        .unwrap_or_else(|| "Imported history".into()),
                )?
            }
            "history" => json!(serato::history(&lock(&self.conn), 1000)?),
            "clear_history" => json!({"removed": serato::clear_history(&lock(&self.conn))?}),

            // ---------- personal files ----------
            "docs_roots" => json!(docs::roots(&lock(&self.conn))?),
            "docs_add_root" => {
                docs::add_root(&lock(&self.conn), &arg::<String>(a, "path")?)?;
                json!({"ok": true})
            }
            "docs_remove_root" => {
                docs::remove_root(&lock(&self.conn), arg(a, "id")?)?;
                json!({"ok": true})
            }
            "docs_scan" => {
                if !docs::enabled(&lock(&self.conn))? {
                    return invalid("The personal files module is turned off.");
                }
                let db = self.db_path.clone();
                self.start_job("docs", move |ctl, p| docs::scan(&db, ctl, p))?
            }
            "docs_search" => json!(docs::search(
                &lock(&self.conn),
                &arg::<Option<String>>(a, "text")?.unwrap_or_default(),
                arg::<Option<String>>(a, "ext")?.as_deref(),
                300
            )?),
            "docs_report" => docs::report(&lock(&self.conn))?,
            "docs_clear" => {
                docs::clear(&lock(&self.conn))?;
                json!({"ok": true})
            }

            // ---------- folder watching ----------
            "watch_status" => {
                let conn = lock(&self.conn);
                let w = lock(&self.watcher);
                json!({"enabled": watcher::enabled(&conn)?, "active": w.is_some(), "roots": w.as_ref().map(|x| x.roots.clone()).unwrap_or_default(), "pending": watcher::pending(&conn)?})
            }
            "watch_clear" => {
                json!({"removed": watcher::clear(&lock(&self.conn), arg(a, "root_id")?)?})
            }

            _ => return invalid(format!("unknown command '{cmd}'")),
        })
    }
}

/// Library rows for a set of ids (for previews).
fn library_rows(app: &App, ids: &[i64]) -> Result<Value> {
    let conn = lock(&app.conn);
    let mut rows = vec![];
    for id in ids.iter().take(500) {
        if let Ok(d) = crate::library::track_detail(&conn, *id) {
            rows.push(json!(d.row));
        }
    }
    Ok(json!(rows))
}
