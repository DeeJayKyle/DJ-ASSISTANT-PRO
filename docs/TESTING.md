# Testing

## DJ Assistant 2.x (Flutter, current release)

### Automated (`.github/workflows/flutter.yml`, every push)

| Suite | What it proves |
|---|---|
| `dart format`, `flutter analyze --fatal-infos` | Format and lint clean |
| `flutter test` (Linux; Windows adds Media Foundation, Pro Stems AI and MP3/M4A Studio tests) | Services, parsers, golden files shared with 1.x, network audit, library safety |
| `test/screens/screens_test.dart` | Every page at 900×600, 1024×640, 1280×720, 1366×768, 1100×720, 1440×900 and 1920×1080, dark and light, with no overflow or layout error; long names with the assistant open, full and hidden; `SCREENSHOTS=<dir>` saves them |
| `integration_test/app_test.dart` | Drives the real app on Linux (Xvfb) and Windows |
| `installer/test-upgrade.ps1` (Windows) | 1.8.1 → 2.x and 2.x → 2.x updates keep data |

Tests for 2.4:

| Requirement | Test |
|---|---|
| Auto-prep is review-first: nothing accepted, files unchanged | `watch_autoprep_test.dart` — *auto-prep is review-first by default* |
| "Fill empty fields" never replaces a value | `watch_autoprep_test.dart` — *fill-empty mode…* |
| "Apply confident fixes" (old behaviour) and exact undo of every automatic change | `watch_autoprep_test.dart`, `online_test.dart` — *catalogues fix BPM, year and genre…* |
| Organise mode off by default, own switch, legacy libraries keep it | `organize_test.dart` — *Organise Files mode…* |
| Only approved items apply; moved file's hash recorded and matches | `organize_test.dart` — *only the approved items…* |
| Replacement: verified copy in, original kept and verified, crates kept, source untouched, undo restores exact bytes, nothing deleted | `organize_test.dart` — *replace a track…* |
| Replacement with another format; emptying Removed files never deletes the track | `organize_test.dart` — *replace with another format…* |
| Serato notes from `database V2` and crates; Serato's files byte-identical afterwards | `organize_test.dart` — *previews say which tracks Serato knows about* |
| Low-bitrate list honours the setting; lossless never listed; owned copies; file facts; loudness matching; caveat wording | `upgrades_test.dart` |
| Pages fit small laptops, long names, assistant modes | `screens/screens_test.dart` |

All tests work on temporary copies of the synthetic fixture library (`crates/dj-core/tests/fixtures/library`) or files they create. None touch a real library.

### Manual tests for 2.4 — NOT yet performed (need a Windows 10/11 PC with Serato DJ)

Use **copies**: copy a few albums and a copy of the `_Serato_` folder to a test drive or user account, and point Serato at that copy, not your live library. Record the date, Windows version, Serato version and result.

| # | Test | Expected |
|---|---|---|
| W1 | Update from 2.3 to 2.4 | Library, crates, settings kept. Suggestions shows the one-time notice. Settings → Library → Metadata suggestions = *Review first* |
| W2 | Scan new music with auto-prep on | Suggestions appear; no catalogue value changes until approved |
| W3 | Approve 3 single suggestions, then a batch of 10; undo one and the batch | Values change, then return exactly to what they were |
| W4 | Window at 1280×720 and 1366×768, at 100%, 125% and 150% scaling; a narrow window | Every page readable, no clipped buttons; assistant docked, resizable, overlay when narrow |
| W5 | Keyboard only: Tab through Suggestions, Organise preview, Upgrades; resize the assistant with arrow keys; Ctrl+J, Ctrl+Shift+J; Narrator | Everything reachable and announced; ticks and buttons have names |
| W6 | Organise mode on; rename 5 copied tracks that are in a copied Serato crate | Preview shows Serato notes for those 5; after applying, Serato shows them missing; *Relocate lost files* finds them; cues and beatgrids intact |
| W7 | Undo the rename batch | Files back under their old names; Serato finds them again |
| W8 | Move tracks into `{genre}` folders; rename a folder | Same as W6/W7 |
| W9 | Replace a copied 128 kbps MP3 that has Serato cues with a better MP3 of the same song | Preview warns that cues stay with the old file. New file has the old name; Serato's crate still lists it; old file in Removed files; undo restores the original and its cues |
| W10 | Replace with a FLAC | Name gains `.flac`; preview warns links break; Serato shows the old name missing |
| W11 | Remove exact duplicates (after Duplicates → Find exact copies) | Kept copy has the crates/tags; others in Removed files; undo works |
| W12 | Edit tags in the files from Organise for 5 tracks | Per-file preview; backups in the app's data folder; Serato cues and beatgrids intact; rollback restores exact bytes |
| W13 | Empty Removed files | The full list is shown first; only files inside Removed files are deleted |
| W14 | Upgrades: compare two real versions with *Compare*; play both | Loudness-matched playback; facts correct; nothing replaced unless chosen |
| W15 | A file open in Serato while renaming it | That item is skipped with a clear reason; nothing half-done |
| W16 | Online services off: use every new page | No network requests (check with Resource Monitor or a firewall log) |

