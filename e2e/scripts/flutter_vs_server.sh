#!/usr/bin/env bash
# Cross-language check: the Dart client (dart_client/, used by the phone
# and PC apps) against the real Rust
# server (server/) on localhost: one dev-plain server and one TLS server.
#
# Author: Hao Tran
#
# Usage: e2e/scripts/flutter_vs_server.sh
#   Builds the server, makes two temp data folders, starts a dev-plain and a
#   TLS server, runs `flutter test --tags server` with
#     NAS_SERVER_ADDR, NAS_DATA_DIR          dev-plain server (unchanged)
#     NAS_TLS_SERVER_ADDR, NAS_TLS_DATA_DIR  TLS server; pairing codes come
#                                            from `$NAS_SERVER_BIN pair --data-dir $NAS_TLS_DATA_DIR`
#     NAS_SERVER_BIN                         the server binary
#   and stops both servers.
#   Exit 0 only if every Dart server test passed.
set -euo pipefail

repo_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_directory"

cargo build --quiet --bin haotrannas-server

# Short path on purpose: the admin socket path must stay under 108 bytes.
data_directory="$(mktemp -u /tmp/htn-cross-XXXXXX)"
tls_data_directory="$(mktemp -u /tmp/htn-cross-tls-XXXXXX)"
server_pid=""
tls_server_pid=""
cleanup() {
    for pid in "$server_pid" "$tls_server_pid"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    rm -rf "$data_directory" "$tls_data_directory"
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

tls_server_lines="$(e2e/scripts/start_dev_server.sh --tls "$tls_data_directory")"
NAS_TLS_SERVER_ADDR="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$tls_server_lines")"
tls_server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$tls_server_lines")"
if [[ -z "$NAS_TLS_SERVER_ADDR" || -z "$tls_server_pid" ]]; then
    echo "error: TLS server did not start:" >&2
    echo "$tls_server_lines" >&2
    exit 1
fi
echo "TLS server at $NAS_TLS_SERVER_ADDR (pid $tls_server_pid)"

# Dart server tests may also call `haotrannas-server restore` to check an
# uploaded file byte for byte, so they get the binary and the data folder.
cd dart_client
NAS_SERVER_ADDR="$NAS_SERVER_ADDR" \
    NAS_SERVER_BIN="$target_directory/debug/haotrannas-server" \
    NAS_DATA_DIR="$data_directory" \
    NAS_TLS_SERVER_ADDR="$NAS_TLS_SERVER_ADDR" \
    NAS_TLS_DATA_DIR="$tls_data_directory" \
    flutter test --tags server
echo "flutter_vs_server: OK"
