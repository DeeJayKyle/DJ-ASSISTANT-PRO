# DaJent 1.0.11-a: design study for gig-time track picking, Serato cues and library matching

A record of a static look at the DaJent 1.0.11-a Windows installer (with REA and
standard unpacking tools), and how DJ Assistant 2.1.2 answers the parts that
fit a local-first app **with its own code**.

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

Not brought over, and why: USB export to rekordbox's own database (needs the
SQLCipher key and a large binary writer — the XML route stays), writing to
Serato's database or tags (against DJ Assistant's safety rules), anything that
needs DaJent's backend, accounts, billing, stores or AI services, and Serato's
private remote-control protocol.
