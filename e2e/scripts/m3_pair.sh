#!/usr/bin/env bash
# M3 check: pair the cli with a TLS server, then ping and upload over
# mutual TLS, and restore the file byte for byte.
#
#   e2e/scripts/m3_pair.sh
#
# Builds the programs, `init`s a fresh temporary data folder, starts
# `run` in TLS mode (port 0), gets a code with `haotrannas-server pair`,
# runs `haotrannas-cli pair` (checking the server id), `ping` and `upload`
# with that identity, stops the server, restores the file offline and
# compares it with cmp. Prints `m3_pair: OK`. Exits non-zero if any step fails.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$repo_root/target}"
cli_binary="$target_dir/debug/haotrannas-cli"
server_binary="$target_dir/debug/haotrannas-server"
file_size_bytes=$((2 * 1024 * 1024 + 5))

cargo build --manifest-path "$repo_root/Cargo.toml" --workspace --bins >&2

# Short path on purpose: the admin socket path must stay under 108 bytes.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/htn-m3.XXXXXX")"
data_dir="$work_dir/data"
identity_dir="$work_dir/identity"
server_pid=""
stop_server() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait_for_exit_tenths=50
        while kill -0 "$server_pid" 2>/dev/null && ((wait_for_exit_tenths > 0)); do
            sleep 0.1
            wait_for_exit_tenths=$((wait_for_exit_tenths - 1))
        done
        server_pid=""
    fi
}
stop_and_clean() {
    stop_server
    rm -rf "$work_dir"
}
trap stop_and_clean EXIT

source_file="$work_dir/source.bin"
restored_file="$work_dir/restored.bin"
head -c "$file_size_bytes" /dev/urandom >"$source_file"

server_lines="$("$repo_root/e2e/scripts/start_dev_server.sh" --tls "$data_dir")"
server_address="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$server_lines")"
server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$server_lines")"
echo "server: $server_address (pid $server_pid, TLS)"

# "code 482913 · server id 3F9A-C21B-77E0 · valid 120 s"
pairing_line="$("$server_binary" pair --data-dir "$data_dir")"
echo "$pairing_line"
pairing_code="$(cut -d ' ' -f 2 <<<"$pairing_line")"
server_id="$(cut -d ' ' -f 6 <<<"$pairing_line")"

"$cli_binary" --server "$server_address" --identity-dir "$identity_dir" \
    pair --code "$pairing_code" --expect-server-id "$server_id"
device_id="$(sed -n 's/.*"device_id": *\([0-9]*\).*/\1/p' "$identity_dir/server.json")"

"$cli_binary" --identity-dir "$identity_dir" ping --count 2
"$cli_binary" --identity-dir "$identity_dir" upload "$source_file" --as m3/source.bin

# Offline restore: the server is stopped first.
stop_server
"$server_binary" restore --data-dir "$data_dir" --device-id "$device_id" \
    --path m3/source.bin --output "$restored_file"

if ! cmp "$source_file" "$restored_file"; then
    echo "m3_pair: FAILED, restored file differs" >&2
    exit 1
fi
echo "m3_pair: OK"
