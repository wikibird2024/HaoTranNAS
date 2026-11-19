#!/usr/bin/env bash
# M5 check: browse and download over the wire (spec §9) with a paired cli.
#
#   e2e/scripts/m5_download.sh
#
# Builds the programs, `init`s a fresh temporary data folder, starts `run`
# in TLS mode (port 0), pairs the cli, uploads a small tree (a folder, a
# 0-byte file, a 3 MiB + 17 B file, a Vietnamese name), checks
# `haotrannas-cli list` of the root and a folder, downloads every file and
# compares it with cmp, then uploads a changed file and downloads the old
# version by its id. Prints `m5_download: OK`. Exits non-zero if any step
# fails.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="${CARGO_TARGET_DIR:-$repo_root/target}"
cli_binary="$target_dir/debug/haotrannas-cli"
server_binary="$target_dir/debug/haotrannas-server"

cargo build --manifest-path "$repo_root/Cargo.toml" --workspace --bins >&2

# Short path on purpose: the admin socket path must stay under 108 bytes.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/htn-m5.XXXXXX")"
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

fail() {
    echo "m5_download: FAILED, $1" >&2
    exit 1
}

cli() {
    "$cli_binary" --identity-dir "$identity_dir" "$@"
}

server_lines="$("$repo_root/e2e/scripts/start_dev_server.sh" --tls "$data_dir")"
server_address="$(sed -n 's/^NAS_SERVER_ADDR=//p' <<<"$server_lines")"
server_pid="$(sed -n 's/^NAS_SERVER_PID=//p' <<<"$server_lines")"
echo "server: $server_address (pid $server_pid, TLS)"

# "code 482913 · server id 3F9A-C21B-77E0 · valid 120 s"
pairing_line="$("$server_binary" pair --data-dir "$data_dir")"
pairing_code="$(cut -d ' ' -f 2 <<<"$pairing_line")"
server_id="$(cut -d ' ' -f 6 <<<"$pairing_line")"
"$cli_binary" --server "$server_address" --identity-dir "$identity_dir" \
    pair --code "$pairing_code" --expect-server-id "$server_id"

# remote path → local source file
source_dir="$work_dir/source"
mkdir -p "$source_dir"
declare -A source_of=(
    ["top.txt"]="$source_dir/top.txt"
    ["photos/empty.bin"]="$source_dir/empty.bin"
    ["photos/2024/video.bin"]="$source_dir/video.bin"
    ["photos/ảnh-đẹp.jpg"]="$source_dir/anh.jpg"
)
echo "hello from m5" >"$source_dir/top.txt"
: >"$source_dir/empty.bin"
head -c $((3 * 1024 * 1024 + 17)) /dev/urandom >"$source_dir/video.bin"
head -c 4000 /dev/urandom >"$source_dir/anh.jpg"
for remote_path in "${!source_of[@]}"; do
    cli upload "${source_of[$remote_path]}" --as "$remote_path"
done

root_listing="$(cli list)"
echo "$root_listing"
[[ "$(cut -c 1-11 <<<"$root_listing")" == $'d photos/\nf top.txt  ' ]] ||
    fail "root listing is not 'd photos/' then 'f top.txt'"
photos_listing="$(cli list photos)"
echo "$photos_listing"
photo_names="$(awk -F '  ' '{ print $1 }' <<<"$photos_listing")"
[[ "$photo_names" == $'d 2024/\nf empty.bin\nf ảnh-đẹp.jpg' ]] ||
    fail "photos listing is wrong: $photo_names"

download_dir="$work_dir/downloads"
mkdir -p "$download_dir"
download_number=0
for remote_path in "${!source_of[@]}"; do
    download_number=$((download_number + 1))
    output_file="$download_dir/file-$download_number"
    cli download "$remote_path" --output "$output_file"
    cmp "${source_of[$remote_path]}" "$output_file" ||
        fail "$remote_path differs after download"
done

# Old version: change top.txt, upload again, download the first version.
old_version_id="$(cli list | sed -n 's/^f top\.txt  .*  v\([0-9]*\)$/\1/p')"
cp "$source_dir/top.txt" "$work_dir/top-old.txt"
echo "changed" >"$source_dir/top.txt"
cli upload "$source_dir/top.txt" --as top.txt
cli download top.txt --output "$download_dir/top-old.txt" --version "$old_version_id"
cmp "$work_dir/top-old.txt" "$download_dir/top-old.txt" || fail "old version differs"
cli download top.txt --output "$download_dir/top-new.txt"
cmp "$source_dir/top.txt" "$download_dir/top-new.txt" || fail "new version differs"

echo "m5_download: OK"
