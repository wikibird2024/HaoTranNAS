#!/usr/bin/env bash
# M7 check: the PC app's code (desktop/) against the real Rust server in
# TLS mode on localhost. Pairs with a code from the admin socket, backs up
# a PC folder (nested folders, a 20 MiB file, a Unicode name, an empty
# file, a symlink that must be skipped), restores the whole folder and
# compares every SHA-256, then runs the admin commands (devices, scrub,
# cleanup, revoke).
#
# Author: Hao Tran
#
# Usage: e2e/scripts/desktop_vs_server.sh
#   Builds the server, starts it in a temp data folder, runs
#   `flutter test --tags server` in desktop/ with
#     NAS_TLS_SERVER_ADDR, NAS_TLS_DATA_DIR
#   and stops the server. Exit 0 only if every test passed.
set -euo pipefail

repo_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_directory"

cargo build --quiet --bin haotrannas-server

# Short path on purpose: the admin socket path must stay under 108 bytes.
tls_data_directory="$(mktemp -u /tmp/htn-desktop-XXXXXX)"
tls_server_pid=""
cleanup() {
    if [[ -n "$tls_server_pid" ]]; then
        kill "$tls_server_pid" 2>/dev/null || true
    fi
    rm -rf "$tls_data_directory"
}
trap cleanup EXIT

tls_server_lines="$(e2e/scripts/start_dev_server.sh --tls "$tls_data_directory")"
NAS_TLS_SERVER_ADDR="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$tls_server_lines")"
tls_server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$tls_server_lines")"
if [[ -z "$NAS_TLS_SERVER_ADDR" || -z "$tls_server_pid" ]]; then
    echo "error: TLS server did not start:" >&2
    echo "$tls_server_lines" >&2
    exit 1
fi
echo "TLS server at $NAS_TLS_SERVER_ADDR (pid $tls_server_pid)"

cd desktop
NAS_TLS_SERVER_ADDR="$NAS_TLS_SERVER_ADDR" \
    NAS_TLS_DATA_DIR="$tls_data_directory" \
    flutter test --tags server
echo "desktop_vs_server: OK"
