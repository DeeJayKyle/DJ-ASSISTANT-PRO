# DJ Assistant 2.0 — Flutter migration map

DJ Assistant 1.x is a Tauri app: a Rust engine (`crates/dj-core`, ~18,900 lines;
`crates/dj-online`, ~2,200 lines) behind one command bridge, and a React/TypeScript
interface (`src/`, ~8,800 lines, plus the Studio in `src/studio/`, ~3,800 lines).
2.0 rewrites all of it in Dart and Flutter for Windows, keeping the same rules:

- **Local-first and private.** No telemetry. Nothing goes online unless the DJ turns
  that service on, and each service says exactly what it sends.
- **Read-only by default.** Music files are only read. Tag writing, renames, moves and
  removals are opt-in, previewed, approved, verified and reversible.
- **The library is never put at risk.** Every write path keeps the verified-backup,
  changed-since-preview and exact-byte rollback guarantees of 1.x.

## How the 1.x architecture maps to Flutter

| 1.x | 2.0 |
|---|---|
| Tauri shell (`src-tauri/src/main.rs`) | Flutter Windows runner (`windows/`) |
| One bridge: `api(cmd, args)` → `Session::dispatch` | No bridge: widgets call Dart services directly |
| Background jobs on threads (`jobs.rs`: scan, hash, analysis, auto-prep, exports) | Dart **isolates**, with progress, pause, resume and cancel streamed through a `JobsController` |
| `track://` stream for previews | Local file playback in the audio engine (no server) |
| `pack://` stream for packs | Direct file access to `<data>/packs/<id>/` |
| `studio_write` raw-bytes command | `StudioFiles.save()` with the same guards (new files only, never replace audio) |
| `reveal` | `Process.run('explorer', ['/select,', path])` |
| React state per view | **Riverpod** providers per feature |
| CSS themes (Midnight Pro, colour presets) | `ThemeData` + `ThemeExtension` tokens |
| WebAudio graph (decks, EQ, filter, loops) | `flutter_soloud` (MIT, SoLoud via FFI): low-latency playback with filters |
| Web Workers (Studio DSP) | Isolates |
| ONNX Runtime Web (Pro Stems AI) | `onnxruntime` Dart package (FFI to onnxruntime.dll, DirectML) |
| `keyring` (Windows Credential Manager) | `win32` FFI: `CredWriteW` / `CredReadW` / `CredDeleteW` |
| Tauri updater (signed `latest.json`) | Same manifest and signing, checked by a Dart updater, MSIX/NSIS installer |

### Data carries over

2.0 opens the **same SQLite catalogue** (`catalogue.sqlite3`, the schema and the
migrations in `db.rs`) with the `sqlite3` package, and the same `accounts.json`. A DJ
moving from 1.8 keeps their library, crates, sets, analysis, suggestions, change log and
settings. The SQL functions `fold()` (accent-insensitive search) and `keynorm()` (any
key spelling to Camelot) are registered from Dart, as 1.x does from Rust.

## Decisions with real risk (to confirm before Phase 3 reaches them)

1. **Audio decoding for analysis.** 1.x decodes MP3, AAC/M4A, FLAC, ALAC, WAV, AIFF,
   Ogg and MKV/MP4 audio with Symphonia. There is no mature pure-Dart decoder for
   MP3/AAC. Plan: decode with **Windows Media Foundation** through `win32` FFI
   (`IMFSourceReader` → 32-bit float PCM). That covers MP3, AAC, FLAC, ALAC and WAV on
   Windows 10/11, with a pure-Dart WAV/AIFF/FLAC reader as fallback. Ogg/Opus would need
   an extra decoder.

   *Status:* done (`lib/audio/`). WAV, AIFF/AIFC and FLAC decode in Dart on every
   platform, bit-exact against ffmpeg on 21 test clips (`test/decode_test.dart`).
   Everything else goes through Media Foundation (`media_foundation.dart`, raw COM
   vtable calls with indices and GUIDs checked against the SDK headers), tested in the
   Windows CI job (`test/media_foundation_test.dart`). Ogg Vorbis and Opus still need a
   decoder: those files are catalogued and tagged, but not yet analysed.
2. **Tag reading and safe writing.** 1.x uses `lofty` for ID3v2/ID3v1, FLAC Vorbis
   comments and MP4 `ilst`. Pure-Dart writers for all three must be written and tested
   byte for byte: Serato `GEOB` frames preserved, padding respected, temp file, verify,
   atomic rename, backup and rollback. This is the most safety-critical part of the port
   and is test-first.
3. **Analysis parity.** BPM (onset envelope, autocorrelation, half/double time), key
   (chroma, Krumhansl profiles, Camelot), EBU R128 loudness (LUFS), clipping, silence,
   intro/outro, cue ideas, waveform and Chromaprint fingerprints are ported from
   `analysis.rs`. Results are checked against 1.x on the same fixture files.

   *Status:* done (`lib/analysis/`). On 6 synthetic music clips and the lossless
   library fixtures 2.0 matches 1.x: same BPM, alternative, key, energy, sections,
   cues, warnings and waveform; loudness within 0.005 LU (EBU R128 port of the
   `ebur128` crate); Chromaprint fingerprints bit-identical, including the rubato sinc
   resampler (`test/analysis_test.dart`). One deliberate difference: 1.x misreads
   AIFF files that have a chunk after the sound data (Symphonia skips the SSND header
   twice, so 4 bytes of the next chunk become samples and can fake a peak); 2.0 reads
   them correctly, as ffmpeg does.

