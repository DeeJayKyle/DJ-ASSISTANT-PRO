DJ Assistant 2.0.1

**Stems work again, Pro Stems AI uses your graphics card, and a cleaner look throughout.**

**Stems (fixes)**
- **Fast stems failed on every song in 2.0.0.** Splitting now works on the Stems, Remix and DJ Decks pages.
- **Pro Stems AI never ran in 2.0.0.** The AI engine shipped with 2.0.0 was too old for the model, so every AI split quietly fell back to Fast. 2.0.1 ships a current one.
- **Pro Stems AI runs on your graphics card again** (DirectML, as in 1.8) when the PC has one, and on the processor otherwise. The Stems page says which one it used.
- **Playback starts straight away** and uses far less memory. The stems are mixed live instead of being copied for playback, so solo, mute and volume apply instantly. If the sound card can't be started, the page now tells you instead of staying silent.
- When a song can't be decoded, the page shows the real reason.

**A cleaner look**
- A new design across every page: the Inter typeface (built in, never downloaded), consistent spacing, panels, buttons, fields and menus, and readable contrast in dark and light.
- Pages fade in. Hovering, pressing and keyboard focus are visible everywhere. Settings → Appearance → Motion: Reduced turns the animations off.
- New accent colours in Settings → Appearance: mint, cyan, violet, amber and rose. Panels: Glass/Solid now takes effect.
- Smaller windows work better. Below about 1240 px wide the sidebar becomes a row of icons, and nothing on any page overflows at 1100 px.

**Diagnostics**
- Settings → About → **Open log folder**. If something goes wrong, the log says what happened. It stays on your PC and is never sent anywhere.

**Updating**
- Updates 2.0.0 and 1.8 in place and keeps your library, settings and shortcuts. Uninstalling never removes your library data.

**Please note:** the installer is signed for automatic updates, but not code-signed, so Windows SmartScreen may show an "unknown publisher" warning. 2.0.1 has passed automated tests on Windows: updating from 1.8.1 and 2.0.0, splitting MP3, M4A, FLAC, WAV and AIFF files with both methods, and driving the real app through every page. It has not yet been hand-tested on a real library with a sound card and graphics card.
