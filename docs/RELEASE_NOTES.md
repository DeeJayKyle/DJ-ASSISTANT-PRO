DJ Assistant 1.3.1

**Maintenance release**
- Updates are now signed automatically by the release build, so every new version arrives through the in-app updater with no manual step.
- Release workflow: can also publish to a separate public update repository if the source is ever made private again; re-running a release replaces its files as one matching set.
- No changes to the app's features or behaviour since 1.3.0.

---

DJ Assistant 1.3.0

**New in 1.3: Quick Prep and local accounts**
- **Quick Prep:** choose a folder of fresh downloads and get it gig-ready. It's added read-only and analysed (with a little mini-game while you wait), then pick a path:
  - **Clean names** — junk like "[FREE DL]", "320kbps", "final FINAL v3", track numbers and underscores removed, capitals fixed, mix names kept; edit inline; Artist – Title or Title – Artist.
  - **Build a playlist** — Warm-up → peak (harmonic, smooth tempo), by BPM, by key, by genre, cool down, or type what you want; drag to reorder; flow score.
  - **Organise folders** — gig folders with Warm Up / Groove / Peak Time; listen and press 1–9 to sort; auto-sort by energy.
  - **Split by genre** — by genre or by families.
  Export as a verified copy in a new folder, one ZIP, or playlists only, with a playlist per folder and (optionally) clean tags written into the copies. Your originals are never changed. Folders and genres can be saved as crates. With the AI assistant on, *Improve with AI* and typed playlist requests use the same model.
- **Local accounts:** no sign-in. Add accounts from the title bar — each has its own folders, crates, sets, analysis and settings. Your existing catalogue becomes the first account.

**Safety:** music files are still only read. The only new writing is into new folders or ZIPs you choose (never over existing files) and tags inside those new copies.

---

DJ Assistant 1.2.0

**New in 1.2: the AI assistant**
- The Assistant panel can now be an **AI model that already knows the whole app**. A built-in guide covers every screen, feature and safety rule, plus DJ know-how (Camelot wheel, energy scale, crate cheat sheet).
- It **works through the app's own commands**:
  - It looks things up by itself: library overview, search, track details, crates, health, duplicates, suggestions, jobs, set previews and settings.
  - It shows you results by filtering the Library or opening a screen.
  - It proposes changes as **action cards you approve with Run**: create crates (smart or manual), add or remove tracks, set energy, rating, genre and key, tag tracks, apply crate templates, scan, analyse, find suggestions, save a set, start or end gig mode, and change preferences.
  - Nothing changes until you press Run. It has no way to change, move or delete music files, or to touch Serato.
- **Choose your model** in Settings → AI assistant:
  - **Claude** (online, your own Anthropic API key, kept in Windows Credential Manager). Opus 5.5 by default; Sonnet 5.5 or Haiku 5.5 to lower cost.
  - **A local model through Ollama**, which keeps everything on your computer.
  - Off by default. Settings says exactly what is sent, and file paths are never sent.
- **/commands** work with or without the AI: /scan, /analyse, /suggest, /find, /fix genre|year|…, /health, /dupes, /crate, /set 120 wedding clean, /gig start|end, /keys camelot|musical, /premium on|off, /theme, /clear, /help.
- Fixed: library rows could briefly share keys with loading placeholders while refreshing.

**Also in this release (from 1.1)**
- **Key notation:** choose Camelot (8A) or musical names (Am) in Settings. Search, filters and the Assistant accept either form ("key Am", "A minor", "8A", Open Key "1m").
- **Fix missing details from Library Health:** missing title/artist, genre, year, album, BPM and key cards now have a Fix button. You get a list of the affected tracks with inline inputs, suggestions with evidence (file and folder names, same album, same artist, stored suggestions), bulk set for selected tracks, and shortcuts to analysis and MusicBrainz. Saving changes DJ Assistant's catalogue only, never the files.
- **Video files:** music videos and visuals in MP4, M4V, MOV, MKV, WebM and AVI are catalogued with resolution, codec and frame rate. Only file headers are read; videos are never written to. There are media and resolution filters, a Video badge, and the Assistant understands "music videos", "house videos" and "1080p videos". Audio inside MP4/MOV/WebM/MKV can be analysed where the codec is supported (not Opus or AVI). WMV, FLV, MPEG and similar formats are listed as unsupported. You can turn video scanning off in Settings.
- **Premium UI (from RxPOS):** a switch in the title bar for the Midnight Pro look, with a translucent sidebar, a cyan glow on the current page, glass cards, mono figures, light beams around key figures and flagged problems, and 120 ms ease-out motion. It only changes how the app looks.

**Safety:** unchanged. Music and video files are only read unless you turn on tag writing, which never applies to videos. Serato data is never written.

---

DJ Assistant 1.0.0 — the full first release.

**New in 1.0**
- Redesigned glass interface with a mint accent, custom title bar, Assistant panel and smooth motion (reduced-motion option)
- Local audio analysis: BPM (+ half/double-time), key + Camelot, energy, loudness, clipping, silence, intro/outro, cue ideas, waveform
- Suggestions with source, evidence and confidence; optional MusicBrainz, AcoustID and Last.fm (all off by default)
- Crate templates from the Crate & Playlist Cheat Sheet, nested crates, energy/rating/colour labels, crate hygiene, M3U8/CSV export
- Discovery: crate fit, gaps, overplayed alternatives, tracklist matching, similar artists, new releases, inspectable learning
- Set Studio: energy journeys, tempo/key transition notes, alternatives, emergency tracks, save/export
- Gig Mode (set list, requests, notes, recap) and Gig Pack (verified copies to USB with manifest)
- Read-only Serato crate and history import
- Opt-in safe tag writing with verified backups, Serato-data preservation checks and rollback
- Opt-in personal files search; folder watcher
- Signed in-app updates

**Safety:** music files are only read unless you turn on tag writing; Serato data is never written; nothing is deleted.

**Please note:** the installer is not code-signed (SmartScreen warning). The app has passed automated tests on Windows CI but has not yet been hand-tested on a real library or alongside Serato — start with copies.
