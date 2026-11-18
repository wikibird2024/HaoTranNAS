#!/usr/bin/env bash
# Cross-language check: the Dart client (mobile/) against the real Rust
# server (server/), in dev-plain mode on localhost.
#
# Author: Hao Tran
#
# Usage: e2e/scripts/flutter_vs_server.sh
#   Builds the server, makes a temp data folder, starts the server, runs
#   `flutter test --tags server` with NAS_SERVER_ADDR set, stops the server.
#   Exit 0 only if every Dart server test passed.
set -euo pipefail

repo_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_directory"

cargo build --quiet --bin haotrannas-server

# Short path on purpose: the admin socket path must stay under 108 bytes.
data_directory="$(mktemp -u /tmp/htn-cross-XXXXXX)"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$data_directory"
}
trap cleanup EXIT

target_directory="${CARGO_TARGET_DIR:-$repo_directory/target}"
"$target_directory/debug/haotrannas-server" init --data-dir "$data_directory" >/dev/null

server_lines="$(e2e/scripts/start_dev_server.sh "$data_directory")"
NAS_SERVER_ADDR="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$server_lines")"
server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$server_lines")"
if [[ -z "$NAS_SERVER_ADDR" || -z "$server_pid" ]]; then
    echo "error: server did not start:" >&2
    echo "$server_lines" >&2
    exit 1
fi
echo "server at $NAS_SERVER_ADDR (pid $server_pid)"

cd mobile
NAS_SERVER_ADDR="$NAS_SERVER_ADDR" flutter test --tags server
echo "flutter_vs_server: OK"
