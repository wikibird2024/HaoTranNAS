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
| Test (dry runs + unit check) | `nas/scripts/tests/run_tests.sh` | any PC, CI |
| Unit check only | `nas/scripts/tests/verify_systemd_unit.sh` | any PC with systemd, CI |
| Firewall syntax | `sudo nft -c -f nas/firewall/haotrannas.nft` | NAS only (needs root) |

| File | Does |
|---|---|
| `scripts/zfs_mirror_setup.sh` | ZFS mirror `tank` + `/srv/haotrannas` + monthly scrub |
| `scripts/wireguard_keys.sh` | Server + phone WireGuard keys |
| `wireguard/*.conf.example` | WireGuard configs with placeholder keys |
| `firewall/haotrannas.nft` | nftables input rules, default drop |
| `scripts/install.sh` | Service user, binary, config, data folder owner, systemd unit (enabled, not started) |
| `systemd/haotrannas-server.service` | Hardened unit: no capabilities, writes only `/srv/haotrannas` |
| `config.example.toml` | Every server setting with its default; a server test keeps it equal to the code |
