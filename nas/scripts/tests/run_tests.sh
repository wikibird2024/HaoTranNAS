#!/usr/bin/env bash
# Dry-run tests for the nas/ scripts. Safe on any machine: nothing is changed.
#
# Author: Hao Tran
#
# Usage: nas/scripts/tests/run_tests.sh   (exit 1 on any failure)
set -euo pipefail

tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts_directory="$(dirname "$tests_directory")"
nas_directory="$(dirname "$scripts_directory")"
output_directory="$(mktemp -d)"
trap 'rm -rf "$output_directory"' EXIT

failure_count=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failure_count=$((failure_count + 1)); }

# 1. ZFS dry run prints exactly the expected commands.
if "$scripts_directory/zfs_mirror_setup.sh" --dry-run /dev/sdX /dev/sdY \
    >"$output_directory/zfs_dry_run.out" 2>"$output_directory/zfs_dry_run.err" \
    && diff -u "$tests_directory/zfs_mirror_setup.dry_run.expected" "$output_directory/zfs_dry_run.out" \
    && [[ ! -s "$output_directory/zfs_dry_run.err" ]]; then
    pass "zfs_mirror_setup.sh --dry-run matches expected output"
else
    cat "$output_directory/zfs_dry_run.err"
    fail "zfs_mirror_setup.sh --dry-run differs from expected output"
fi

# 2. A real run with /dev/sdX names is refused before any check or command.
zfs_exit_code=0
"$scripts_directory/zfs_mirror_setup.sh" /dev/sdX /dev/sdY \
    >/dev/null 2>"$output_directory/zfs_no_by_id.err" </dev/null || zfs_exit_code=$?
if [[ "$zfs_exit_code" -eq 2 ]] && grep -q 'by-id' "$output_directory/zfs_no_by_id.err"; then
    pass "zfs_mirror_setup.sh refuses non-by-id disk paths"
else
    fail "zfs_mirror_setup.sh did not refuse /dev/sdX (exit $zfs_exit_code)"
fi

# 3. Wrong number of disks is a usage error.
zfs_exit_code=0
"$scripts_directory/zfs_mirror_setup.sh" --dry-run /dev/sdX >/dev/null 2>&1 || zfs_exit_code=$?
if [[ "$zfs_exit_code" -eq 2 ]]; then
    pass "zfs_mirror_setup.sh needs exactly two disks"
else
    fail "zfs_mirror_setup.sh accepted one disk (exit $zfs_exit_code)"
fi

# 4. WireGuard key dry run prints only "would run:" lines and creates nothing.
key_directory="$output_directory/keys"
if "$scripts_directory/wireguard_keys.sh" --dry-run "$key_directory" >"$output_directory/keys_dry_run.out" \
    && [[ -s "$output_directory/keys_dry_run.out" ]] \
    && ! grep -qv '^would run: ' "$output_directory/keys_dry_run.out" \
    && [[ ! -e "$key_directory" ]]; then
    pass "wireguard_keys.sh --dry-run prints only commands"
else
    fail "wireguard_keys.sh --dry-run"
fi

# 5. WireGuard key script refuses to overwrite an existing key.
mkdir -p "$key_directory"
echo "existing" >"$key_directory/server_private.key"
if ! "$scripts_directory/wireguard_keys.sh" --dry-run "$key_directory" >/dev/null 2>&1 \
    && [[ "$(cat "$key_directory/server_private.key")" == "existing" ]]; then
    pass "wireguard_keys.sh refuses to overwrite existing keys"
else
    fail "wireguard_keys.sh did not refuse an existing key"
fi

# 6. No real WireGuard key (44-char base64 ending in "=") is committed under nas/.
if grep -rEn --exclude-dir=.git '(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=' "$nas_directory"; then
    fail "something that looks like a real WireGuard key is in nas/ (see above)"
else
    pass "no WireGuard keys in nas/"
fi

echo
if [[ "$failure_count" -gt 0 ]]; then
    echo "$failure_count test(s) failed"
    exit 1
fi
echo "all tests passed"
