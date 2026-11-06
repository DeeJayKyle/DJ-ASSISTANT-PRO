# DJ Assistant 2.0 — fix plan

Reported on 2.0.0:
- **Stems don't work, with either the AI or the Fast method.**
- **The interface isn't polished on any page:** design, fonts, animations, transitions.

## Where things stand

On Linux:
- The analyzer is clean and all 223 tests pass.
- A new end-to-end test (`test/studio_engine_e2e_test.dart`) decodes a real FLAC file, analyses it, splits it into four stems with the Fast method and makes MIDI. All of that works.

So the core stem code is sound. What the tests never covered is the path a DJ actually uses on **Windows**:
- MP3 and M4A decoding through Media Foundation, inside a background isolate;
- the HTDemucs model through the bundled ONNX Runtime;
- playback through SoLoud;
- the Stems page around all of that.

That is why everything passed while stems fail for you. The plan therefore starts by reproducing the failure on Windows, then fixes it, then rebuilds the UI on a proper design system, with tests that look at every page.

Each phase ends with:
- the analyzer and all tests green on Linux;
- the Windows CI job green, including the installer upgrade test;
- a 2.0.x release through `release-flutter.yml`, so fixes reach you as they land.

---

## Phase 1 — Make the Windows failures visible (first)

1. **Diagnostics log.** Write a rotating log, `%APPDATA%\com.deejaykyle.djassistant\logs\dj-assistant.log`. It records:
   - every Studio error, with its stack trace;
   - which decoder was used;
   - the isolate and ONNX Runtime messages.

   Add *Settings → About → Open log folder*, and show the real reason for a failure on the Stems page instead of a generic message. Logs stay on the PC; nothing is sent anywhere.
2. **Windows end-to-end Studio tests in CI** (run in the `windows` job):
   - Decode MP3, M4A/AAC, FLAC, WAV and AIFF fixtures with `StudioEngine.load` (Media Foundation in an isolate). Analyse each and split it with the Fast method.
   - Download the Pro Stems AI model from the pack's URL, cached between runs. Check its SHA-256 and run `HtDemucs` on a 10-second clip. Check that it loads, and that the output shape and the four stems match `separateAi`.
   - Start SoLoud and load four stems with `LayerPlayer`; check that playback position advances.
3. **Integration test that drives the real app on Windows** (`integration_test/`):
   - Open each page, then on Stems pick a song and split it with Fast.
   - Capture a screenshot of every step and upload the screenshots as CI artifacts.
4. **Check against your report.** Ask you for the log file and the song formats that fail, and reproduce each failure in the tests above.

*Done when the stem failures are reproduced by failing tests on Windows CI.*

## Phase 2 — Fix stems (Fast and AI)

Likely causes to rule out one by one, each with a test:
1. **Decoding in isolates on Windows.** Media Foundation and COM may not be initialised on the isolate's thread. Large files may also exhaust memory, since the whole song is decoded to float and then copied for every worker.
   - Fix: initialise COM per thread, and stream the decode in chunks.
   - Share memory between isolates instead of copying (`TransferableTypedData`).
2. **Fast splitter at the full song size.** Run a 5-minute 44.1/48 kHz stereo song across 3–6 isolates and check peak memory and time.
   - Fix: limit parallel parts by available RAM, and report progress steadily.
