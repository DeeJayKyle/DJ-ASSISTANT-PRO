DJ Assistant 1.6.0

**The Studio, faster and deeper**
- **Faster stems:** splitting a track takes about a third of the time it did, and the MIDI bass line is found many times faster. Results are the same.
- **DJ Decks:** each deck now has a 3-band EQ (low, mid, high), a filter knob (left for low-pass, right for high-pass), 4 hot cues and beat loops of 1, 2, 4 or 8 beats. Double-click a knob to reset it.
- **Remix:** undo and redo (Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y). Click a clip to select it, then duplicate it (Ctrl+D) or delete it (Delete).
- **Drum Lab sequencer:** a 16-step pattern for your kit with tempo and swing. It loops while you edit, and every change is heard straight away. Export the loop as a 4-bar WAV, or the pattern as MIDI.
- **Lighter on memory:** the Studio keeps only the 8 most recent songs loaded.

**Fixes**
- The Remix timeline's ruler no longer blocks clicks on the first track's clips.
- The Drum Lab pads fit their panel at every window size.
- Studio saves are written to a temporary file and then renamed, so a half-written file is never left behind.

---

DJ Assistant 1.5.0

**New in 1.5: the Studio** (sidebar → Create)
- **Stems:** split any track into vocals, drums, bass and melodies, plus an instrumental. The key, tempo and a live chord readout show as it plays. Solo, mute or rebalance each stem. Download the stems as WAV, or download MIDI with bass, melody, vocal melody, chords and drums.
- **Remix:** add whole tracks or single stems as clips on a beat grid. Move, trim and loop clips, and set volume, pan, mute and solo per track. Pick the remix's tempo and key, and every clip is time-stretched and pitch-shifted to match. Export the mix, or each track, as WAV.
- **DJ Decks:** two decks with Sync (tempo and beat phase), tempo faders, key shift and *Match key*, live stem toggles, volume and a crossfader. A deck loaded while the other plays starts in time with it.
- **Synth Lab:** describe an instrument ("dark thick sub bass"), then play it with your computer keys, the on-screen keyboard or a MIDI controller. Fine-tune it and step through variations. Save it as samples plus an SFZ file. With the AI assistant on, the AI designs the patch.
- **Drum Lab:** describe a kit ("crisp trap kit with booming 808") and get 16 pads, played with keys or MIDI notes 36–51. Tune each pad, then save the WAVs plus an SFZ file.

**How it works:** everything runs on this computer, spread over your CPU cores. Stem separation uses signal processing, not an AI model: it's private and fast, but less clean than AI separators.

**Safety:** your music files are only read. The Studio saves only new files you choose (WAV, MIDI, SFZ, JSON), and never replaces an existing audio file.

---

DJ Assistant 1.4.0

**Auto-prep: your library fixes itself as you add music**
- After every scan, new tracks are analysed (BPM, key, energy, loudness, intro/outro, cue ideas).
- Titles, artists, genres and years are then found from file names, folders, albums and artists, plus MusicBrainz if you switched it on.
- The recommended fixes are applied to your catalogue: empty fields are filled from good evidence, and existing values change only at high confidence (85% by default).
- Every fix can be undone from Suggestions → Accepted. A summary and a "Run auto-prep now" button are in the new **Organise Files** screen.

**Organise Files: change files on disk, safely** (only after you turn on "Allow writing to music files")
- **Write fixes into the files:** catalogue values go into each file's tags (MP3, FLAC, M4A), with a verified backup and rollback.
- **Rename files** with a template like `{artist} - {title}`.
- **Sort into folders** like `{genre}/{artist}`.
- **Rename a folder:** its tracks, crates and analysis follow.
- **Remove corrupt and empty files** to a restorable "Removed files" area, emptied only when you confirm.
- **Replace duplicates:** Duplicate Review → "Keep this, replace others". Crates, tags and ratings move to the copy you keep.

Every change is previewed (with the reason for anything that can't be done), needs your OK, skips files that changed since the preview, and can be undone. Renaming or moving warns that Serato's links will need relocating.

**Export crates** (Virtual Crates → Export crates…)
- **Serato:** new `.crate` files in your `_Serato_` folder. Sub-crates stay nested; existing crates are never overwritten.
- **rekordbox:** an XML collection with a playlist per crate.
- **Folders:** verified copies with a playlist per crate.

**Make it yours** (Settings → Look & sound)
- **Colour:** 8 colour themes (Mint, Ocean, Violet, Sunset, Rose, Gold, Cyan, Lime) or any custom accent colour.
- **Background and motion:** 4 background styles, slide/fade/zoom page transitions, and an animation speed slider.
- **Sounds:** a different short chime for scans, analysis, auto-prep, exports, assistant replies and errors, with volume control.
- **Opening and closing:** an animated splash when DJ Assistant opens, and a smooth fade when it closes (also with Alt+F4).
- **Taskbar and tray:** the app icon is set on the taskbar, and a system tray icon offers Show/Quit.

**Smoother on Windows**
- The window starts dark, with no white flash.
- Release builds are fully optimised, and long track lists render more cheaply.

**Fixed:** starting gig mode could report the wrong gig id.

---

DJ Assistant 1.3.2

**One-click setup for the private AI model**
- Settings → AI assistant → **Local model (private)** now walks you through three steps:
  1. **Install Ollama:** opens the free download; the page notices when it's installed.
  2. **Start Ollama:** one button starts it quietly in the background (no window).
  3. **Download the model:** choose qwen2.5:7b (recommended, 4.7 GB), qwen2.5:3b (1.9 GB, for older or low-memory PCs) or llama3.1:8b, then watch the download with a progress bar. You can stop it; it resumes later.
- The assistant only shows as ready once Ollama is running and the model is downloaded. Until then the chat says which step is missing.
- Clear messages instead of system errors such as "os error 10061".
- Nothing about the local model leaves your computer. The setup only talks to Ollama on this PC; the one exception is the Download Ollama button, which opens ollama.com in your browser.

---

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
