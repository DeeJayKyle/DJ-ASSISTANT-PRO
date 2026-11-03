#!/usr/bin/env bash
# Guard: the core library and desktop shell must not contain APIs that write,
# rename, move, copy or delete files (music files are read-only in v0.1).
# Allowed exceptions are listed explicitly below with their purpose.
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='fs::write|File::create|OpenOptions|fs::rename|remove_file|remove_dir|set_permissions|set_modified|fs::copy|hard_link|fs::symlink|symlink_file|symlink_dir|save_to|\.save\(|write_to|TagExt'
ALLOW='src-tauri/src/main.rs:.*OpenOptions'   # app's own log file in the app log directory
HITS=$(grep -rnE "$PATTERN" crates/dj-core/src src-tauri/src | grep -vE "$ALLOW" || true)
if [[ -n "$HITS" ]]; then
  echo "FAIL: file-modifying API found in shipped code:"; echo "$HITS"; exit 1
fi
echo "OK: no file-writing/renaming/deleting APIs in dj-core or the desktop shell (except the app's own log file)."