3. **AI stems.**
   - The ONNX Runtime DLL must load from the install folder.
   - Building the input tensor from a typed list must not copy through `List<double>` (about 3M values per segment; it's slow and memory-heavy).
   - Fix: build the tensors from native memory.
   - Check the input and output names of `htdemucs_embedded.onnx` and handle a model that doesn't load.
   - Make the run cancellable and keep the fallback to Fast.
   - Measure processor time per segment and show a realistic estimate on the page.
   - Look into DirectML or GPU support for ONNX Runtime on Windows to restore graphics-card speed.
4. **Playback.** `LayerPlayer` currently encodes four whole-song WAV files and loads them into SoLoud.
   - Fix: stream the stems (buffer streams), or mix stem volumes in Dart and play a single stream. That keeps memory and start-up time small, and lets solo, mute and volume change without reloading.
5. **Same checks for Remix and DJ Decks**, which share decoding, separation and playback: load a song, turn stems on, play and sync.

*Done when the Windows CI tests from Phase 1 pass for every format and both methods, and you confirm stems work on your PC.*

## Phase 3 — A real design system

Use the installed UI skills (ui-ux-pro-max and Material Design 3) to pick a direction. It must stay an original design: no Fadr or Toqi look.
1. **Tokens** in `lib/ui/theme.dart`, with one source of truth for each:
   - colour (dark and light, accent presets);
   - surfaces and elevation;
   - spacing (a 4 px grid) and corner radii;
   - borders;
   - a type scale, with fonts bundled as assets (no network font loading);
   - icon sizes;
   - motion: durations and curves.
2. **Typography.** Bundle one open-licensed UI font (for example Inter, SIL OFL), plus tabular figures for BPM, key and time. Define and apply text styles; remove the ad-hoc font sizes.
3. **Components.** One set of shared widgets, used everywhere:
   - page header, panel or card, list row, table, toolbar, buttons, chips, segmented controls, sliders and knobs, dialogs, toasts, empty and loading states, progress, tooltips.
   - Remove the one-off styling in each screen.
4. **Motion and transitions:**
   - page transitions in the shell (a fade-through cross-fade);
   - list and expand animations;
   - hover and press states;
   - a waveform playhead that moves smoothly at the display's frame rate.
   - All of it honours the existing *Motion: Full/Reduced* setting.
5. **Responsiveness:** layouts for compact (1100 px), standard and wide windows; the sidebar collapses; nothing overflows; DPI scaling from 100% to 200%.
6. **Accessibility:**
   - keyboard focus order and visible focus rings;
   - contrast of at least 4.5:1;
   - screen-reader labels on every control;
   - shortcuts listed in a help sheet.

*Done when the tokens and components are in place and the theme is applied app-wide.*

## Phase 4 — Page-by-page UI pass

For each page:
- apply the components;
- fix the layout at each window size;
- add loading, empty and error states;
- add the transitions;
- check performance: lazy lists, `RepaintBoundary` on waveforms and meters, no rebuild on every tick.

The pages, in order:
1. Shell: title bar, sidebar, status bar, assistant panel.
2. Library and the track detail pane.
3. Quick Prep: every step.
4. Studio: Stems, Remix, DJ Decks, Synth Lab, Drum Lab.
5. Crates, Duplicates, Health, Suggestions, Scan Activity.
6. Set Studio, Gig, Gig Pack, Discovery.
7. Organise, Files.
8. Settings.

**UI tests:**
- Golden screenshots of every page at three window sizes, in dark and light, compared in CI.
- The Windows integration test from Phase 1, extended to visit every page.

*Done when you sign off each page from the CI screenshots, before release.*

## Phase 5 — Full regression and release

1. Run all suites: Linux tests, Windows tests, the Windows end-to-end Studio tests, the integration and screenshot tests, and the installer upgrade test (1.8.1 → 2.0.x and 2.0.0 → 2.0.x).
2. Check performance budgets:
   - the app starts in under 3 s;
   - Library scrolls at 60 fps with 50,000 tracks;
   - the Fast split of a 5-minute song takes less than its length on 4 cores;
   - memory stays under 1.5 GB while splitting.
3. Rerun the network audit and the file-safety checks.
4. Release 2.0.x with notes, then confirm the update reaches 2.0.0 installs.

## Order and checkpoints

Phase 1 → Phase 2 (stems fixed, released as 2.0.1) → Phase 3 → Phase 4 (released page group by page group as 2.0.2, 2.0.3, …) → Phase 5.

I check in with you:
- after Phase 1, with the reproduced failures;
- after Phase 2, to confirm stems work on your PC;
- after Phase 3, to agree the visual direction before every page is reworked.
