# Roadmap

**Tested** = implemented with automated tests (Rust integration tests on Linux and Windows CI and/or the browser e2e test). **Implemented** = built and exercised, limited automated coverage. **Planned** = not built.
Every item still needs **manual testing on a real Windows PC with a real library** (see docs/TESTING.md).


## v1.4 (this release)

| Area | Feature | Status |
|---|---|---|
| Auto-prep | Analysis + suggestions + recommended fixes after every scan (catalogue only), run on demand | Tested |
| Organise Files | Tags from catalogue, rename by template, sort into folders, folder rename, restorable removal, duplicate replace, undo | Tested (integration + e2e rename/undo) |
| Export | Serato .crate (round-trip with our importer), rekordbox XML, folders | Tested; not yet opened in real Serato/rekordbox |
| Look & sound | Colour presets, custom accent, backgrounds, transitions, speed, sounds | Tested (e2e theme); sounds checked in code only |
| Windows | Splash, close animation, taskbar icon, tray icon, dark first frame, optimised build | Builds; needs a check on a real Windows PC |

## v1.3

| Area | Feature | Status |
|---|---|---|
| Quick Prep | Add a folder → read-only scan → analysis → four paths (clean names, playlist, folders, genres) | Tested (e2e) |
| Quick Prep | Name cleanup rules, name format, inline edits, genre families, set ordering, plain-word sort requests | Tested (unit + e2e) |
| Quick Prep | Export as verified folder copy, ZIP, or playlists only; layouts with sub-folders and a playlist per folder | Tested (Rust integration + e2e) |
| Quick Prep | Clean tags written into new copies only (MP3, FLAC, M4A), audio data verified unchanged | Tested (MP3, FLAC) |
| Quick Prep | Track previews (read-only `track:` protocol with range requests, catalogued tracks only) and waveform | Tested (bridge); desktop protocol needs a manual check on Windows |
| Quick Prep | AI help for names, genres and set orders, using the assistant's model (Claude or local) | Tested with a fake model and the scripted demo model |
| Accounts | Several local accounts, no sign-in; separate catalogues; rename/remove; existing catalogue migrates | Tested (Rust + e2e) |

## v1.2

| Area | Feature | Status |
|---|---|---|
| AI assistant | Built-in app knowledge (docs/ASSISTANT_GUIDE.md as the system prompt, cached) | Tested |
| AI assistant | 31 tools over the app's commands: read (auto), screen (auto), actions (approval cards) | Tested (scripted model) |
| AI assistant | Claude provider (Messages API, raw HTTPS, refusal fallback, prompt caching) | Implemented; request shape unit-tested, no live call possible here |
| AI assistant | Local provider (Ollama, loopback only) | Tested against a fake server; not against a real Ollama |
| AI assistant | No file paths in tool results; no file-changing tools | Tested |
| Chat | /commands for app tasks, with or without AI | Tested (e2e) |

## v1.1

| Area | Feature | Status |
|---|---|---|
| Keys | Camelot / musical display setting; either notation in search, rules and Assistant (incl. Open Key) | Tested |
| Library health | Fix list for missing title/artist, genre, year, album, BPM, key: hints with evidence, bulk set, catalogue-only save | Tested |
| Video | MP4/M4V/MOV/MKV/WebM/AVI header parsing (resolution, codec, fps, duration, tags); media/resolution filters; never written | Tested |
| Video | Audio analysis of MP4/MOV/MKV/WebM where the codec is supported | Tested (AAC, Vorbis) |
| UI | Premium UI switch (Midnight Pro look from RxPOS) | Tested (e2e) |

## v1.0

| Area | Feature | Status |
|---|---|---|
| Library | Folder/drive selection, read-only scan, pause/resume/cancel, offline drives, missing files, Unicode/symlinks | Tested |
| Library | Search, quick filters (genre/decade/format/quality), rule builder, sorting, virtualised table | Tested |
| Library | Folder watcher with organisation suggestions (never moves files) | Tested |
| Catalogue | Energy, rating, colour, mood, tags, notes, overrides (title, artist, album, genre, year, original year, BPM, key, label, version, clean/explicit) | Tested |
| Crates | Manual + smart crates, nesting, manual additions/exclusions, preview | Tested |
| Crates | Cheat-sheet templates (genres, energy, utility, events, ratings, decades, genre-by-energy), labels, colour-by-energy, hygiene | Tested |
| Export | M3U8 and CSV export of crates, sets and selections | Tested |
| Analysis | BPM (+alt), key/Camelot, energy (library-relative), LUFS, peak, clipping, silence, intro/outro, cues, waveform, tempo drift, fingerprint | Tested (synthetic audio; accuracy on real music to be validated) |
| Suggestions | Local heuristics, analysis, accept/edit/reject, bulk accept | Tested |
| Suggestions | MusicBrainz (original year, album, label, genre), AcoustID fingerprint lookup | Tested with fakes; live calls not yet verified |
| Duplicates | Exact (full hash) vs possible vs alternate, review notes | Tested |
| Quality | Configurable low-bitrate rule (lossless/unknown never flagged) | Tested |
| Health | Missing metadata, unreadable, unsupported, offline, missing, last-scan problems | Tested |
| Discovery | Crate fit, gaps, overplayed alternatives, version-aware tracklist matching, learning inspect/disable/reset, store links | Tested |
| Discovery | Last.fm similar artists/tracks, MusicBrainz new releases for followed artists | Tested with fakes; live calls not yet verified |
| Set Studio | Planner with energy curves, transition notes, alternatives, emergency tracks, save/export/crate | Tested |
| Gig | Gig mode (requests, notes, play log, background pause), recap + export | Tested |
| Gig | Gig pack: preview, free-space check, verified copy, manifest, playlist, missing report | Tested |
| Serato | Read-only crate import, history CSV import | Tested (synthetic crate files; real Serato files to be validated) |
| Safety | Opt-in tag writing with preview, change check, verified backup, audio + Serato GEOB preservation, atomic replace, rollback | Tested (MP3 GEOB case); FLAC/M4A writing implemented, lighter coverage |
| Personal files | Opt-in index, text search (txt/md/csv/json/docx/odt…), duplicates, encrypted/unreadable flags, organisation ideas | Tested |
| Assistant | Rule-based search/filter/navigation incl. set planning requests | Tested |
| App | Glass UI per mock-up, RxPos motion, light/dark, glass/solid, reduced motion, custom title bar | Implemented (visual e2e screenshots) |
| App | Signed auto-update via GitHub releases | Implemented; needs public release hosting + signing secret (docs/UPDATES.md) |
| Privacy | No network in core (dependency audit + syscall trace), Credential Manager for keys | Tested (Linux); Credential Manager on Windows not yet hand-tested |

## Later

| Feature | Status |
|---|---|
| Accuracy validation of analysis on Herbie's real library; tuning | Planned |
| Waveform zoom and beatgrid view; Serato cue comparison (read-only) | Planned |
| Charts / radio-show / festival tracklist sources (permitted APIs only) | Planned |
| Request queue from phones on the same network | Planned |
| Local stem separation (only if a permissively licensed, offline model is practical) | Planned |
| Code-signed installer | Planned (needs a certificate) |
| Physical folder organisation (moves/renames) | Not planned by default — breaks Serato links; would need the full safety process |