## Legacy 1.x (Tauri) testing

The sections below describe the 1.x test suites and manual checks. They remain valid for the 1.x code in `src/`, `src-tauri/` and `crates/`.

### Automated (run on every push)

| Suite | Where | What it proves |
|---|---|---|
| `cargo test -p dj-core` — 25 unit + 17 library + 15 v1 integration tests | Windows CI and Linux CI | See tables below |
| `cargo test -p dj-online` — 4 parser tests | Windows CI | MusicBrainz/AcoustID/Last.fm response parsing and error handling |
| `npm test` (Vitest) — 5 tests | Windows CI | Formatting and rule helpers |
| `npm run e2e` — 25 steps | Linux CI | Real UI + real backend + real audio files in Chromium: scanning, filters, track card, crates, templates, analysis, duplicates, health, suggestions, Set Studio, Gig Mode, Gig Pack, assistant, settings, persistence; no external requests; source files unchanged |
| `scripts/check-no-network.sh` | Linux CI | No HTTP/TLS client crates in dj-core; no AF_INET/AF_INET6 socket or connect() during scanning, hashing, search, analysis, suggestions, crates, exports, Set Studio, gig packs, tag writing, personal files |
| `scripts/check-read-only.sh` | Windows CI | File-changing APIs only in safe_write.rs (opt-in), gigpack.rs (new folder) and export.rs (chosen file) |
| `scripts/check-licenses.py` | Windows CI | Shipped dependencies have permissive licences (MPL-2.0 Symphonia allowed) |
| clippy `-D warnings`, rustfmt, tsc | Windows CI | Lint/format/types |
| `npx tauri build` | Windows CI | NSIS installer builds; SHA-256 recorded |

### v1 integration tests (`crates/dj-core/tests/v1.rs`)

| Requirement | Test |
|---|---|
| Analysis reads audio, stores versioned estimates, never changes files | `analysis_reads_audio_and_never_changes_files` |
| Suggestions separate from file tags; accept/edit/reject; files untouched | `local_suggestions_are_reviewed_before_reaching_the_catalogue` |
| Online services off by default, consent for fingerprints, keys never returned, evidence text | `online_lookups_require_consent_and_give_evidence` |
| Cheat-sheet templates, labels, colour-by-energy, hygiene | `crate_templates_labels_and_hygiene` |
| Exports write only the chosen file, no silent overwrite, never audio names | `exports_write_only_the_chosen_file` |
| Discovery reasons, version-aware tracklist matching, ownership, learning reset | `discovery_from_library_and_online` |
| Set Studio: must-plays, no repeats, clean-only, save/review/crate | `set_studio_plans_reviewable_sets` |
| Gig mode pauses background work; requests; recap; play counts | `gig_mode_pauses_background_work_and_recaps` |
| Gig pack refuses destinations in the library, verifies copies, reports missing, never overwrites, sources unchanged | `gig_pack_copies_verifies_and_never_overwrites` |
| Tag writing: off by default, approval, backup equals original, audio unchanged, Serato GEOB preserved, changed-since-preview refused, rollback restores exact bytes | `safe_tag_writing_backs_up_verifies_and_rolls_back` |
| Serato crate/history import read-only | `serato_crates_and_history_import_read_only` |
| Personal files opt-in, separate from music, duplicates/encrypted flags | `personal_files_are_opt_in_and_separate` |
| Folder watcher notices new files without touching them | `folder_watcher_notices_new_files_without_touching_them` |
| SQL-like text in new inputs | `new_text_inputs_cannot_execute_sql` |
| Assistant routes v1 requests | `assistant_routes_v1_requests` |

### Analysis accuracy (manual check on a generated demo library)

`scripts/make-demo-library.sh` creates 20 three-minute synthetic tracks with known tempo and key. Result at release: tempo 19/20 exact (the other reported at double tempo with the correct half-time alternative), key 17/20 (misses were major keys read as a related minor), energy spread 2–9 in a sensible order. Real-music accuracy still needs checking on Herbie's library.

Fixtures (`crates/dj-core/tests/fixtures/library`, regenerated by `scripts/make-fixtures.sh`) are generated sine tones with invented tags: MP3 at 320/256/192/128/96 kbps, AAC 64 kbps and ALAC in M4A, FLAC, WAV, AIFF, Ogg Vorbis, Opus, a byte-identical copy, a re-encode, remix/live/clean versions, two same-titled tracks of different length, Unicode/space paths, random-byte “corrupt.mp3”, a truncated FLAC, an empty MP3, a WMA and a text file. Tests always work on a temporary copy.

### Integration tests mapped to acceptance criteria

