# Architecture (1.x, legacy)

> This describes DJ Assistant **1.x** (Tauri + Rust + React), which stopped at 1.8.1. The current release is 2.x, written in Dart and Flutter in `dj_assistant_flutter/`. See `dj_assistant_flutter/MIGRATION.md` for how each 1.x part maps to 2.x, and `dj_assistant_flutter/README.md` for the 2.x layout. Both versions share the same catalogue schema.

## Why this stack

**Tauri 2 + Rust + React/TypeScript + SQLite.**

- **Small, native Windows app.** Tauri uses the system WebView2 instead of bundling Chromium, so the installer is a few MB and memory use is modest — useful on a DJ laptop that also runs Serato.
- **Rust for the parts that touch your files.** Scanning, tag reading and hashing run in Rust worker threads with no garbage-collection pauses and strong guarantees against memory bugs when parsing damaged files. A parser panic on a corrupt file is caught and recorded as an error for that file.
- **One testable core.** All logic lives in `crates/dj-core`, a plain Rust library with **no Tauri and no networking dependencies**. It is fully tested on Linux and Windows CI. The desktop shell is a thin wrapper.
- **SQLite** (bundled, public domain) gives a single local catalogue file with transactions, WAL mode and migrations.
- **React + TypeScript** for an accessible, keyboard-friendly UI. Fonts are bundled; nothing is loaded from the internet.

Alternatives considered: Electron (larger installer, bundles Chromium, larger attack surface), .NET WPF/WinUI (good Windows fit but weaker cross-platform test story here and fewer mature tag libraries with permissive licences than `lofty`).

## Layout

```
crates/dj-core/        core library (no network, no Tauri)
  src/db.rs            SQLite open, pragmas, numbered migrations, settings
  src/scanner.rs       read-only scan: walk → stat → bounded worker pool → batched writer
  src/metadata.rs      lofty-based tag/property reading, codec + lossless detection
  src/rules.rs         rule JSON → SQL with whitelisted fields/operators, bound params
  src/library.rs       search, track detail, catalogue-only edits, tags, facets, stats
  src/crates.rs        manual + smart crates, membership, preview
  src/duplicates.rs    exact (full BLAKE3), possible, alternate; review decisions
  src/health.rs        health categories (each is a rule set)
  src/assistant.rs     rule-based request parser (not AI)
  src/api.rs           App: JSON command dispatcher + background jobs
  tests/               integration tests on copies of tests/fixtures/library
  src/analysis.rs      decode (Symphonia) + BPM/key/energy/loudness/cues/waveform/fingerprint
  src/analysis_store.rs  analysis persistence, background job, library-relative energy
  src/suggest.rs       suggestions (local heuristics, MusicBrainz, AcoustID) — catalogue-only accept
  src/online.rs        traits for online services and secrets (no network code here)
  src/templates.rs     cheat-sheet crate templates, labels, crate hygiene
  src/discovery.rs     crate fit, gaps, overplayed, tracklists, Last.fm/MusicBrainz items, learning
  src/sets.rs          Set Studio planner; src/gig.rs gig mode; src/gigpack.rs verified USB copies
  src/safe_write.rs    the only module that edits music files (opt-in, backed up, reversible)
  src/serato.rs        read-only Serato crate + history CSV import
  src/docs.rs          personal files index; src/watcher.rs folder watcher; src/jobs.rs job manager
  src/accounts.rs      local accounts (no sign-in): accounts.json + one catalogue per account; Session dispatcher
  src/media.rs         read-only range streaming of catalogued tracks for previews
  src/quick.rs         Quick Prep's optional AI help: prompts, defensive parsing, URL checks
crates/dj-online/      the only networked crate: MusicBrainz, AcoustID, Last.fm (ureq + rustls)
crates/dj-devbridge/   DEV ONLY loopback HTTP bridge for browser e2e tests
src-tauri/             desktop shell: one `api` command → App::dispatch
src/                   React UI (src/lib/quick: name cleanup, genres, set ordering, export layouts;
                       src/components/quick: the Quick Prep screens)
e2e/run.mjs            Playwright end-to-end test
scripts/               fixture generator, read-only guard, no-network check, licence check
```

## Data model (catalogue)