## Command inventory → Dart services

All 164 commands of 1.x, grouped by the Dart service that replaces them.

| Dart service | 1.x commands | Source (Rust) |
|---|---|---|
| `AccountsService` | accounts, account_create, account_switch, account_rename, account_delete | accounts.rs |
| `PacksService` | packs, pack_install, pack_cancel, pack_remove | packs.rs |
| `LibraryService` | app_info, stats, list_roots, add_root, remove_root, search, track_detail, update_user_fields, set_tags, list_tags, facet | library.rs, api.rs |
| `ScanService` (isolate) | start_scan, scan_status, pause_scan, cancel_scan, watch_status, watch_clear | scanner.rs, watcher.rs, metadata.rs, video.rs |
| `CratesService` | list_crates, create_crate, update_crate, delete_crate, crate_add, crate_add_query, crate_remove, preview_rules, rule_fields, move_crate, crate_templates, apply_template, labels, set_labels, colour_by_energy, crate_hygiene | crates.rs, rules.rs, templates.rs |
| `DuplicatesService` (isolate) | start_hash, hash_status, cancel_hash, duplicates, set_dup_decision | duplicates.rs |
| `HealthService` | health, health_fix_list | health.rs |
| `SettingsService` | get_settings, set_setting (and its keys: low_bitrate_kbps, theme, surface, motion, ui_prefs, auto_fix_min, key_notation, ai_*) | api.rs, db.rs |
| `JobsController` | jobs, job_status, cancel_job, pause_job | jobs.rs |
| `AnalysisService` (isolate) | start_analysis, analysis_summary | analysis.rs, analysis_store.rs |
| `SuggestionsService` | generate_suggestions, suggestions, suggestion_counts, accept_suggestion, reject_suggestion, reset_suggestion, accept_suggestions_bulk, run_auto_prep | suggest.rs, autoprep.rs |
| `OnlineLookups` (off by default) | lookup_musicbrainz, lookup_catalogs, lookup_acoustid, services, set_service, set_secret, delete_secret | suggest.rs, dj-online |
| `AssistantService` | assistant, ai_status, ai_chat, ai_confirm, ai_reset, ai_complete, ai_tidy, ai_order, ai_list_models | assistant.rs, agent.rs, dj-online/llm.rs |
| `LocalModelService` | ai_local_setup, ai_local_start, ai_local_pull, ai_local_models, ai_pack_setup | agent.rs, dj-online |
| `DiscoveryService` | crate_fit, crate_gaps, overplayed, match_tracklist, preferences, pref_feedback, reset_learning, lastfm_crate, lastfm_track, follow, unfollow, followed, refresh_releases, discovery_items, discovery_status, store_links | discovery.rs |
| `SetStudioService` | plan_set, save_set, list_sets, get_set, delete_set, review_set, set_to_crate | sets.rs |
| `GigService` | gig_current, gig_start, gig_end, gig_event, gig_request, gig_delete_event, gigs, gig_recap, export_recap | gig.rs |
| `ExportService` | export_m3u, export_csv, export_serato, export_rekordbox, export_crate_folders | export.rs, dj_export.rs |
| `GigPackService` (isolate) | gigpack_preview, gigpack_start | gigpack.rs |
| `QuickPrepService` | (Quick Prep paths: clean names, playlist, folders, genres, export) | quick.rs |
| `SafeWriteService` | write_preview, fix_files_preview, write_apply, change_log, rollback_change | safe_write.rs |
| `OrganizeService` | bad_files, organize_preview, organize_apply, organize_undo, organize_history, removed_summary, empty_removed (rename, move, folder_rename, remove, replace) | organize.rs |
| `SeratoImport` | serato_import_crates, history_import_csv, history, clear_history | serato.rs |
| `PersonalFiles` (opt-in) | docs_roots, docs_add_root, docs_remove_root, docs_scan, docs_search, docs_report, docs_clear | docs.rs |
| `StudioFiles` | studio_new_folder (+ studio_write, reveal) | export.rs, main.rs |
| Studio (Dart DSP) | stems, chords, MIDI, time-stretch, decks, remix, synth, drums, sequencer, Pro Stems AI | src/studio/** |

## Phases

1. **Discovery** (this document).
2. **Project:** `flutter create --platforms=windows`, dependencies, a GitHub Actions job
   that runs `flutter analyze`, `flutter test` and `flutter build windows`.
3. **Core services in Dart,** test-first, in this order: catalogue + accounts (same DB),
   search and smart crates, analysis, safe tag writing, organiser, then the rest.
4. **UI:** shell (title bar, account switcher, sidebar, Assistant panel), Library,
   Quick Prep, Studio (decks with EQ/filter/hot cues/loops, `CustomPainter` waveforms),
   then every remaining screen.
5. **Verify:** analyzer and tests clean, Windows build in CI, a network audit (no
   socket opened unless a service is on), and a migration report.

## Limits of the build environment

Development happens on Linux. Dart code is checked here with `flutter analyze`,
`flutter test` and a Linux desktop build. The **Windows build runs in GitHub Actions**
(`windows-latest`), and hands-on testing of the Windows app happens on the DJ's PC.
