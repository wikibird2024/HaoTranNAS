# HaoTranNAS — NAS runbook

Author: Hao Tran · Updated: 2026-11-18

🟡 Scripts and configs are ready and lint-clean. **Nothing here has run on
real hardware yet** (hardware still open, decisions O-3). See the last section.

```
  phone (4G)                         home router                    NAS (Debian/Ubuntu)
 ┌───────────┐   UDP 51820 only   ┌───────────────┐            ┌──────────────────────────────┐
 │ WireGuard ├───── internet ────►│ port-forward  ├───────────►│ wg0 10.66.0.1   nftables     │
 │ 10.66.0.2 │                    │ UDP 51820 ──► │            │   │ drop by default          │
 └───────────┘                    └───────────────┘            │   ▼                          │
                                                               │ haotrannas-server :47100     │
  phone (home Wi-Fi) ── LAN ── mDNS + TCP 47100 + pairing ────►│   │                          │
                                                               │   ▼                          │
                                                               │ /srv/haotrannas              │
                                                               │ = tank/haotrannas            │
                                                               │ = ZFS mirror (2 disks)       │
                                                               └──────────────────────────────┘
```

## Setup order

| # | Step | Tool | Status |
|---|---|---|---|
| 1 | Install the OS | Debian/Ubuntu installer | ⚪ |
| 2 | ZFS mirror | `scripts/zfs_mirror_setup.sh` | ⚪ |
| 3 | Install the server | systemd unit (task C1) | ⚪ not written yet |
| 4 | Firewall | `firewall/haotrannas.nft` | ⚪ |
| 5 | WireGuard on the NAS | `scripts/wireguard_keys.sh` + `wireguard/wg0.conf.example` | ⚪ |
| 6 | Router port-forward | UDP 51820 only | ⚪ |
| 7 | Phone WireGuard app | QR import of `phone.conf` | ⚪ |
| 8 | Back up `tls/` | off the NAS | ⚪ |

All commands run on the NAS, from the repo folder, unless noted.

## 1. OS install

| Item | Choice |
|---|---|
| OS | Debian 12+ or Ubuntu 24.04 LTS, x86_64 or arm64 |
| OS disk | A third, small disk (SSD/USB). Not one of the two mirror disks |
| Network | Fixed LAN IP (DHCP reservation on the router) |
| Packages | `sudo apt install zfsutils-linux wireguard-tools nftables qrencode` |
| Debian only | ZFS is in `contrib`: enable it, and install `linux-headers-$(uname -r)` for the DKMS module |

## 2. ZFS mirror

Find the two disks by stable name (`/dev/sdX` can change between boots):

```
ls -l /dev/disk/by-id/ | grep -v part
```

Dry run first, then the real run:

```
nas/scripts/zfs_mirror_setup.sh --dry-run /dev/disk/by-id/ata-DISK_A /dev/disk/by-id/ata-DISK_B
sudo nas/scripts/zfs_mirror_setup.sh      /dev/disk/by-id/ata-DISK_A /dev/disk/by-id/ata-DISK_B
```

| The script | |
|---|---|
| 🔴 Erases both disks | Asks you to type `yes, erase <disk1> <disk2>` |
| Refuses | Non-by-id path, partition, mounted disk, ZFS label, disk in a pool, existing `tank` |
| Creates | Pool `tank` (mirror, ashift=12, lz4, atime=off, xattr=sa) |
| Creates | Dataset `tank/haotrannas` at `/srv/haotrannas` |
| Scrub | Enables `zfs-scrub-monthly@tank.timer`, else prints a cron line |

If `zpool` says a disk has an old partition table: check twice that it is the
right disk, then `sudo wipefs -a /dev/disk/by-id/<disk>` and run again.

🟡 Debian/Ubuntu's `zfsutils-linux` may also ship `/etc/cron.d/zfsutils-linux`
with its own monthly scrub. Keep one: `cat /etc/cron.d/zfsutils-linux`.

## 3. Install the server

Placeholder. The systemd unit and `config.toml` come in task C1.

Rule for `config.toml`: `pairing_networks` lists the **real LAN only** (for
example `192.168.1.0/24`). Never `10.0.0.0/8` or `10.66.0.0/24`: pairing is
LAN-only (protocol/spec.md section 7), and the WireGuard subnet must not pair.

## 4. Firewall

```
 input ─► established? ─► lo? ─► ICMP? ─► UDP 51820? ─► LAN: 22, 5353, 47100? ─► wg0: 47100? ─► DROP
```

| Port | From | Why |
|---|---|---|
| UDP 51820 | anywhere | WireGuard |
| TCP 47100 | LAN, wg0 | HaoTranNAS server |
| TCP 22 | LAN | SSH |
| UDP 5353 | LAN | mDNS discovery |

1. Set your LAN subnet: `nvim nas/firewall/haotrannas.nft`, edit `define LAN_NETWORKS`, then `:wq`.
2. Install and check:
   ```
   sudo mkdir -p /etc/nftables.d
   sudo cp nas/firewall/haotrannas.nft /etc/nftables.d/haotrannas.nft
   sudo nft -c -f /etc/nftables.d/haotrannas.nft
   ```
3. Over SSH? Set an auto-undo first, so a mistake cannot lock you out:
   ```
   sudo systemd-run --unit=firewall-undo --on-active=5min /usr/sbin/nft delete table inet haotrannas
   sudo nft -f /etc/nftables.d/haotrannas.nft
   ```
   Open a **new** SSH session. Works → `sudo systemctl stop firewall-undo.timer`.
   Locked out → wait 5 minutes, the rules are removed.
