First release of DJ Assistant: a local-first, **read-only** music library assistant for Windows.

**What's in v0.1.0**
- Add music folders/drives and scan them read-only (pause, resume, cancel)
- Persistent local catalogue with tags and technical properties (MP3, FLAC, WAV, AIFF, M4A AAC/ALAC, Ogg, Opus, and more)
- Fast accent-insensitive search and filters (genre, year/decade, BPM, key, energy, rating, tags, quality, location…)
- Your own energy (1–10), rating, colour, mood, tags and notes — stored in the app, never written to files
- Manual and smart crates with AND/OR rules, ranges, exclusions and live preview
- Configurable low-bitrate warning (default 128 kbps; lossless and unknown never flagged)
- Conservative duplicate review: exact (full-file hash) vs possible vs alternate versions — nothing is deleted
- Library health: missing metadata, unreadable/unsupported files, offline drives, missing files
- Rule-based assistant sidebar (not AI) that turns requests into filters

**Safety and privacy**
- Never edits, renames, moves or deletes music files. Never touches Serato data.
- No account, no telemetry, no online services. Works offline.

**Please note**
- The installer is **not code-signed**; Windows SmartScreen will warn. Verify `SHA256SUMS.txt` first.
- Built and tested automatically on Windows CI; **not yet hand-tested on a real Windows PC or alongside Serato** — see docs/TESTING.md.
- No audio analysis yet: BPM/key come only from existing tags.