| Acceptance criterion | Test |
|---|---|
| Folder scanned without changing source files; hashes and timestamps unchanged | `scanning_never_modifies_source_files` (BLAKE3 + size + mtime of every file before/after scan **and** duplicate hashing); e2e final step (SHA-256 + size + mtime) |
| Search and filters return correct results | `search_and_filters_return_correct_results`, e2e search steps |
| Data and crates persist after restart | `data_and_crates_persist_after_restart`, e2e restart step |
| SQL-like text cannot execute SQL | `sql_like_input_cannot_execute_sql` (search text, rule values, tag names, crate names, assistant, field/operator/sort names) + unit tests |
| Low-bitrate lossy file flagged | `low_bitrate_rule_is_honest` (96k MP3, 64k AAC flagged; exactly 128k not flagged) |
| Lossless/unknown not flagged | same test (FLAC/WAV/AIFF/ALAC with low numeric bitrate → lossless; unreadable → unknown) |
| Exact vs possible labelled differently | `exact_possible_and_alternate_duplicates_are_separated`, `hash_cache_is_invalidated_when_file_changes` |
| Unicode paths, spaces, unreadable and corrupt files handled | `reads_metadata_and_technical_properties`, `corrupt_unsupported_and_empty_files_are_reported_not_fatal` |
| Cancel/interruption does not corrupt catalogue | `cancelled_scan_leaves_catalogue_consistent` (PRAGMA integrity_check, nothing marked missing), `interrupted_scan_is_recovered_on_restart` |
| Disconnected drives not treated as deleted | `disconnected_drive_is_offline_not_deleted`, `deleted_files_are_marked_missing_not_removed` |
| No network during offline scanning | `scripts/check-no-network.sh`; e2e asserts the UI made no non-loopback requests |
| Symlink loops | `symlink_loops_do_not_hang` (Unix only) |

## Manual tests — NOT yet performed (v0.1 and v1.0)

These need a real Windows 10/11 PC. Please record date, Windows version and result.

| # | Test | Expected |
|---|---|---|
| M1 | Install from the release `.exe`; SmartScreen warning appears | “More info → Run anyway” installs per-user; app starts |
| M2 | Verify the SHA-256 of the downloaded installer | Matches `SHA256SUMS.txt` |
| M3 | Add a copy of a real music folder (thousands of tracks) | Scan completes; UI stays responsive; pause/resume/cancel work |
| M4 | Before/after scan, compare hashes of a sample of files (`Get-FileHash`) and Serato’s view | Identical; Serato shows no changes |
| M5 | Add a folder on a USB drive, scan, unplug, rescan | Folder shows offline; tracks kept; plug back in → online |
| M6 | Open a track in another app that locks it (or set file to deny read), scan | File reported as unreadable; scan completes |
| M7 | Paths with Unicode, very long paths (>260 chars), network drive | Handled or clearly reported |
| M8 | Run DJ Assistant while Serato DJ is open on the same library | No interference; Serato unaffected |
| M9 | Library of 50k+ tracks | Search/filter feel instant; memory reasonable |
| M10 | Keyboard-only use and Windows Narrator | All views reachable; controls announced |
| M11 | Uninstall | App removed; catalogue remains in `%APPDATA%` (by design) unless deleted manually |
| M12 | Analyse 200+ real tracks; compare BPM/key with Serato's values | Mostly agree; differences are half/double tempo or related keys |
| M13 | Turn on tag writing; on COPIES of 5 Serato-analysed MP3s change the genre; open them in Serato | Cues, loops and beatgrids intact; genre updated; rollback restores |
| M14 | Gig pack to a real USB stick; open playlist.m3u8 on another laptop | Files present and playable; manifest hashes match |
| M15 | Import real Serato crates (from a COPY of `_Serato_`) and a history CSV | Crates and plays match what Serato shows |
| M16 | Add MusicBrainz, AcoustID and Last.fm keys; run lookups | Suggestions/recommendations appear with sources; keys visible in Credential Manager only |
| M17 | Install v1.0.0, publish a v1.0.1 (after hosting is public and signing secrets are set) | App offers the update, installs and restarts with data kept |
| M18 | Custom title bar: drag, double-click maximise, snap, minimise/close | Behaves like a normal window |

## Manual tests for 1.2 (Quick Prep and accounts) — NOT yet performed

1. On Windows, open Quick Prep, choose a folder of real downloads, and check the names, BPM and key it shows.
2. Press play on a few tracks (MP3, FLAC, WAV, M4A) and click the waveform to jump — this exercises the desktop `track:` protocol, which automated tests cover only through the dev bridge.
3. Export each path to a USB stick as a folder and as a ZIP; import the `.m3u8` files into Serato and check names, BPM, key and any cue points in the tagged copies.
4. With the AI assistant on (Claude with a real key, and a local Ollama model), try *Improve with AI* and a typed playlist request in Quick Prep.
5. Create a second account, add a different folder, switch back and forth, rename and remove an account; restart the app and check it reopens the last account.

## Serato

DJ Assistant reads Serato data (crates, `database V2`, history, and the cues, loops and beatgrids in file tags) and never writes Serato's databases, cues, beatgrids, history or existing crates. Exporting crates adds new `.crate` files only. Every Serato test must use a **disposable copy** of a Serato library (see W6–W12 above).
