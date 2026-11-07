DJ Assistant 2.0.4

**Getting Pro Stems AI works again.**

- **Fixed: "Get" for Pro Stems AI stayed on Downloading and never downloaded anything** (Settings → Packs). The download job could not start, and the error was hidden, so it looked busy forever. It now downloads, picks up where it left off if interrupted, and checks the file before installing it.
- **No job can look stuck like that again.** If any background job (scan, analysis, downloads, Gig Pack) can't start, it now says so with the reason instead of showing as running. The reason is also written to the log (Settings → About → Open log folder).

If the download was stuck in 2.0.3, update, then press **Get** again in Settings → Packs.

**Please note:** the installer is signed for automatic updates, but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning.
