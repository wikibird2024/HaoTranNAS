#!/usr/bin/env bash
# Generate WireGuard key pairs for the NAS (server) and the phone.
#
# Author: Hao Tran
#
# Usage: wireguard_keys.sh [--dry-run] <key_directory>
#
#   Writes server_private.key, server_public.key, phone_private.key,
#   phone_public.key into <key_directory> (created with mode 700, keys 600).
#   Refuses to overwrite any existing key. Prints only the public keys.
#   --dry-run  Only print what it would do, prefixed "would run: ".
set -euo pipefail

readonly KEY_NAMES=(server phone)

is_dry_run=false
positional_arguments=()

print_usage() {
    echo "Usage: $(basename "$0") [--dry-run] <key_directory>" >&2
}

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
key_directory="${positional_arguments[0]}"

# Refuse before doing anything if any key file already exists.
for key_name in "${KEY_NAMES[@]}"; do
    for key_file in "$key_directory/${key_name}_private.key" "$key_directory/${key_name}_public.key"; do
        if [[ -e "$key_file" ]]; then
            echo "error: $key_file already exists. Not overwriting keys." >&2
            exit 1
        fi
    done
done

if [[ "$is_dry_run" == true ]]; then
    echo "would run: umask 077"
    echo "would run: mkdir -p $key_directory"
    for key_name in "${KEY_NAMES[@]}"; do
        echo "would run: wg genkey > $key_directory/${key_name}_private.key"
        echo "would run: wg pubkey < $key_directory/${key_name}_private.key > $key_directory/${key_name}_public.key"
    done
    exit 0
fi

command -v wg >/dev/null || { echo "error: wg not found. Install wireguard-tools first." >&2; exit 1; }

umask 077
set -o noclobber # a race with another writer still cannot overwrite a key
mkdir -p "$key_directory"

for key_name in "${KEY_NAMES[@]}"; do
    wg genkey >"$key_directory/${key_name}_private.key"
    wg pubkey <"$key_directory/${key_name}_private.key" >"$key_directory/${key_name}_public.key"
done

echo "Keys written to $key_directory (private keys are mode 600, never print or commit them)."
for key_name in "${KEY_NAMES[@]}"; do
    echo "${key_name} public key: $(cat "$key_directory/${key_name}_public.key")"
done
