# Architecture

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
crates/dj-devbridge/   DEV ONLY loopback HTTP bridge for browser e2e tests
src-tauri/             desktop shell: one `api` command → App::dispatch
src/                   React UI
e2e/run.mjs            Playwright end-to-end test
scripts/               fixture generator, read-only guard, no-network check, licence check
```

## Data model (catalogue)

- `library_roots` — folders you added; `status` online/offline.
- `tracks` — one row per file. **Original file values** (title, artist, genre, BPM tag…) and technical properties. Stable internal `id` and random `uid`; identity by a normalised path key (NFC, case-folded on Windows). `presence` present/missing; `read_status` ok/error/unsupported. Full-file hash is cached with the size and mtime it was computed for and ignored if either changes.
- `track_user` — **values you choose**, stored only here (energy, rating, colour, mood, notes, overrides). Displayed values are `COALESCE(yours, file)`; both are visible in track detail.
- `tags`, `track_tags`, `crates`, `crate_tracks` (include/exclude), `duplicate_reviews`, `scans`, `scan_errors`, `settings`.
- Suggestions from analysis/online sources (the third category in the brief) will get their own table in Phase 2 so they never mix with file or user values.

## Scanning

1. If the folder is unavailable → mark offline, record a problem, keep its tracks. Stop.
2. Walk the tree without following symlinks/junctions. Only known audio extensions are considered; unsupported music formats are recorded as such.
3. Files whose size and modified time are unchanged (and previously readable) are only marked as seen.
4. Others go through a bounded channel to 1–4 reader threads (`catch_unwind` around the parser), and a single writer commits batches of 100 in a transaction.
5. Pause/cancel flags are checked between files. On cancel nothing is marked missing.
6. After a completed walk, if the folder is **still** available, tracks not seen are marked missing (never deleted).

## Security notes

- Every SQL statement uses bound parameters. Dynamic SQL is assembled only from whitelisted field expressions/operators/sort columns; integers like the bitrate threshold are validated before inlining. `trusted_schema=OFF`.
- The Tauri window CSP: `default-src 'self'; connect-src ipc: http://ipc.localhost`. Capabilities: core defaults + folder-open dialog. No shell, filesystem, HTTP or updater plugins.
- The production front-end bundle is checked to contain no dev-bridge code (the bridge is compiled in only with `VITE_DEV_BRIDGE=1`).
