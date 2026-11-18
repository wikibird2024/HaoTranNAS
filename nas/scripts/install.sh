#!/usr/bin/env bash
# Install the HaoTranNAS server on the NAS: service user, binary, config,
# data folder ownership, systemd unit (enabled, not started).
#
# Author: Hao Tran
#
# Usage: install.sh [--dry-run] <path-to-haotrannas-server-binary>
#
#   --dry-run  Only print the commands, one per line, prefixed "would run: ",
#              then the next steps. No checks, no root needed, nothing is
#              changed. It assumes a fresh machine: no user, no config yet.
#
# A real run needs root and the ZFS dataset mounted at /srv/haotrannas
# (zfs_mirror_setup.sh). Safe to run again to update the binary or unit:
# the user is created only once and an existing config.toml is never touched.
#
# It does NOT start the service: `haotrannas-server init` must run first, as
# the service user. The exact commands are printed at the end.
set -euo pipefail

readonly SERVICE_USER="haotrannas"
readonly BINARY_TARGET="/usr/local/bin/haotrannas-server"
readonly CONFIG_DIRECTORY="/etc/haotrannas"
readonly CONFIG_TARGET="$CONFIG_DIRECTORY/config.toml"
readonly DATA_DIRECTORY="/srv/haotrannas"
readonly UNIT_NAME="haotrannas-server.service"
readonly UNIT_TARGET="/etc/systemd/system/$UNIT_NAME"

scripts_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nas_directory="$(dirname "$scripts_directory")"
readonly CONFIG_EXAMPLE="$nas_directory/config.example.toml"
readonly UNIT_SOURCE="$nas_directory/systemd/$UNIT_NAME"

is_dry_run=false
positional_arguments=()

print_usage() {
    echo "Usage: $(basename "$0") [--dry-run] <path-to-haotrannas-server-binary>" >&2
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
for argument in "$@"; do
    case "$argument" in
        --dry-run) is_dry_run=true ;;
        -h | --help) print_usage; exit 0 ;;
        -*) print_usage; echo "error: unknown option: $argument" >&2; exit 2 ;;
        *) positional_arguments+=("$argument") ;;
    esac
done

if [[ ${#positional_arguments[@]} -ne 1 ]]; then
    print_usage
    exit 2
fi
binary_source="${positional_arguments[0]}"

# --- checks (real run only) --------------------------------------------------
if [[ "$is_dry_run" == false ]]; then
    [[ "$(id -u)" -eq 0 ]] || fail "run as root (sudo)."
    command -v systemctl >/dev/null || fail "systemctl not found. This script needs systemd."
    [[ -f "$binary_source" && -x "$binary_source" ]] \
        || fail "$binary_source is not an executable file."
    [[ -f "$CONFIG_EXAMPLE" ]] || fail "$CONFIG_EXAMPLE not found. Run from a full repo checkout."
    [[ -f "$UNIT_SOURCE" ]] || fail "$UNIT_SOURCE not found. Run from a full repo checkout."
    # Never create the data folder here: a plain folder on the OS disk would be
    # hidden later when the ZFS dataset mounts over it.
    [[ -d "$DATA_DIRECTORY" ]] \
        || fail "$DATA_DIRECTORY does not exist. Create the ZFS mirror first (zfs_mirror_setup.sh)."
    if ! findmnt --mountpoint "$DATA_DIRECTORY" >/dev/null 2>&1; then
        echo "warning: $DATA_DIRECTORY is not a mount point. Backups would land on the OS disk." >&2
    fi
fi

# --- service user ------------------------------------------------------------
# System user, own group, no login shell, no home folder.
if [[ "$is_dry_run" == true ]] || ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    run_command useradd --system --user-group --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
else
    echo "user $SERVICE_USER already exists, kept"
fi

# --- binary ------------------------------------------------------------------
run_command install -m 0755 -o root -g root "$binary_source" "$BINARY_TARGET"

# --- config: root owns it, the service can only read it ----------------------
run_command install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIRECTORY"
if [[ "$is_dry_run" == true ]] || [[ ! -e "$CONFIG_TARGET" ]]; then
    run_command install -m 0640 -o root -g "$SERVICE_USER" "$CONFIG_EXAMPLE" "$CONFIG_TARGET"
else
    echo "$CONFIG_TARGET already exists, kept (compare with $CONFIG_EXAMPLE)"
fi

# --- data folder: only the service user ---------------------------------------
run_command chown "$SERVICE_USER:$SERVICE_USER" "$DATA_DIRECTORY"
run_command chmod 0700 "$DATA_DIRECTORY"

# --- systemd unit: enabled for boot, not started -----------------------------
run_command install -m 0644 -o root -g root "$UNIT_SOURCE" "$UNIT_TARGET"
run_command systemctl daemon-reload
run_command systemctl enable "$UNIT_NAME"

if [[ "$is_dry_run" == true ]]; then
    summary="Dry run: nothing changed. After a real run, the next steps are:"
else
    summary="Installed and enabled, not started. Next steps:"
fi
cat <<EOF

$summary
  1. Set the real LAN in pairing_networks:
       sudo nvim $CONFIG_TARGET
  2. Create the data files and TLS identity (once, as the service user):
       sudo -u $SERVICE_USER $BINARY_TARGET init --config $CONFIG_TARGET
  3. Start and check:
       sudo systemctl start $UNIT_NAME
       systemctl status $UNIT_NAME
       journalctl -u $UNIT_NAME -f
Updating an installed server: run this script again, then
       sudo systemctl restart $UNIT_NAME
EOF
