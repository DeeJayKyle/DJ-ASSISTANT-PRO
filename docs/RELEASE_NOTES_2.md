DJ Assistant 2.4.0

**Suggestions wait for you**
- Auto-prep still analyses new music and finds fixes after every scan, but by default it no longer changes anything by itself. Every suggestion waits in Suggestions.
- Approve or reject one at a time, or tick several (or "Select ≥ 85%") and approve or reject them together. Filter by field and source.
- **Undo really undoes.** Accepted changes now remember the value they replaced and who accepted them ("by you" or "automatic"), so Undo puts the exact previous value back. It won't overwrite anything you've changed since. Settings → Library → *Undo automatic changes…* does all automatic ones at once.
- Prefer the old way? Settings → Library → Metadata suggestions: *Fill empty fields* (never replaces a value you have) or *Apply confident fixes* (the behaviour before 2.4).
- Accepting a suggestion still changes DJ Assistant's catalogue only, never the file.

**Organise Files mode** (off by default)
- Its own switch, separate from tag writing. Libraries that already allowed file changes keep it.
- Work on tracks sent from the Library (*Organise…*), a crate, or every track: edit tags in the files, rename, move into folders, rename a folder, replace a track with a better file, remove exact duplicates (choose which copy to keep) and remove bad files.
- **Every change is listed in a preview with a tick.** Only ticked items run, after a second confirmation. Name conflicts are blocked, and files that changed since the preview are skipped.
- **Serato notes for each track:** the preview reads, never writes, Serato's library list, crates and the cues, loops and beatgrid stored in each file, and says what each change would break in Serato.
- Moves are checked by hash. Removed and replaced files go to the restorable Removed files area, and emptying it shows the full list first. History undoes one change or a whole batch.
- Deleting songs "with their files" now shows the same preview before anything moves.

**Upgrades** (Prepare → Upgrades)
- Lossy tracks below your low-bitrate warning (still configurable; lossless and unknown are never listed).
- Better copies you already own, *Compare with a file…* for a new purchase, and store search links (links only; nothing is sent until you open one).
- **Compare by ear:** format, bitrate, sample rate, bit depth, length, loudness, peak and clipping side by side, with two players at matched loudness. Bitrate is treated as a clue, not proof of quality.
- *Replace…* goes through Organise Files' preview. The old file is kept, and the replacement can be undone.

**Fits more screens**
- The assistant stays open by default. Drag its edge, or focus it and use the arrow keys, to resize it (remembered). Ctrl+Shift+J expands it, and Ctrl+J hides it. On narrow windows it floats over the page instead of squeezing it.
- Every page is now checked at 900×600, 1024×640, 1280×720 and 1366×768 as well as larger sizes, with very long names.
- The status bar says when tag writing or Organise mode is on.

**Also**
- Discovery says what Last.fm and MusicBrainz receive, next to the buttons that use them.
- Fixed: Organise Files' history showed "null" instead of file paths.
- Fixed: Duplicate Review pointed to a "Replace duplicates" button that didn't exist; it's in Organise Files now.

**Please note:** the installer is signed for automatic updates but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning. Test Organise Files on copies of your music first.

---

DJ Assistant 2.3.0

**Remove songs**
- **From the library only:** the files are untouched, and scans skip them from then on. Settings → Removed songs brings them back.
- **With their files:** only when changes to music files are allowed in Settings. The files move to the restorable Removed files area; nothing is deleted until you empty it.

**Drag and drop onto the window**
- Drop a folder and it becomes a library folder.
- Drop files or ZIPs and they're copied (and verified) into your Inbox, then scanned, analysed and fixed by Auto-prep. They also go into the Inbox crate.

**Faster with the keyboard and mouse**
- **Library:** Up/Down, Shift+Up/Down, Page Up/Down, Home/End, Ctrl+A, Ctrl+I, Esc, Enter, Delete and Ctrl+F. Right-click for a menu, and double-click to open details. The selection bar has Select all, Invert and Delete.
- **Getting around:**
  - Back and forward with Alt+Left/Right, the mouse side buttons or the title-bar arrows.
  - Ctrl+K to go to any page, Ctrl+1–9 for pages, Ctrl+, for Settings.
  - F1 lists every key and mouse action.

**A tidier interface**
- Cards in a row now line up at the same height, and a single card is no longer left alone on the last row (Quick Prep's four paths sit 2 × 2).
- DJ Decks, the waveforms and the Library Map draw their labels in the app's font.
- **Stems:** a clearer song list, and a helpful message before you pick a song.
- **Set Studio:** field labels are no longer cut off, and every dropdown uses the same text.

**Studio speed:** tempo and beat analysis is about 40% faster, and pitch shifting about 25% faster. Results are identical.

**Please note:** the installer is signed for automatic updates, but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning.

---

DJ Assistant 2.2.1

**Faster, especially with big libraries.**

- **Set Studio plans in about a second.** A two-hour running order from a 50,000-track library used to take over 40 seconds; it now takes about one. The plan itself is the same.
- **Next up answers at once.** In Gig Mode, the suggestions are worked out once per played track and reused, so the panel no longer recalculates every time the screen redraws or Follow Serato checks in.
- **Faster matching.** Tracklists, playlist files, rekordbox XML and Serato history are matched against your library several times faster, and repeat matches are instant until the library changes.
- **Faster search and Library Map.** Searching plain-English titles and artists is quicker everywhere, and the Library Map draws a large library faster.

Everything from 2.2.0 is included: Follow Serato, Set Studio rules, rekordbox XML and Serato history import, the Library Map and playlist files with a shopping list.

**Please note:** the installer is signed for automatic updates, but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning.
