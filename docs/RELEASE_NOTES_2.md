DJ Assistant 2.0.0

**DJ Assistant, rebuilt.** 2.0 is a new native Windows app (Flutter), written from scratch with the same features and the same rules as 1.8: local-first, private, read-only by default, and no telemetry.

**Your library comes with you**
- 2.0 opens the same catalogue, accounts, crates, sets, analysis, suggestions, change log and settings as 1.8. Nothing is converted or copied.
- Saved API keys stay in Windows Credential Manager and are found again.
- Changes logged by 1.8 can still be rolled back.

**What's different**
- **Faster and lighter:** no web view and no local song server. Audio plays straight from your files.
- **DJ Decks** are mixed natively. The EQ, filter, loops, hot cues and crossfader work as before. Knob moves are heard about a tenth of a second later.
- **MIDI controllers** in Synth Lab and Drum Lab connect through Windows directly.
- **Pro Stems AI** runs on the processor for now. The stems are just as clean, but separation is slower on PCs where 1.8 used the graphics card.
- **Ogg Vorbis and Opus** files are catalogued and tagged, but not analysed yet.
- **Fixes:** AIFF files with extra data after the audio are read correctly. MP3 comments show the real comment instead of iTunes' loudness data.

**Safety is unchanged**
- Music files are only read unless you turn on writing.
- Every change is previewed, checked, backed up, verified and reversible.
- Studio and Quick Prep exports only ever create new files.
- Nothing goes online unless you turn that service on. The update check sends only the app version, and can be turned off in Settings → Online services.

**Installing:** the update replaces 1.8 in the same folder and keeps your Start menu and desktop shortcuts. Uninstalling never removes your library data.

**Please note:** the installer is signed for automatic updates, but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning. 2.0 has passed automated tests on Windows, including updating from 1.8.1, but has not yet been hand-tested on a real library. If anything misbehaves, 1.8.1 can still be installed from its release page, and it opens the same data.
