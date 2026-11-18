#!/usr/bin/env bash
# M0 "Done when" check: `cli ping` gets `Pong` from a real server.
#
#   e2e/scripts/m0_ping.sh
#
# Builds the programs, starts a dev-plain server on a fresh temporary data
# folder (port 0), runs `haotrannas-cli ping`, prints its output, stops the
# server. Exits non-zero if any step fails or no `Pong` came back.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$repo_root/target}"
cli_binary="$target_dir/debug/haotrannas-cli"

cargo build --manifest-path "$repo_root/Cargo.toml" --workspace --bins >&2

# Short path on purpose: the admin socket path must stay under 108 bytes.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/htn-m0.XXXXXX")"
server_pid=""
stop_and_clean() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait_for_exit_tenths=50
        while kill -0 "$server_pid" 2>/dev/null && ((wait_for_exit_tenths > 0)); do
            sleep 0.1
            wait_for_exit_tenths=$((wait_for_exit_tenths - 1))
        done
    fi
    rm -rf "$work_dir"
}
trap stop_and_clean EXIT

server_lines="$("$repo_root/e2e/scripts/start_dev_server.sh" "$work_dir/data")"
server_address="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$server_lines")"
server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$server_lines")"
echo "server: $server_address (pid $server_pid)"

ping_output="$("$cli_binary" --server "$server_address" ping --dev-plain --count 3)"
echo "$ping_output"

if ! grep -q '^Pong in ' <<<"$ping_output"; then
    echo "m0_ping: FAILED, no Pong" >&2
    exit 1
fi
echo "m0_ping: OK"
