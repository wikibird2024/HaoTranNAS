# nas

Setup of the machine the server runs on: disks, VPN, service, config. Config and scripts only, no application code.

| | |
|---|---|
| Owns | ZFS mirror, WireGuard, systemd unit, `config.toml` example, backup scripts |
| First milestone | M3n |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Hardware still open (see decisions O-3), so only lint and dry runs work today.
Setup on the real NAS: [RUNBOOK.md](RUNBOOK.md).

| What | Command (from repo root) | Where |
|---|---|---|
| Lint | `shellcheck nas/scripts/*.sh nas/scripts/tests/*.sh` | any PC, CI |
| Test (dry runs) | `nas/scripts/tests/run_tests.sh` | any PC, CI |
| Firewall syntax | `sudo nft -c -f nas/firewall/haotrannas.nft` | NAS only (needs root) |

| File | Does |
|---|---|
| `scripts/zfs_mirror_setup.sh` | ZFS mirror `tank` + `/srv/haotrannas` + monthly scrub |
| `scripts/wireguard_keys.sh` | Server + phone WireGuard keys |
| `wireguard/*.conf.example` | WireGuard configs with placeholder keys |
| `firewall/haotrannas.nft` | nftables input rules, default drop |
