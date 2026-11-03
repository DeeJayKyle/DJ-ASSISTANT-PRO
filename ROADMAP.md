# Roadmap

Status key: **Tested** = implemented and covered by automated tests · **Implemented** = built, needs more testing · **Planned** = not built yet.
“Manual Windows test pending” means it has passed automated tests (including on a Windows CI runner where noted) but nobody has yet tried it by hand on a real Windows PC with a real library.

## Phase 1 — v0.1 safe foundation

| Feature | Status |
|---|---|
| Select music folders / external drives (picker + typed path) | Tested (automated); manual Windows test pending |
| Read-only recursive scan, unchanged-file skip | Tested |
| Pause / resume / cancel scan; interruption recovery | Tested |
| Symlink loops avoided; Unicode and spaces in paths | Tested (Linux CI); Windows path tests run in Windows CI |
| Windows case-insensitive path identity | Tested (unit) |
| Missing folders / disconnected drives → offline, not deleted | Tested |
| Locked, corrupt, empty and unsupported files reported, not fatal | Tested (corrupt/empty/unsupported); locked files: manual Windows test pending |
| Persistent SQLite catalogue with migrations | Tested |
| Tag + technical property extraction (MP3, FLAC, WAV, AIFF, M4A AAC/ALAC, Ogg, Opus) | Tested |
| APE, WavPack, Musepack | Implemented (library support; no fixtures yet) |
| Search and filters, sort, decade, ranges | Tested |
| SQL injection resistance (search, rules, crate names, assistant) | Tested |
| Catalogue-only values: energy, rating, colour, mood, tags, notes, overrides | Tested |
| Manual crates, smart crates (AND/OR, ranges, exclusions, manual additions), preview | Tested |
| Configurable low-bitrate warning (lossless/unknown never flagged) | Tested |
| Duplicate review: exact (full hash) vs possible vs alternate; review notes | Tested |
| Library health view | Tested |
| Rule-based assistant sidebar (hide / full screen) — not AI | Tested |
| Privacy/read-only notice | Tested (e2e) |
| No network during scanning | Tested (dependency audit + strace on Linux) |
| Windows NSIS installer (unsigned) + SHA-256 | Built in Windows CI |
| Keyboard navigation (/ search, arrows, Space, Enter, Ctrl+A, Ctrl+J) | Implemented; partial e2e |

## Phase 2 — knowledge and suggestions

| Feature | Status |
|---|---|
| Folder watching with organisation suggestions | Planned |
| Suggestions model (existing vs suggested value, source, evidence, confidence; accept/reject/edit) | Planned |
| MusicBrainz lookup (opt-in, rate-limited, attributed) | Planned |
| Chromaprint/AcoustID fingerprint candidates (opt-in, per-lookup consent) | Planned |
| Distinguish original / remix / reissue / edition year | Planned |
| Last.fm similar artists/tracks (opt-in) | Planned |
| Windows Credential Manager for API keys | Planned |
| Read-only Serato crate/history import (tested on disposable library copy first) | Planned |

## Phase 3 — audio analysis

| Feature | Status |
|---|---|
| BPM with half/double-time ambiguity, key, energy, mood estimates (versioned, overridable) | Planned |
| Waveforms, intro/outro, cue/mix point suggestions | Planned |
| Loudness, silence, clipping, beatgrid issue hints | Planned |
| Fingerprint-assisted duplicate candidates | Planned |

## Phase 4 — discovery and sets

| Feature | Status |
|---|---|
| Crate-fit recommendations, gaps, related artists/labels — each explained with source and date | Planned |
| Tracklist import and owned / possibly owned / missing matching | Planned |
| Inspect, disable and reset learned preferences | Planned |
| Legitimate purchase/download source links (no ripping, no DRM bypass) | Planned |
| Set studio: event, duration, energy journey, editable running order, alternatives | Planned |
| Gig mode (offline essentials, pause background work) | Planned |
| Gig pack: preview, disk-space check, copy, verify, manifest, missing-file report | Planned |
| Request queue, DJ notes, play-history import, post-gig recap | Planned |
| Local stem separation (if technically and legally feasible) | Planned |

## Phase 5 — safe file changes

| Feature | Status |
|---|---|
| Tag writes / renames / moves with exact preview, conflict check, verified backup, approval, change log, rollback | Planned |
| Warnings for Serato link, cue, beatgrid and crate impacts | Planned |
| Replacement workflow for low-quality files | Planned |

## Phase 6 — personal files (separate, opt-in)

| Feature | Status |
|---|---|
| Index selected folders, search names and supported document contents locally | Planned |
| Duplicate / unreadable / encrypted document flags, organisation suggestions | Planned |
