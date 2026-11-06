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
| `track://` stream for previews | Local file playback with `flutter_soloud` straight from disk (no server) |
| `pack://` stream for packs | Direct file access to `<data>/packs/<id>/` |
| `studio_write` raw-bytes command | `StudioFiles.save()` with the same guards (new files only, never replace audio) |
| `reveal` | `Process.run('explorer', ['/select,', path])` |
| React state per view | **Riverpod** providers per feature |
| CSS themes (Midnight Pro, colour presets) | `ThemeData` + `ThemeExtension` tokens |
| WebAudio graph (decks, EQ, filter, loops) | Decks, EQ (RBJ biquads), filter, loops and crossfader mixed in Dart; `flutter_soloud` (MIT) plays the stream |
| Web Workers (Studio DSP) | Isolates |
| Web MIDI (Synth/Drum Lab controllers) | winmm `midiIn*` through FFI |
| ONNX Runtime Web (Pro Stems AI) | `onnxruntime` Dart package (FFI to its bundled onnxruntime.dll, processor) |
| `keyring` (Windows Credential Manager) | Raw FFI to advapi32: `CredWriteW` / `CredReadW` / `CredDeleteW`, same credential format |
| Tauri updater (signed `latest.json`) | Same manifest and minisign key, verified in Dart before an installer is run |

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

   *Status:* done (`tag_writer.dart`, `safe_write.dart`, `blake3.dart`). The writers
   change only the edited fields and copy every other ID3 frame, Vorbis comment, FLAC
   block and MP4 item byte for byte; ID3 keeps its 2.3/2.4 version and reuses its
   padding, FLAC resizes its padding block, MP4 uses a neighbouring `free` atom or
   moves the chunk offsets (`stco`/`co64`). Unusual layouts (ID3v2.2, extended
   headers, footers, 2.4 whole-tag unsync, 64-bit moov) are refused, not rewritten.
   The service keeps 1.x's six steps (off by default, exact preview, unchanged-since-
   preview check, verified backup, verified temporary copy + rename, logged and
   reversible), and BLAKE3 matches 1.x, so 2.0 can roll back changes logged by 1.8.
   Files written by 2.0 read back correctly in 1.x (lofty) and ffprobe.
   1.x quirk not reproduced: its scanner shows the first MP3 COMM frame as the
   comment even when that is iTunes' `iTunNORM` loudness data; 2.0 shows the real
   (undescribed) comment.
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

## Migration report (Phase 5)

### Where each phase stands

| Phase | Status |
|---|---|
| 1. Discovery | Done (this document). |
| 2. Project | Done. `flutter.yml` runs format, `flutter analyze --fatal-infos` and `flutter test` on Linux, then `flutter test` and `flutter build windows --release` on `windows-latest`, and uploads the build. |
| 3. Core services | Done. Every 1.x command group in the inventory above has its Dart service (`lib/core`, `lib/online`, `lib/assistant`, `lib/analysis`, `lib/audio`, `lib/app/session.dart`). |
| 4. UI and state | Done. Shell (title bar with accounts, sidebar with crates and folders, status bar, job toasts, Ctrl+J assistant), every 1.x screen, Quick Prep, and the Studio (Stems, Remix, DJ Decks, Synth Lab, Drum Lab). Riverpod providers in `lib/ui/state.dart`. |
| 5. Verify | Done, except hands-on testing on a DJ's PC (below). |
| Release | **v2.0.0 published** (`release-flutter.yml`). The installer is signed with 1.x's update key and published with `latest.json`, so 1.8 installs are offered 2.0 by their auto-updater. |

### Evidence

- **Analyzer:** `flutter analyze --fatal-infos`: no issues.
- **Tests:** 225 pass. 7 are skipped on Linux: the Media Foundation tests, which are Windows-only and run in the Windows CI job, and the checks that need ffprobe installed.
- **Parity with 1.x:**
  - The same catalogue and accounts are opened.
  - Golden files generated by the Rust engine cover analysis, metadata and the 68 rule-assistant phrases.
  - Decoding is bit-exact against ffmpeg on 21 clips.
  - Tag writes read back in lofty and ffprobe, and BLAKE3 backups roll back changes logged by 1.8.
  - The update signature was checked on the real 1.8.1 installer.
  - The Online parsers pass 1.x's own tests, and every 1.x Studio test is ported (`test/studio_test.dart`).
- **Network audit** (`test/network_audit_test.dart`):
  - Every request goes through one HTTP client, which the test replaces with a counter.
  - A new library has every online service off except the update check (as in 1.x: it sends only the app version, and can be turned off in Settings).
  - Lookups, auto-prep online steps, Discovery (Last.fm, MusicBrainz releases) and the AI assistant all refuse, and send nothing, until their service is turned on.
  - Turning MusicBrainz on lets requests through, and only to musicbrainz.org.
  - Opening the Studio, playback, analysis, separation, MIDI and the folder watcher are all local.
  - There is no telemetry.
- **Library safety:**
  - Music files are only opened for reading, except by `SafeWriteService` and `OrganizeService`, which keep 1.x's preview, check, backup, verify and rollback steps.
  - Studio and Quick Prep exports only create new files or new folders (`studioSave`, `studioNewFolder`, `studioWriteInto`), and never replace audio.

### Differences from 1.x

- **Pro Stems AI runs on the processor.** The ONNX Runtime bundled with the Dart package has no DirectML, so the graphics card is not used yet. Results are the same; separation is slower on PCs where 1.8.1 used the GPU.
- **Ogg Vorbis and Opus** are catalogued and tagged but not analysed (no decoder yet).
- **The decks are mixed in Dart** and streamed to the sound card with about 120 ms queued, so knob moves take effect after that delay.
- **Fixes over 1.x:**
  - AIFF files with a chunk after the sound data are read correctly.
  - The MP3 comment shown is the real one, not iTunes' `iTunNORM` loudness data.

### Installer and update path

`installer/dj_assistant.nsi` is a per-user NSIS installer with 1.x's product name, folder (`%LOCALAPPDATA%\DJ Assistant`) and registry keys. It removes 1.x with 1.x's own uninstaller in update mode, which keeps app data and shortcuts, and it understands the `/P /UPDATE /R` switches the 1.x updater passes.

On every push and every release, CI on Windows (`installer/test-upgrade.ps1`):
1. installs 1.8.1;
2. updates it exactly as the 1.x updater does;
3. checks that 2.0 is registered, the 1.x program is gone, the data is kept and the Start menu shortcut opens 2.0;
4. starts 2.0 and confirms it keeps running;
5. uninstalls, and checks the data is still there;
6. installs fresh, then reinstalls over it.

The release checks the signature with the key built into the app before publishing. The installer is not code-signed (neither was 1.x), so SmartScreen may warn about an unknown publisher.

### Still to do on a Windows PC

Hands-on testing that CI cannot do:

- Real-time decks: latency, loops, EQ, the sound of the filters.
- MIDI controllers.
- Pro Stems AI with the installed pack.
- Media Foundation formats on real libraries.
- The update install flow.
- Window and DPI behaviour.
