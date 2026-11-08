# Serato DJ Pro 4.0.9: design study for stems, BPM and key

A record of what was learned from a static look at the Serato DJ Pro 4.0.9
Windows installer (with REA and standard unpacking tools), and how DJ
Assistant 2.1 answers each point **with its own code**.

**Ground rules.** Nothing from Serato is in DJ Assistant: no code, no
decompiled logic, no model weights, no artwork, icons, fonts or skins.
Serato's AI stems models ship encrypted and were not decrypted or extracted.
The study used only what the files openly show (installer structure, which
libraries are loaded, imported function names, type and method names, and
log or interface text) to understand *what* the features do and *how they
are organised*, then built those features independently. Reading the BPM
and beatgrid Serato writes into a DJ's own music files follows the
community-documented tag layout, for interoperability.

## What the installer contains

- A WiX Burn bundle wrapping one MSI (1.6 GB), the Visual C++ runtimes and
  an optional QuickTime installer.
- `Serato DJ Pro.exe` (x64, Qt 6), `tensorflow.dll` (200 MB) and
  `tensorflow_framework.dll`, 55 model bundles in `bundles/*.bin` plus
  `bundle1`/`bundle2`. Every bundle measures about 8 bits of entropy per
  byte: encrypted or compressed, not readable model files.
- Audio is decoded through Windows Media Foundation (`MFPlat`,
  `MFReadWrite`), as DJ Assistant 2.0 already does.

## Stems separation

Observed:

- TensorFlow's C API loads a frozen graph (`TF_GraphImportGraphDef`) and
  runs it in a session (`TF_SessionRun`); thread counts for TensorFlow are
  set from a "Stem Threads" setting; the separator is warmed up before use.
- A `Stemifier` works in **regions and chunks**: the regions a deck needs
  (around the playhead, cues and loops: "cache strategy" per marker) are
  separated first, chunk by chunk, and mixed into per-stem caches.
- Finished stems are kept as **prepared stems files** (`.serato-stems`, with
  a header chunk) so a track is separated once; there is a stems crate and
  bulk "analyse stems"; the library stores a stems-analysis state per track;
  disk space and write permission are checked before writing.
- Four stems on the decks (vocals, melody, bass, drums), each with a level,
  mute, and stem effects; an "Instrumental"/"Acapella"-style quick switch.

DJ Assistant 2.1:

- Separation stays on **HTDemucs** (Meta, MIT licence), already shipped as
  the Pro Stems AI pack, with the built-in Fast splitter as the fallback.
- **Prepared stems** (`lib/studio/stems_cache.dart`): each split is saved
  once in the app's data folder (never beside the music), keyed by the
  song's path, size and modified time and by the separator, validated when
  read, written through a temporary file, with a free-space check and a
  size cap (oldest removed first). Settings → Studio turns it on or off and
  sets the space; Stems → **Prepare stems** splits a whole crate ahead of a
  gig. Prepared stems load instantly on the Stems page and on the decks.
- DJ Decks: stem pads (mute per stem, Instrumental, Acapella, All), a level
  fader per stem, and stem-coloured scrolling waveforms.

## BPM, beatgrid and key ("entire file analysis")

Observed:

- A bulk analyser with separate steps: overview, BPM, **full beatgrid**,
  key, auto gain and sample regions.
- A **BPM range** preference used during analysis.
- The beatgrid is a **tempo map** of markers (a steady track has one;
  others have several), serialised into the file's tags; band-limited
  onset analysis feeds it.
- Key analysis is skipped when the sample rate is too low.

DJ Assistant 2.1 (`lib/analysis/beatgrid.dart`, `analysis.dart`):

- **Whole-file beatgrid** from published dynamic-programming beat tracking
  (Ellis 2007): every beat in the file, then one marker for a steady track
  or a marker at each tempo change, the first beat, and the downbeat from
  the low band (kick and bass). Stored per track; shown in track details;
  drawn on the DJ Decks waveforms; exported to rekordbox as `TEMPO` markers.
- **BPM range** setting: automatic, 58–115, 68–135, 78–155 or 88–175.
- **Tuning-aware key**: music 20+ cents off A = 440 Hz is read on its own
  tuning; key analysis is skipped (with a note) below a 4 kHz sample rate.
- **Serato's own results**: when a file carries Serato's beatgrid and BPM
  tags (MP3 GEOB frames, FLAC comments), DJ Assistant reads them (never
  writes them) and prefers that grid, so tracks analysed in Serato keep
  Serato's exact grid.

## DJ Decks layout

DJ software shares common layout conventions: scrolling waveforms on one
time scale, deck panels either side of a mixer, performance pads and a
library below. DJ Assistant 2.1 uses that general arrangement, drawn
entirely with its own theme tokens, icons and components. No Serato
artwork, skin or styling is used.