- `library_roots` — folders you added; `status` online/offline.
- `tracks` — one row per file. **Original file values** (title, artist, genre, BPM tag…) and technical properties. Stable internal `id` and random `uid`; identity by a normalised path key (NFC, case-folded on Windows). `presence` present/missing; `read_status` ok/error/unsupported. Full-file hash is cached with the size and mtime it was computed for and ignored if either changes.
- `track_user` — **values you choose**, stored only here (energy, rating, colour, mood, notes, overrides). Displayed values are `COALESCE(yours, file)`; both are visible in track detail.
- `tags`, `track_tags`, `crates`, `crate_tracks` (include/exclude), `duplicate_reviews`, `scans`, `scan_errors`, `settings`.
- Suggestions from analysis/online sources (the third category in the brief) will get their own table in Phase 2 so they never mix with file or user values.

## Accounts

`accounts::Session` sits in front of `App`. `accounts.json` in the app data folder lists the accounts and the last one used; each account's catalogue is its own SQLite file (`accounts/<id>/catalogue.sqlite3`, or the original `catalogue.sqlite3` for an account migrated from before 1.2). Switching closes one `App` and opens another; it's refused while a scan or job runs. The UI remounts on a switch. API keys in Credential Manager are shared by the accounts on the computer.

## Quick Prep export

The UI builds a layout (folder and file name per track, playlists) and sends it to `gigpack_preview` as `options`. The gig pack copier sanitises every path segment, never overwrites, verifies each copy by BLAKE3, and for ZIPs streams stored entries into `<name>.zip.part` before renaming. With tags on, `safe_write::tag_new_copy` writes catalogue values into the **new copy** and checks its audio data hash is unchanged.

## Scanning

1. If the folder is unavailable → mark offline, record a problem, keep its tracks. Stop.
2. Walk the tree without following symlinks/junctions. Only known audio extensions are considered; unsupported music formats are recorded as such.
3. Files whose size and modified time are unchanged (and previously readable) are only marked as seen.
4. Others go through a bounded channel to 1–4 reader threads (`catch_unwind` around the parser), and a single writer commits batches of 100 in a transaction.
5. Pause/cancel flags are checked between files. On cancel nothing is marked missing.
6. After a completed walk, if the folder is **still** available, tracks not seen are marked missing (never deleted).

## Online services

`dj-core` defines `Online` and `Secrets` traits; the desktop shell injects `dj_online::Http` and a Windows Credential Manager store (`keyring`). Every online command first checks that the DJ enabled the service (`svc_*` settings). MusicBrainz is rate-limited to one request per second with a descriptive User-Agent; AcoustID requires explicit confirmation per batch and sends only the compressed Chromaprint fingerprint and duration.

## AI assistant

`dj-core/src/agent.rs` runs the conversation; `dj-online/src/llm.rs` talks to the model (Claude over the Messages API, or Ollama on 127.0.0.1). The system prompt is `docs/ASSISTANT_GUIDE.md`, compiled into the app and cached by the API along with the tool list. Each tool maps onto an existing `App::dispatch` command and has a tier:

- **read**: runs automatically;
- **ui**: changes only the screen, applied by the front end;
- **act**: becomes an action card and runs only after the DJ approves it (`ai_confirm`).

Assistant turns are kept exactly as returned, so thinking blocks go back unchanged. Tool results are stripped of anything that looks like a file path before they reach the model. No tool can write, move or delete files or touch Serato data. The devbridge's `--demo-ai` flag swaps in a scripted model for the browser e2e test.

## Updates

`tauri-plugin-updater` with a minisign public key in `tauri.conf.json`; see docs/UPDATES.md.

## UI

React + TypeScript, Inter (bundled), Lucide icons. Design tokens in `src/styles.css`: dark glass with a mint accent per the mock-up; motion system adapted from RxPos (spring/out easing tokens, page/card entrances, light beam via `@property --beam`, success tick, row flash). Everything respects reduced motion (OS setting or Settings → Motion).

## Security notes

- Every SQL statement uses bound parameters. Dynamic SQL is assembled only from whitelisted field expressions/operators/sort columns; integers like the bitrate threshold are validated before inlining. `trusted_schema=OFF`.
- The Tauri window CSP: `default-src 'self'; connect-src ipc: http://ipc.localhost`. Capabilities: core defaults, window controls for the custom title bar, open/save dialogs, opening https URLs, process restart and the updater. No shell, filesystem or HTTP plugins are exposed to the web view; all network traffic happens in Rust (`dj-online`, updater).
- The production front-end bundle is checked to contain no dev-bridge code (the bridge is compiled in only with `VITE_DEV_BRIDGE=1`).
