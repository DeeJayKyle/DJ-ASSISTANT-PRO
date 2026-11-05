#!/usr/bin/env bash
# Guard: only four modules may create, change or delete files:
#   safe_write.rs  - opt-in tag writing (preview, verified backup, approval, log, rollback),
#                    and clean tags on NEW gig-pack copies (never originals)
#   gigpack.rs     - copies into a NEW folder or .zip outside the library (create_new only)
#   export.rs      - writes the single playlist/CSV/recap file the user chose
#   accounts.rs    - the app's own accounts.json and an account's catalogue files
#   packs.rs       - downloaded packs, only inside the app's own <data>/packs/<pack>/ folder
#   organize.rs    - opt-in renames/moves and restorable removals, previewed and approved, with undo
# Everything else (scanner, analysis, library, crates, discovery, Serato import,
# personal files, ...) must stay read-only. The desktop shell may only write
# its own log file.
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='fs::write|File::create|OpenOptions|fs::rename|remove_file|remove_dir|set_permissions|set_modified|fs::copy|hard_link|fs::symlink|symlink_file|symlink_dir|save_to|\.save\(|write_to|TagExt|create_new'
ALLOW='^crates/dj-core/src/(safe_write|gigpack|export|accounts|packs|organize|dj_export)\.rs:|^src-tauri/src/main\.rs:.*OpenOptions'
HITS=$(grep -rnE "$PATTERN" crates/dj-core/src src-tauri/src | grep -vE "$ALLOW" || true)
if [[ -n "$HITS" ]]; then
  echo "FAIL: file-modifying API outside the allowed modules:"; echo "$HITS"; exit 1
fi
# The allowed export/gig-pack modules must never open an existing file for writing.
if grep -nE "OpenOptions::new\(\)\.read\(true\)\.write\(true\)" crates/dj-core/src/gigpack.rs crates/dj-core/src/export.rs; then
  echo "FAIL: gig pack/export may only create new files"; exit 1
fi
echo "OK: file-changing code is confined to safe_write.rs (opt-in), gigpack.rs (new folder/zip only), export.rs (chosen file only) accounts.rs (app data only), packs.rs (app data packs folder only), organize.rs (opt-in, previewed, undoable) and dj_export.rs (new export files only)."
