#!/usr/bin/env bash
# Verifies that core features make no network calls:
#  1. dj-core's dependency tree contains no HTTP/TLS/socket client crates.
#     (mio is allowed: the folder watcher uses it for inotify on Linux.)
#  2. (Linux only) scanning, hashing, search, analysis, suggestions, Set Studio,
#     gig packs, tag writing and personal-file indexing tests run under strace
#     and must not create any AF_INET/AF_INET6 socket or call connect().
#     Online services live in the separate dj-online crate.
set -euo pipefail
cd "$(dirname "$0")/.."
BAD='^(reqwest|hyper|ureq|isahc|curl|attohttpc|surf|native-tls|rustls|openssl|h2|socket2|tungstenite|async-std)$'
DEPS=$(cargo tree -p dj-core -e normal --prefix none --format '{p}' | awk '{print $1}' | sort -u)
if echo "$DEPS" | grep -Eq "$BAD"; then
  echo "FAIL: dj-core depends on a network client crate:"; echo "$DEPS" | grep -E "$BAD"; exit 1
fi
echo "OK: dj-core dependency tree has no network client crates ($(echo "$DEPS" | wc -l) crates checked)."
if [[ "$(uname -s)" == "Linux" ]] && command -v strace >/dev/null; then
  bin_for() {
    cargo test -p dj-core --test "$1" --no-run --message-format=json 2>/dev/null | python3 -c 'import sys,json
name=sys.argv[1]
for l in sys.stdin:
    m=json.loads(l)
    if m.get("reason")=="compiler-artifact" and m.get("executable") and m["target"]["name"]==name: print(m["executable"])' "$1" | tail -1
  }
  LOG=$(mktemp)
  strace -f -qq -e trace=socket,connect -o "$LOG.a" "$(bin_for library)" --test-threads=2 scanning reads_metadata exact_possible search_and_filters >/dev/null
  strace -f -qq -e trace=socket,connect -o "$LOG.b" "$(bin_for v1)" --test-threads=2 analysis_reads gig_pack safe_tag personal_files set_studio local_suggestions crate_templates exports >/dev/null
  cat "$LOG.a" "$LOG.b" > "$LOG"
  if grep -E 'AF_INET|AF_INET6|connect\(' "$LOG"; then
    echo "FAIL: network syscalls observed"; exit 1
  fi
  echo "OK: no AF_INET/AF_INET6 sockets or connect() calls during scanning, hashing, search, analysis, suggestions, crates, exports, Set Studio, gig packs, tag writing or personal-file indexing ($(wc -l < "$LOG") socket-related syscalls total)."
  rm -f "$LOG" "$LOG.a" "$LOG.b"
else
  echo "SKIP: strace syscall check (Linux only)."
fi
