#!/usr/bin/env bash
# Create the HaoTranNAS ZFS mirror: pool "tank", dataset tank/haotrannas
# mounted at /srv/haotrannas, monthly scrub.
#
# Author: Hao Tran
#
# Usage: zfs_mirror_setup.sh [--dry-run] <disk1> <disk2>
#
#   --dry-run  Only print the commands, one per line, prefixed "would run: ".
#              No checks on the disks, no root needed, nothing is changed.
#              It assumes the zfs-scrub-monthly@ timer exists (the real run
#              falls back to printing a cron line if it does not).
#
# A real run needs root, whole disks given as /dev/disk/by-id/... paths, and
# the typed confirmation "yes, erase <disk1> <disk2>". It ERASES both disks.
set -euo pipefail

readonly POOL_NAME="tank"
readonly DATASET_NAME="tank/haotrannas"
readonly MOUNT_POINT="/srv/haotrannas"
readonly BY_ID_PREFIX="/dev/disk/by-id/"
readonly SCRUB_TIMER_TEMPLATE="zfs-scrub-monthly@.timer"
readonly SCRUB_TIMER_UNIT="zfs-scrub-monthly@${POOL_NAME}.timer"

is_dry_run=false

print_usage() {
    echo "Usage: $(basename "$0") [--dry-run] <disk1> <disk2>" >&2
    echo "  Disks must be /dev/disk/by-id/... paths (unless --dry-run)." >&2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

# Run a command, or in dry-run mode print it exactly (shell-quoted).
run_command() {
    if [[ "$is_dry_run" == true ]]; then
        printf 'would run:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# --- arguments --------------------------------------------------------------
disks=()
for argument in "$@"; do
    case "$argument" in
        --dry-run) is_dry_run=true ;;
        -h | --help) print_usage; exit 0 ;;
        -*) print_usage; echo "error: unknown option: $argument" >&2; exit 2 ;;
        *) disks+=("$argument") ;;
    esac
done

if [[ ${#disks[@]} -ne 2 ]]; then
    print_usage
    exit 2
fi
first_disk="${disks[0]}"
second_disk="${disks[1]}"

# Pure string check first, so a wrong call stops before touching anything.
if [[ "$is_dry_run" == false ]]; then
    for disk in "$first_disk" "$second_disk"; do
        if [[ "$disk" != "$BY_ID_PREFIX"* ]]; then
            echo "error: $disk is not a ${BY_ID_PREFIX}... path." >&2
            echo "       /dev/sdX names can change between boots. List stable names with:" >&2
            echo "       ls -l ${BY_ID_PREFIX}" >&2
            exit 2
        fi
    done
fi

# --- safety checks (real run only) -------------------------------------------
check_disk_is_free() {
    local disk="$1"
    local device_names device_name pool_status

    [[ -e "$disk" ]] || fail "$disk does not exist."
    [[ -b "$(readlink -f "$disk")" ]] || fail "$disk is not a block device."

    [[ "$(lsblk -ndo TYPE "$disk")" == "disk" ]] \
        || fail "$disk is not a whole disk (a partition?). Use the disk itself."

    if lsblk -nro MOUNTPOINT "$disk" | grep -q .; then
        fail "$disk (or one of its partitions) is mounted or used as swap."
    fi

    if lsblk -nro FSTYPE "$disk" | grep -qx zfs_member; then
        fail "$disk carries a ZFS label (part of an existing or exported pool)."
    fi

    # Kernel names of the disk and its partitions, e.g. /dev/sda /dev/sda1.
    device_names="$(lsblk -nrpo NAME "$disk")"
    pool_status="$(zpool status -LP 2>/dev/null || true)"
    while IFS= read -r device_name; do
        [[ -n "$device_name" ]] || continue
        if grep -Fqw -- "$device_name" <<<"$pool_status"; then
            fail "$disk ($device_name) is part of an imported ZFS pool."
        fi
    done <<<"$device_names"
}

if [[ "$is_dry_run" == false ]]; then
    [[ "$(id -u)" -eq 0 ]] || fail "run as root (sudo)."
    for tool in zpool zfs lsblk; do
        command -v "$tool" >/dev/null || fail "$tool not found. Install zfsutils-linux first."
    done

    [[ "$(readlink -f "$first_disk")" != "$(readlink -f "$second_disk")" ]] \
        || fail "both paths point to the same disk."

    check_disk_is_free "$first_disk"
    check_disk_is_free "$second_disk"

    if zpool list -H -o name "$POOL_NAME" >/dev/null 2>&1; then
        fail "a pool named $POOL_NAME already exists."
    fi

    expected_answer="yes, erase $first_disk $second_disk"
    echo "This ERASES all data on:" >&2
    echo "  $first_disk" >&2
    echo "  $second_disk" >&2
    echo "Type exactly: $expected_answer" >&2
    typed_answer=""
    read -r -p "> " typed_answer || true
    [[ "$typed_answer" == "$expected_answer" ]] || fail "confirmation did not match. Nothing changed."
fi

# --- create pool and dataset -------------------------------------------------
# No -f: zpool itself refuses disks that still carry a partition table or label.
run_command zpool create \
    -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O mountpoint=none \
    "$POOL_NAME" mirror "$first_disk" "$second_disk"

run_command zfs create -o mountpoint="$MOUNT_POINT" "$DATASET_NAME"

# --- monthly scrub -----------------------------------------------------------
scrub_timer_exists() {
    local unit_directory
    for unit_directory in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        [[ -e "$unit_directory/$SCRUB_TIMER_TEMPLATE" ]] && return 0
    done
    return 1
}

if [[ "$is_dry_run" == true ]] || scrub_timer_exists; then
    run_command systemctl enable --now "$SCRUB_TIMER_UNIT"
else
    zpool_path="$(command -v zpool)"
    echo "No $SCRUB_TIMER_TEMPLATE on this system. Add this line to /etc/cron.d/haotrannas-scrub:"
    echo "0 3 1 * * root $zpool_path scrub $POOL_NAME"
fi

if [[ "$is_dry_run" == false ]]; then
    zpool status "$POOL_NAME"
    echo "Done: $DATASET_NAME mounted at $MOUNT_POINT."
fi
