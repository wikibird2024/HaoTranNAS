#!/usr/bin/env bash
# Check nas/systemd/haotrannas-server.service with `systemd-analyze verify`.
# Safe on any machine: reads a temp copy, changes nothing.
#
# Author: Hao Tran
#
# Usage: nas/scripts/tests/verify_systemd_unit.sh   (exit 1 on any problem)
#
# Why a temp copy and a filter:
#   - verify fails when the ExecStart binary does not exist, and on a dev PC
#     or CI runner /usr/local/bin/haotrannas-server never does. The copy
#     points ExecStart at /bin/true; every other line stays the same.
#   - verify exits 0 on an unknown key or a bad value: it only prints a
#     warning ("Unknown key name ..., ignoring"). So any output line that
#     names our unit counts as a failure.
#   - verify also prints warnings about other units installed on the host.
#     Those lines do not name our unit and are ignored.
set -euo pipefail

readonly UNIT_NAME="haotrannas-server.service"
readonly REAL_BINARY="/usr/local/bin/haotrannas-server"
readonly STAND_IN_BINARY="/bin/true"

tests_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nas_directory="$(dirname "$(dirname "$tests_directory")")"
unit_file="$nas_directory/systemd/$UNIT_NAME"

command -v systemd-analyze >/dev/null || { echo "error: systemd-analyze not found" >&2; exit 1; }

copy_directory="$(mktemp -d)"
trap 'rm -rf "$copy_directory"' EXIT

grep -q "^ExecStart=$REAL_BINARY " "$unit_file" \
    || { echo "error: ExecStart in $unit_file does not start with $REAL_BINARY" >&2; exit 1; }
sed "s|^ExecStart=$REAL_BINARY |ExecStart=$STAND_IN_BINARY |" "$unit_file" >"$copy_directory/$UNIT_NAME"

verify_exit_code=0
verify_output="$(systemd-analyze verify --man=no "$copy_directory/$UNIT_NAME" 2>&1)" || verify_exit_code=$?
unit_problems="$(grep -F "$UNIT_NAME" <<<"$verify_output" || true)"

if [[ "$verify_exit_code" -ne 0 || -n "$unit_problems" ]]; then
    echo "systemd-analyze verify (exit $verify_exit_code) found problems in $UNIT_NAME:" >&2
    echo "${unit_problems:-$verify_output}" >&2
    exit 1
fi
echo "systemd-analyze verify: $UNIT_NAME has no problems"
