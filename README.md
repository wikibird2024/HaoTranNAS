# HaoTranNAS

Author: Hao Tran

My phone (and later my PC) backs up its files and photos to my own server,
at home or from anywhere, over a protocol I designed myself. It's a learning
project: protocols, an async server, storage, security and networking.

```
 mobile, desktop (Flutter) ─► dart_client ─┐
 cli (Rust) ───────────────► core ─────────┴─TLS─► server ─► chunk store + catalog ─► NAS disks
                 every side follows protocol/spec.md
```

| Folder | What |
|---|---|
| `docs/` | Start here: [docs/README.md](docs/README.md) |
| `protocol/` | Message definitions: the contract |
| `core/` | Rust library shared by server and cli |
| `server/` | Rust daemon on the NAS |
| `cli/` | Test client |
| `dart_client/` | Dart client logic shared by mobile and desktop |
| `mobile/` | Flutter phone app: Android and iPhone |
| `desktop/` | Flutter PC app |
| `nas/` | Host setup: ZFS, WireGuard, systemd |
| `yocto/` | NAS image built with Yocto for the Raspberry Pi 5 (M9) |
| `e2e/` | End-to-end tests |

Status and plan: [docs/roadmap.md](docs/roadmap.md).
