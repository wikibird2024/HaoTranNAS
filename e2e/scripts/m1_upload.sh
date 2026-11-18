#!/usr/bin/env bash
# M1 "Done when" check: the restored file's hash equals the source file's.
#
#   e2e/scripts/m1_upload.sh
#
# Builds the programs, starts a dev-plain server on a fresh temporary data
# folder, uploads a random 3 MiB + 17 B file with `haotrannas-cli upload`,
# stops the server, restores the file offline with
# `haotrannas-server restore`, then compares the bytes (cmp) and SHA-256.
# Exits non-zero if any step fails.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$repo_root/target}"
cli_binary="$target_dir/debug/haotrannas-cli"
server_binary="$target_dir/debug/haotrannas-server"
file_size_bytes=$((3 * 1024 * 1024 + 17))

cargo build --manifest-path "$repo_root/Cargo.toml" --workspace --bins >&2

# Short path on purpose: the admin socket path must stay under 108 bytes.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/htn-m1.XXXXXX")"
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

server_lines="$("$repo_root/e2e/scripts/start_dev_server.sh" "$work_dir/data")"
server_address="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$server_lines")"
server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$server_lines")"
echo "server: $server_address (pid $server_pid)"

"$cli_binary" --server "$server_address" upload "$source_file" --as m1/source.bin --dev-plain

# Offline restore: the server is stopped first.
stop_server
"$server_binary" restore --data-dir "$work_dir/data" --path m1/source.bin --output "$restored_file"

cmp "$source_file" "$restored_file"
source_sha256="$(sha256sum "$source_file" | cut -d ' ' -f 1)"
restored_sha256="$(sha256sum "$restored_file" | cut -d ' ' -f 1)"
echo "source   sha256 $source_sha256"
echo "restored sha256 $restored_sha256"
if [[ "$source_sha256" != "$restored_sha256" ]]; then
    echo "m1_upload: FAILED, hashes differ" >&2
    exit 1
fi
echo "m1_upload: OK"
