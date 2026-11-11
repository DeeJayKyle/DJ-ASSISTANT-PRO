# DJ Assistant 2.x (Flutter)

The current DJ Assistant release: a local-first Windows app for organising, analysing and preparing a DJ library alongside Serato. See the [main README](../README.md) for what it does, how it keeps the library safe and how to install it.

## Develop

Flutter 3.47.9 (stable).

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test
```

On Linux the tests need the desktop build tools CI installs (`libgtk-3-dev libx11-dev libxi-dev ninja-build clang cmake pkg-config`). Media Foundation, Pro Stems AI and some Studio tests run only on Windows.

## Layout

| Folder | What's in it |
|---|---|
| `lib/core/` | Catalogue, scanning, crates, suggestions and auto-prep, safe tag writing, Organise Files, Serato readers, upgrades, exports |
| `lib/online/` | Every network call (off until each service is turned on) |
| `lib/assistant/` | The AI assistant, its tools and the built-in rule-based helper |
| `lib/analysis/`, `lib/audio/` | Local audio decoding and analysis |
| `lib/studio/` | Stems, Remix, DJ Decks, Synth and Drum Lab |
| `lib/ui/` | Screens and widgets |
| `test/` | Service, golden and screen-layout tests (synthetic files and temporary copies only) |
| `integration_test/` | Drives the real app on Linux and Windows |
| `installer/` | NSIS installer and the 1.8 → 2.x upgrade test |

`MIGRATION.md` maps the 1.x (Tauri/Rust) app onto this one. Generated files: `lib/core/migrations.g.dart` (`tool/gen_migrations.py`) and `lib/assistant/guide.g.dart` (`tool/gen_guide.py`, from `docs/ASSISTANT_GUIDE.md`).
