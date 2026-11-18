# HaoTranNAS

Author: Hao Tran

My phone (and later my PC) backs up its files and photos to my own server,
at home or from anywhere, over a protocol I designed myself. It's a learning
project: protocols, an async server, storage, security and networking.

```
 mobile / cli / desktop ──TLS──► server ──► chunk store + catalog ──► NAS disks
             └──── all speak the same protocol/ ────┘
```

| Folder | What |
|---|---|
| `docs/` | Start here: [docs/README.md](docs/README.md) |
| `protocol/` | Message definitions: the contract |
| `core/` | Rust library shared by server, cli, desktop |
| `server/` | Rust daemon on the NAS |
| `cli/` | Test client |
| `desktop/` | PC app (later, M7) |
| `mobile/` | Android app (to be imported) |
| `nas/` | Host setup: ZFS, WireGuard, systemd |
| `e2e/` | End-to-end tests |

Status and plan: [docs/roadmap.md](docs/roadmap.md).
