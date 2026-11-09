# DaJent 1.0.11-a: design study

A record of a static look at the DaJent 1.0.11-a Windows installer (with REA and
standard unpacking tools), and how DJ Assistant 2.1.2 and 2.2.0 answer the parts
that fit a local-first app **with its own code**.

**Ground rules.** Nothing from DaJent is in DJ Assistant: no code, no strings,
no artwork, no keys or endpoints. Nothing was run; the installer was only
unpacked and read. The study looked at *what* features do and *which inputs and
outputs* they have, then the features were written from scratch in Dart to fit
DJ Assistant's own data (Camelot keys, energy 1–10, local analysis). File
formats read here (Serato's Markers2 tag, rekordbox XML) are read or written
following their community-documented layouts, for interoperability. DaJent's
cloud features (accounts, its backend, billing, store carts, AI chat) are not
copied and DJ Assistant still makes no network calls from its core.

## Phase 1: what the installer is

| | |
|---|---|
| Installer | NSIS (electron-builder), `DaJent-Setup-1.0.11-a.exe`, 137 MB, x86 stub; payload `app-64.7z` |
| Framework | **Electron** (Chromium + Node), main process ES module `out/main/main.js` (≈16 k lines, ≈980 functions), preload `out/preload/preload.cjs`, renderer: **Vite + React** (React compiler), i18n in 8 languages |
| Entry points | `package.json` `main` → `out/main/main.js`; main window and a second "live" window load `out/renderer/index.html` (`?live=1`); OAuth and store-login windows; a hidden analysis page (`waveform-analyzer.html`) |
| Preload bridge | `contextBridge` exposes `window.electronAPI` with ~100 members over ~96 literal IPC channels, grouped `usb:*`, `rekordbox:*`, `serato:*`, `sync:*`, `stores:*`, `live:*`, `localAnalysis:*`, `updates:*`, `auth:*`, `analytics:*` |
| Native modules | `better-sqlite3-multiple-ciphers` (opens rekordbox's SQLCipher `master.db` / `exportLibrary.db`), `bonjour-service` (mDNS), `chokidar` (folder watching), `electron-store`, `electron-updater`, `music-metadata` |
| Bundled engines | a Kotlin/JS "binary engine" that writes the rekordbox USB database (`export.pdb`) and ANLZ files, with a baseline USB scaffold; Essentia.js (WASM) and an ONNX/TF-style model bundle in the renderer for in-browser analysis |

**Network endpoints (observed as strings, not called):**

- Backend: a Supabase project (PostgREST tables such as `songs`, `sets`,
  `set_slots`, `playlists`, `cue_points`, `song_beatgrids`, `song_waveforms`,
  `analysis_jobs`, `stem_jobs`, `semantic_axes`, `play_sessions`; ~28 RPCs such
  as `library_rows`, `library_facets`, `find_dedup_candidates`,
  `merge_duplicate_songs`, `update_set_curve`, `reorder_set_slots`; edge
  functions for Spotify / Apple Music / TIDAL / SoundCloud / YouTube import,
  `discover`, `import-plan`, `me-entitlements`, `crew-chat`,
  `storage-gateway`; a storage bucket `audio`).
- Own hosts: a data host and a downloads page on the vendor's domain; update
  feed from Supabase storage (generic provider in `app-update.yml`).
- A hosted analysis API (Essentia on Modal); PostHog analytics.
- Stores: Beatport (`api.beatport.com/v4`, site session), Bandcamp (fan API,
  cart) — driven through embedded login windows.
- Local: an HTTP queue bridge on `127.0.0.1` (random port, bearer token) for
  an optional local analysis sidecar; a TCP server advertised over mDNS as a
  "live" peer for Serato's remote-control protocol; a custom
  `dajent-local:` protocol that streams local audio with range requests.

**Local storage:**

- `electron-store` JSON files in `userData`: `sync-config` (watch folder,
  sync/paused flags), `main-events`, live-window layout.
- SQLite `candidates.db` in `userData` (files found in the watch folder:
  path, hash, status, attempts).
- rekordbox: reads `master.db` (SQLCipher) for import, history and "library
  sync" (with timestamped backups first); writes `PIONEER/rekordbox/export.pdb`
  plus `exportLibrary.db` (OneLibrary) to USB drives through a staging folder.
- Serato: reads `_Serato_/database V2`, crates and `history.database`; can
  patch `database V2` and write cue/BPM tags into files, with a journal and
  backups.
- Renderer: `localStorage` for the live session (`live-session:<user>`, 12 h
  resume), caches; all library data lives on the backend.

## Phase 2: features traced

Feature areas (from IPC groups, routes and locale namespaces): Library and
songs, Sets (set builder with energy curve), Live (floating "next up" strip
over Serato/rekordbox), USB export (rekordbox PDB/OneLibrary), rekordbox
import/export/library sync, Serato import/export/library sync, cue sync, store
"acquire" (carts), streaming-service playlist import, Crew (AI chat over a
set), GPS (a "galaxy" map of the library by vibe), Coach, history, billing.

Three were traced in depth because they fit a local-first app.

### 1. Live "next up"

Observed inputs: the trail of played tracks (BPM, key, scale, energy 1–10),
a direction (cool / hold / lift), a BPM window, a key gate, per-track
"axis" scores from the backend's audio model.

Observed behaviour:

- **BPM gate:** no window or no anchor BPM → pass; candidate without BPM →
  pass, flagged; window 0 → same rounded BPM; otherwise within ±window, or at
  half/double time when allowed. Default window 3, range 0–16; the "widen"
  ladder is exact → ±3 → any.
- **Key gate (Camelot):** off → pass; unknown anchor → pass; unknown candidate
  → pass, flagged. Strict: same ring and ≤1 step, or same number on the other
  ring. Loose: also same ring 5 steps apart (one semitone), marked as a key
  shift.
- **Target energy:** mean of the last 10 played energies, ±1 for lift/cool,
  clamped to 1–10.
- **Score:** each signal is z-scored (population SD; all zero below 1e-6) over
  the library and summed with weights: energy proximity `max(0, 1 − |e − t|/5)`
  with weight 1; "residual" axes (the axis value after a least-squares fit on
  energy, compared with the anchor's residual) with weight 0.5; user-steered
  axes and a "magnet" (taste) term. Tracks with no score keep library order
  after the scored ones.
- **Loosen hints** when nothing passes: widen BPM, strict→loose key, key off,
  each with the number of tracks it would unlock.

Unknown / not extracted: the backend's axis scores and taste "affinity" come
from server-side models (MuQ embeddings, Essentia moods) and are not in the
app; the live detection of what is playing uses Serato's remote protocol and
history databases (not studied further).

### 2. Serato cues

Observed: DaJent reads and writes the `Serato Markers2` tag (and the legacy
`Serato Markers_`) in MP3, FLAC and MP4, keeping hot cues 1–8 (position ms,
colour, name), saved loops (start/end, colour, locked, name), track colour and
BPM lock, and moves cues to rekordbox (pads) and back. Writing is guarded by
backups and a journal.

### 3. Matching tracks between libraries

Observed: to pair its songs with Serato/rekordbox database rows, DaJent indexes
by normalised path, file name, "artist title" (NFKD, letters and digits only)
and title. Sure matches go path → file name → artist+title (closest length
wins); a second pass makes likely matches on the same title scored by how the
artist word sets relate (contains: best; share a word: next, better with
lengths within 5 s; same length; or no artist at all). Each row is used once.

## Phase 3/4: what DJ Assistant 2.1.2 does

| Feature | Where | Notes |
|---|---|---|
| **Next up** in Gig Mode | `lib/core/next_track.dart`, `NextUpPanel` in `lib/ui/prepare_screens.dart` | Same gates, direction and z-score blend, written for DJ Assistant's catalogue (your values win over analysis). Loudness (LUFS) from local analysis stands in for the model axes as the one "residual" measure. No taste model, no network. |
| **Serato hot cues and saved loops** | `lib/core/serato_cues.dart`, track details | Read only (MP3 and FLAC), shown as coloured chips. Serato's files are never written — DJ Assistant's rule since 1.0. |
| **Cues in rekordbox XML** | `lib/core/dj_export.dart` | Hot cues → `POSITION_MARK` Type 0 on pads A–H with colour; saved loops → memory loops (Type 4, Num −1), since rekordbox shares its pads. |
| **Better history matching** | `lib/core/track_match.dart`, `SeratoService.importHistoryCsv` | Falls back to file path/name, artist+title and likely title+artist matches; reports how many were likely. A history may repeat a track, so tracks are not "used up". |

### 2.2.0 additions

| Feature | Where | Notes |
|---|---|---|
| **rekordbox XML import** | `lib/core/rekordbox_import.dart`, Library tools | Playlists and folders become crates of matching tracks (by path, file name, artist + title, or likely). Stands in for DaJent's direct `master.db` import, which needs rekordbox's database key. |
| **Serato play history** | `SeratoService.importSeratoDbHistory` | Reads Serato DJ 4's `Library/master.sqlite` from a temporary copy; each session once. |
| **Follow Serato (Gig Mode)** | `GigService.followSerato`, Next up panel | Every 15 s, plays Serato logged since the gig started are marked as played, so Next up follows the decks — DaJent's Live does this through Serato's history and remote protocol. |
| **Playlist files and shopping list** | `DiscoveryService.matchPlaylistFile`, Discovery | M3U/M3U8/CSV/text; owned, possibly owned, missing; missing tracks saved as a CSV with store search links. Stands in for DaJent's streaming-service import and store carts. |
| **Library Map** | `lib/ui/library_map.dart` | Tempo across, energy up, colour by Camelot key, search lights up matches. DaJent's "galaxy" places tracks by a server-side audio model; DJ Assistant uses its own analysis. |
| **Set Studio rules** | `lib/core/set_check.dart`, `sets.dart` | Mix grades (smooth / good / workable / clash), per-slot issues (key clash, tempo jump, same artist within N minutes, off the tempo path, energy off the curve, BPM/key unknown), key mode (strict / loose / off), half/double time, tempo ramp (start → end BPM), opening track, energy band. |

## Code similarity check (before the 2.2.0 release)

Measured MOSS-style: identifiers, numbers and strings normalised, 12-token
fingerprints winnowed, then the share of DJ Assistant's fingerprints found in
the reference ("containment") and the longest common run of normalised
tokens. Two DJ Assistant files written before DaJent was looked at give the
noise floor.

| DJ Assistant file | vs DaJent `main.js` | vs DaJent Live / ranking | vs uploaded set-builder | longest run (tokens) |
|---|---|---|---|---|
| next_track.dart | 7.4 % | 4.3 % / 7.4 % | 0.9 % | 31 |
| set_check.dart | 5.4 % | 1.9 % / 3.5 % | 1.2 % | 21 |
| serato_cues.dart | 6.3 % | 1.3 % / 1.3 % | 0.0 % | 20 |
| track_match.dart | 9.8 % | 2.7 % / 4.4 % | 1.0 % | 31 |
| rekordbox_import.dart | 7.2 % | 1.2 % / 2.7 % | 0.9 % | 31 |
| library_map.dart | 5.3 % | 1.9 % / 2.4 % | 0.8 % | 21 |
| *baseline* health.dart | 6.1 % | 2.8 % / 2.8 % | 0.3 % | 28 |
| *baseline* crates.dart | 6.7 % | 0.7 % / 3.2 % | 0.4 % | 23 |

The new code sits at the noise floor (common Dart/JS boilerplate such as
`for … length`, `import`, `String`); no run longer than 31 normalised tokens
is shared. Three function names that happened to match DaJent's
(`bpmGate`, `keyGate`, `artistRelation`) and one type (`MixGate`) were
renamed before release so that even names are distinct.

## Gaps that remain, and why

| DaJent feature | Status in DJ Assistant | Why |
|---|---|---|
| USB export to rekordbox's own device database (`export.pdb`, OneLibrary) | Not built; rekordbox XML instead | Needs rekordbox's database key and a binary writer that can only be trusted after testing on real CDJs; a bad USB fails at the gig. |
| rekordbox `master.db` import and library sync | rekordbox XML import instead | `master.db` is encrypted by rekordbox. |
| Writing to Serato's database, crates in place, or cue/BPM tags | Not built | DJ Assistant's rule since 1.0: Serato's files are never written. |
| Serato remote-control pairing | Not built | Serato's private protocol; Follow Serato reads history instead. |
| Store carts (Beatport, Bandcamp sign-in) | Store search links and a shopping list | Driving store accounts through embedded logins. |
| Spotify / Apple Music / TIDAL / SoundCloud / YouTube playlist import | Playlist files (M3U/CSV) | Needs registered developer apps and a server. |
| "Vibe" axes, taste magnet, galaxy layout | Energy, loudness, key and BPM | Come from DaJent's server-side audio models. |
| Crew (AI set chat), Coach (fitness routines), accounts, billing, cloud sync, analytics | Not built | DJ Assistant already has its own AI assistant and local accounts; the rest needs DaJent's backend and goes against local-first. |
