#!/usr/bin/env bash
# Start a haotrannas-server in the background for client tests (the Dart
# harness, manual cli runs): dev-plain by default, TLS with --tls.
#
#   e2e/scripts/start_dev_server.sh [--tls] <data-dir>
#
# - builds haotrannas-server (debug; honours CARGO_TARGET_DIR)
# - runs `init` if <data-dir> is not initialized yet
# - starts `run --dev-plain --listen 127.0.0.1:0` in the background
#   (with --tls: `run --listen 127.0.0.1:0`, TLS mode; get pairing codes with
#   `haotrannas-server pair --data-dir <data-dir>`)
# - prints exactly two lines on stdout, then exits 0:
#       NAS_SERVER_ADDR=127.0.0.1:<port>
#       NAS_SERVER_PID=<pid>
#
# Stop the server with `kill <pid>` (SIGTERM: clients get Close SERVER_SHUTDOWN).
# Server logs: <data-dir>/dev-server.log. Keep <data-dir> short (under ~90
# bytes): the admin socket path inside it must stay under 108 bytes.
set -euo pipefail

mode_flags=(--dev-plain)
if [[ "${1:-}" == "--tls" ]]; then
    mode_flags=()
    shift
fi
if [[ $# -ne 1 ]]; then
    echo "usage: $0 [--tls] <data-dir>" >&2
    exit 2
fi
data_dir="$1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$repo_root/target}"
server_binary="$target_dir/debug/haotrannas-server"
start_timeout_tenths=100 # 10 s, in 0.1 s steps

# Build output goes to stderr: stdout is only for the two result lines.
cargo build --manifest-path "$repo_root/Cargo.toml" -p haotrannas-server --bins >&2

if [[ ! -e "$data_dir/index.sqlite" ]]; then
    "$server_binary" init --data-dir "$data_dir" >&2
fi

stdout_file="$data_dir/dev-server.stdout"
log_file="$data_dir/dev-server.log"
: >"$stdout_file"
"$server_binary" run "${mode_flags[@]}" --listen 127.0.0.1:0 --data-dir "$data_dir" \
    </dev/null >"$stdout_file" 2>"$log_file" &
server_pid=$!

listening_line=""
for _ in $(seq 1 "$start_timeout_tenths"); do
    listening_line="$(grep -m1 '^listening on ' "$stdout_file" || true)"
    if [[ -n "$listening_line" ]]; then
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        echo "haotrannas-server exited before listening; log:" >&2
        cat "$log_file" >&2
        exit 1
    fi
    sleep 0.1
done

if [[ -z "$listening_line" ]]; then
    echo "haotrannas-server did not start listening in time; log:" >&2
    cat "$log_file" >&2
    kill "$server_pid" 2>/dev/null || true
    exit 1
fi

echo "NAS_SERVER_ADDR=${listening_line#listening on }"
echo "NAS_SERVER_PID=$server_pid"
