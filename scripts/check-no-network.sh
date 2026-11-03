#!/usr/bin/env bash
# Verifies that core scanning/hashing/search makes no network calls:
#  1. dj-core's dependency tree contains no HTTP/network client crates.
#  2. (Linux only) the scan integration tests are run under strace and must
#     not create any AF_INET/AF_INET6 socket or call connect().
set -euo pipefail
cd "$(dirname "$0")/.."
BAD='^(reqwest|hyper|ureq|isahc|curl|attohttpc|surf|tokio|async-std|native-tls|rustls|openssl|h2|socket2|mio)$'
DEPS=$(cargo tree -p dj-core -e normal --prefix none --format '{p}' | awk '{print $1}' | sort -u)
if echo "$DEPS" | grep -Eq "$BAD"; then
  echo "FAIL: dj-core depends on a network-capable crate:"; echo "$DEPS" | grep -E "$BAD"; exit 1
fi
echo "OK: dj-core dependency tree has no network client crates ($(echo "$DEPS" | wc -l) crates checked)."
if [[ "$(uname -s)" == "Linux" ]] && command -v strace >/dev/null; then
  BIN=$(cargo test -p dj-core --test library --no-run --message-format=json 2>/dev/null | python3 -c 'import sys,json
for l in sys.stdin:
    m=json.loads(l)
    if m.get("reason")=="compiler-artifact" and m.get("executable") and "library" in m["target"]["name"]: print(m["executable"])' | tail -1)
  LOG=$(mktemp)
  strace -f -qq -e trace=socket,connect -o "$LOG" "$BIN" --test-threads=2 scanning reads_metadata exact_possible search_and_filters >/dev/null
  if grep -E 'AF_INET|AF_INET6|connect\(' "$LOG"; then
    echo "FAIL: network syscalls observed during scan tests"; exit 1
  fi
  echo "OK: no AF_INET/AF_INET6 sockets or connect() calls during scan, hash and search tests ($(wc -l < "$LOG") socket-related syscalls total)."
  rm -f "$LOG"
else
  echo "SKIP: strace syscall check (Linux only)."
fi
