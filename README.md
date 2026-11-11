# DJ Assistant

A local-first Windows app that helps a working DJ organise, analyse, plan and prepare — **without risking the music library**. Built for Herbie, who plays out with Serato DJ.

BPM and key data provided by [GetSongBPM](https://getsongbpm.com).

![Music Library](docs/screenshots/library.png)

> **Current release: DJ Assistant 2.x (Flutter), in [`dj_assistant_flutter/`](dj_assistant_flutter/).** It is what the Releases page publishes and what installs update to. The 1.x app (React + Tauri + Rust, in `src/`, `src-tauri/` and `crates/`) stopped at 1.8.1 and is kept for reference and for the shared catalogue schema; see [Legacy 1.x](#legacy-1x-react--tauri) below.

## What it does (2.4)

**Library** — choose music folders and drives, or drag folders and files onto the window (files are copied into the Inbox, never moved); read-only background scanning with pause/resume/cancel; tags and technical properties for MP3, FLAC, WAV, AIFF, M4A (AAC/ALAC), Ogg, Opus and more; accent-insensitive search; Genre / Decade / Format / Quality filters plus a rule builder; select with click, Ctrl/Shift-click, arrow keys, Ctrl+A and Ctrl+I; right-click for a menu; offline drives kept, never treated as deleted; folder watcher and optional Inbox auto-import of finished downloads.

**Your catalogue** — energy (1–10), star ratings, colour, mood, tags, notes and your own title, artist, album, genre, year, original year, BPM, key, label and version. Stored in DJ Assistant only; the file's own tags stay visible separately.

**Virtual crates** — manual and smart crates (AND/OR rules, ranges, exclusions, manual additions), nested folders and one-click templates: genres, energy (Peak Time 9–10 → Cool Down 1–2), utility, events, ratings, decades and genre-by-energy. Crate-hygiene warnings. Export as M3U8, CSV, Serato `.crate` (new files only), rekordbox XML or verified folder copies.

**Quick Prep** — a fast lane for a folder of fresh downloads: clean names, build a playlist, organise into gig folders, split by genre; exported as verified copies, a ZIP or playlists pointing at the originals. Tags are only ever written into the new copies.

**Audio analysis (local)** — BPM with half/double alternatives, whole-file beatgrid, key with Camelot code, energy, loudness (LUFS), peak, clipping, silence, intro/outro, cue ideas, waveform and fingerprint. Shown as estimates; your values always win. Serato's own BPM, beatgrid, hot cues and saved loops are read from the file tags (never written).

**Suggestions — review first (new default in 2.4)** — fixes from file names, folders, spellings, analysis and the online services you turn on, each with the current value, suggestion, source, evidence and confidence. Approve or reject one at a time, or tick a batch. Accepting changes the catalogue only, never the file, and **Undo restores the exact previous value**. See [Auto-prep and suggestions](#auto-prep-and-suggestions).

**Organise Files mode (opt-in, off by default)** — edit tags in the files, rename and move files or folders, replace a track with a better file, remove exact duplicates and bad files. See [Organise Files](#organise-files).

**Upgrades (new in 2.4)** — lossy tracks below your low-bitrate warning (configurable, default 128 kbps; lossless and unknown are never flagged). For each one: better copies you already own, a side-by-side comparison with two players at matched loudness, legitimate store search links, and "Replace…" through Organise Files' preview. **Bitrate is treated as a clue, never as proof of quality.**

**Duplicates & health** — exact (full-file hash), possible and alternate versions with reasons; library health for missing metadata (with a Fix list), unreadable/unsupported files, low bitrate, offline drives and missing files.

**Discovery** — tracks that fit a crate, gaps, alternatives to overplayed tracks, tracklist and playlist-file matching with a shopping list CSV, Last.fm similar artists and MusicBrainz new releases (both opt-in, each saying what it sends), and store search links. Recommendations come from your own library and the services you turn on; nothing is hard-coded.

**Set Studio, Gig Mode & Gig Pack** — running orders with mix grades and rules; offline gig mode with requests, notes, play log and **Next up** (can follow Serato DJ 4's history, read from a copy); verified USB gig packs.

**Serato, rekordbox & history** — read-only import of Serato crates, Serato DJ 4 play history and history CSVs, and rekordbox XML playlists. Serato cues and beatgrids carried into rekordbox XML exports.

**Studio** — Stems (fast DSP split, or Pro Stems AI from an optional pack), Remix, DJ Decks, Synth Lab and Drum Lab. Saves only new files.

**Assistant** — open by default on the right. Drag its edge (or focus it and use ←/→) to resize, expand it to full width (Ctrl+Shift+J) or hide it (Ctrl+J); on a narrow window it floats over the page. The built-in helper and /commands work offline; an AI model (free online options, your own Claude/OpenAI/… key, any OpenAI-compatible server, or Ollama on this computer) is opt-in. Actions appear as cards that run only when you press Run. It can never change music files and cannot turn on file changes.

**Look and keys** — dark/light themes, five accents, glass/solid panels, reduced motion, Premium UI; Camelot or musical key notation; F1 lists every keyboard shortcut.

**Local accounts** — no sign-in; each account keeps its own catalogue on this computer.

## Auto-prep and suggestions

Auto-prep runs after scans and imports (switch in Settings → Library). It analyses new tracks and creates suggestions. What happens next is your choice in **Settings → Library → Metadata suggestions**:

| Mode | What auto-prep does |
|---|---|
| **Review first** (default from 2.4) | Changes nothing. Every suggestion waits in Suggestions for your approval. |
| Fill empty fields | Fills empty fields from the best evidence. Never replaces a value you already have. |
| Apply confident fixes | The behaviour before 2.4: fills empty fields and replaces existing values at or above the confidence slider (default 85%). |

All three only touch DJ Assistant's catalogue, never the files. From 2.4 every accepted suggestion records what it replaced and who accepted it ("by you" or "automatic"), so **Undo** under Suggestions → Accepted (or **Undo automatic changes…** in Settings) puts the exact previous value back, unless you have changed it since. Values accepted before 2.4 show as "earlier" and can't be undone exactly, because their previous values weren't kept.

## Organise Files

Off by default, with its own switch (Settings → Changes to music files, or the Organise Files page). Libraries that already allowed file changes before 2.4 keep it available.

- **Nothing happens silently.** Every action opens a preview listing **every** item with a tick. Name conflicts and missing files are blocked; only ticked items run, after a second confirmation; each file is re-checked and skipped if it changed since the preview.
- **Verified and restorable.** Tag edits use the safe tag writer: per-file preview, a verified (BLAKE3) backup, Serato's cue and beatgrid data kept byte for byte, rollback from the change log. Renames and moves check each file's hash before and after. Removed and replaced files go to a **Removed files** area in the app's data folder, outside your music. Nothing is permanently deleted until you empty that area, after seeing the full list.
- **Undo.** History undoes one change or a whole batch; a replacement is always undone as a whole.
- **Serato warnings per track.** The preview reads, never writes, Serato's `database V2`, its crates and the cue, loop and beatgrid data in each file, and says which tracks Serato knows about. Renaming or moving those files breaks Serato's links until you use Serato's *Files → Relocate lost files*. A replacement with the same format keeps the file name, so Serato's crates still find it, but cues and beatgrids stored inside the old file don't carry over to the new one. The old file is kept.
- **Scope.** Work on tracks sent from the Library ("Organise…"), a crate, or every track.

Test on copies of your music first.

## Safety

- Music files are only read unless you turn on tag writing or Organise Files mode (both off by default). Quick Prep, Gig Pack and exports only create new files and folders.
- Serato's databases, cues, beatgrids, history and settings are never written, and existing Serato crates are never changed. Exporting a crate to Serato adds a new `.crate` file in `_Serato_/Subcrates`, never overwriting one.
- The AI assistant has no tool that changes, moves or deletes files, and cannot change the file-change switches or the suggestion mode.

## Privacy

- No online account and no telemetry; accounts are local to this computer.
- Every online service (MusicBrainz, AcoustID, the Deezer and Apple Music catalogues, Spotify, YouTube, GetSongBPM, Last.fm, an online AI model, update checks) is **off by default**, except update checks, which send only the app version and can be turned off. Each one says exactly what it sends, in Settings next to its switch and in Discovery where it is used. Store links are plain links: nothing is sent until you open one.
- API keys go to Windows Credential Manager and are never shown, logged or stored in the catalogue.
- A test (`test/network_audit_test.dart`) checks that nothing is sent until a service is on, and only to that service.

## Install (Windows 10/11, 64-bit)

1. Download `DJ-Assistant_<version>_x64-setup.exe` and `SHA256SUMS.txt` from Releases.
2. Verify: `Get-FileHash .\DJ-Assistant_<version>_x64-setup.exe -Algorithm SHA256` and compare with `SHA256SUMS.txt`.
3. Run it (per-user install, no admin needed). The installer is **not code-signed**, so SmartScreen may warn about an unknown publisher; choose *More info → Run anyway* if the checksum matches.
4. Later versions arrive through **Settings → Updates**. Updates are signed with the same key as 1.x, so 1.8 installs update to 2.x in place and keep their data.

## Build from source (2.x)

Flutter 3.47.9 (stable). On Windows, Visual Studio with the C++ desktop workload.

```bash
cd dj_assistant_flutter
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test                 # unit, service and screen-layout tests (Linux or Windows)
flutter test integration_test -d windows   # drives the real app
flutter build windows --release
```

`SCREENSHOTS=<folder> flutter test test/screens` writes a screenshot of every page at seven window sizes (900×600 to 1920×1080), dark and light. Tests always work on temporary copies of the synthetic fixture library in `crates/dj-core/tests/fixtures/`. See [docs/TESTING.md](docs/TESTING.md), [dj_assistant_flutter/MIGRATION.md](dj_assistant_flutter/MIGRATION.md), [ROADMAP.md](ROADMAP.md) and [docs/UPDATES.md](docs/UPDATES.md). Release notes: [docs/RELEASE_NOTES_2.md](docs/RELEASE_NOTES_2.md).

## Known limitations

- **Not yet hand-tested on a real Windows PC with a real library and Serato.** Automated tests run on Linux and Windows CI with synthetic files. Please work through the 2.4 checklist in [docs/TESTING.md](docs/TESTING.md), starting with copies of your music.
- Installer not code-signed (SmartScreen warning).
- Analysis is estimation: half/double tempo and relative-key confusion happen; energy is relative to your library. Ogg Vorbis and Opus are catalogued but not analysed.
- Serato file formats follow community documentation. They are only read, and may need updates if Serato changes them.
- Live calls to online services and AI providers can't be made from the build environment; they are tested with recorded responses and fakes.

## Legacy 1.x (React + Tauri)

1.x (last release 1.8.1) is a Tauri app: a Rust engine in `crates/dj-core` and `crates/dj-online`, a React/TypeScript interface in `src/`, and the shell in `src-tauri/`. Its workflows (`ci.yml`, `release.yml`) still build it, but new releases come from `release-flutter.yml`. 2.x opens the same catalogue (`catalogue.sqlite3`, the same numbered schema) and `accounts.json`. New 2.x data lives in extra tables that 1.x ignores, so a library can still be opened by 1.8. Features added after 2.0 exist only in 2.x.

To build 1.x: Rust 1.97, Node 22, then `npm ci`, `cargo test -p dj-core -p dj-online`, `npm test`, `npx tauri build --config src-tauri/tauri.ci.conf.json`.

## Licence

MIT. Third-party licences: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