4. Load at boot: `sudo nvim /etc/nftables.conf`, press `G` `o`, type
   `include "/etc/nftables.d/haotrannas.nft"`, `Esc`, `:wq`. Then:
   ```
   sudo nft -c -f /etc/nftables.conf
   sudo systemctl enable --now nftables
   ```

## 5. WireGuard on the NAS

```
sudo nas/scripts/wireguard_keys.sh /root/wireguard-keys
sudo cp nas/wireguard/wg0.conf.example /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo nvim /etc/wireguard/wg0.conf
```

In nvim: replace `<SERVER_PRIVATE_KEY>` with the content of
`/root/wireguard-keys/server_private.key` and `<PHONE_PUBLIC_KEY>` with
`phone_public.key` (tip: `:r /root/wireguard-keys/server_private.key` pastes
a file below the cursor). `:wq`. Then:

```
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

## 6. Router port-forward

| Forward | To | 🔴 Never |
|---|---|---|
| UDP 51820 | NAS LAN IP, UDP 51820 | TCP 47100, TCP 22, anything else |

🟡 Check the router's WAN IP equals your public IP (`curl ifconfig.me` from
home). If not, the ISP uses CGNAT and a port-forward cannot work.

## 7. Phone WireGuard app

Make `phone.conf` on the NAS, in a private folder, never in the repo:

```
sudo cp nas/wireguard/phone.conf.example /root/wireguard-keys/phone.conf
sudo nvim /root/wireguard-keys/phone.conf
```

Fill `<PHONE_PRIVATE_KEY>`, `<SERVER_PUBLIC_KEY>`, and the endpoint (home
public IP or DDNS name). `:wq`. Show it as a QR code in the terminal:

```
sudo sh -c 'qrencode -t ansiutf8 < /root/wireguard-keys/phone.conf'
```

WireGuard app → **+** → **Scan from QR code**. Test on 4G: tunnel on, open the
HaoTranNAS app, it should reach `10.66.0.1:47100`. Other apps keep the normal
internet (split tunnel, `AllowedIPs = 10.66.0.1/32`).

After import, delete the phone private key from the NAS:
`sudo rm /root/wireguard-keys/phone_private.key /root/wireguard-keys/phone.conf`.

## 8. BACKUP: `/srv/haotrannas/tls/`

🔴 **Losing `tls/` forces every device to re-pair.** It holds the server
certificate and key that every phone has pinned (spec section 7). The ZFS
mirror does not protect against deleting it or losing the NAS.

| What | Where to keep a copy |
|---|---|
| `/srv/haotrannas/tls/` | USB stick + one other machine, encrypted |
| `/etc/wireguard/wg0.conf` | Same place (else: new keys + re-import the phone) |

```
sudo tar -C /srv/haotrannas -czf - tls | gpg -c > haotrannas-tls-$(date +%F).tar.gz.gpg
```

Redo the backup after any change in `tls/`. Restore: `gpg -d <file> | sudo tar -C /srv/haotrannas -xzf -`.

## 9. Monthly scrub check

| Check | Command | Good result |
|---|---|---|
| Timer runs | `systemctl list-timers 'zfs-scrub*'` | Next run listed |
| Pool health | `zpool status -x` | `all pools are healthy` |
| Last scrub | `zpool status tank` | `scrub repaired 0B ... with 0 errors` |

Errors or `DEGRADED` → look at the `READ / WRITE / CKSUM` columns. A disk with
growing counts → replace it (next section). Check `smartctl -a` on it too.

## 10. Replace a disk

```
 DEGRADED ─► find bad disk ─► new disk in ─► zpool replace ─► resilver ─► scrub ─► ONLINE
```

| # | Step | Command |
|---|---|---|
| 1 | Find the bad disk by-id | `zpool status -P tank` |
| 2 | Note its serial (by-id name contains it) | `ls -l /dev/disk/by-id/` |
| 3 | Fit the new disk. Same size or larger | Keep the old one in if you have a free port (safer) |
| 4 | Find the new disk by-id | `ls -l /dev/disk/by-id/ \| grep -v part` |
| 5 | Replace | `sudo zpool replace tank <old-by-id> /dev/disk/by-id/<new>` |
| 6 | Wait for resilver | `watch zpool status tank` |
| 7 | Check | `sudo zpool scrub tank`, then `zpool status -x` |
| 8 | Remove the old disk | Only after the pool is `ONLINE` |

🔴 During a resilver the pool has **one** good copy. Do not touch the other disk.

## Not verified yet (needs hardware)

| Item | Status |
|---|---|
| `zfs_mirror_setup.sh` real run (only the dry run is tested) | ⚪ |
| Disk checks: `lsblk` mount / ZFS label / `zpool status -LP` match | ⚪ |
| `zfs-scrub-monthly@.timer` exists on the chosen OS | ⚪ |
| `haotrannas.nft` loads (`nft -c` not run: needs root) | ⚪ |
| SSH, mDNS and port 47100 pass the firewall from the LAN | ⚪ |
| `wireguard_keys.sh` real run (`wg` not installed on the dev PC) | ⚪ |
| WireGuard handshake from 4G through the router | ⚪ |
| Android WireGuard app imports the QR (with comment lines) | ⚪ |
| ISP gives a public IP (no CGNAT) | ⚪ |
| IPv6 from the LAN: only ICMPv6 allowed, by design | ⚪ |
| Disk replacement procedure | ⚪ |
| `tls/` backup and restore | ⚪ |
