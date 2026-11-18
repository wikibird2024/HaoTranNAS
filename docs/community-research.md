# HaoTranNAS — What the community already does

Author: Hao Tran · Checked: 2026-11-18 (GitHub API) · Status: Draft v0.1

Status lights: 🟢 fine / adopted · 🟡 change we take · 🔴 avoid · ⚪ later / not checked

---

## 1. Verdict

🟢 **Our design matches what the most popular projects do.** Their shared
core idea: hash the content, and the server says what it is missing.
🟡 We borrow three things: device identity from the TLS certificate, LAN
discovery, and the one-repo layout.

```
  Syncthing ──► PROTOCOL       protobuf over TLS, device ID = cert hash, blocks
  restic    ──► STORAGE        chunks named by hash, packs, scrub
  Immich    ──► PHONE + REPO   phone backup flow, one repo, API spec → clients
  LocalSend ──► DISCOVERY      app finds the server on Wi-Fi by itself
  Ente      ──► DOCS + CRYPTO  architecture/ folder in repo, E2E keys (later)
```

## 2. Community vote (GitHub stars on 2026-11-18)

| Project | ⭐ | Lang | What we learn | Status |
|---|---|---|---|---|
| [Immich](https://github.com/immich-app/immich) | 119.5k | TS + Flutter | Phone backup flow, one repo, API spec → clients | 🟢 active |
| [LocalSend](https://github.com/localsend/localsend) | 99.5k | Dart | LAN discovery, protocol in its own documented repo | 🟢 active |
| [Syncthing](https://github.com/syncthing/syncthing) | 90.5k | Go | **Sync protocol (BEP)** | 🟢 active |
| [rclone](https://github.com/rclone/rclone) | 61k | Go | Chunked transfer, many backends | 🟢 active |
| [PhotoPrism](https://github.com/photoprism/photoprism) | 40.5k | Go | Photo indexing | 🟢 active |
| [Nextcloud](https://github.com/nextcloud/server) | 37.5k | PHP | Full cloud; shows how big scope gets | 🟡 scope warning |
| [restic](https://github.com/restic/restic) | 37.3k | Go | **Chunk store** | 🟢 active |
| [SeaweedFS](https://github.com/seaweedfs/seaweedfs) | 36k | Go | Many small files at scale | 🟢 active |
| [Ente](https://github.com/ente/ente) | 30.2k | Go + Flutter | One repo, architecture doc, E2E encryption | 🟢 active |
| [kopia](https://github.com/kopia/kopia) / [borg](https://github.com/borgbackup/borg) | 14.7k / 13.9k | Go / Python | Same idea as restic | 🟢 active |
| [OpenMediaVault](https://github.com/openmediavault/openmediavault) | 7.1k | PHP | NAS host OS | 🟢 active |
| [Garage](https://github.com/deuxfleurs-org/garage) | 4.9k | Rust | S3 store in Rust, if ever needed | 🟢 active |
| [MinIO](https://github.com/minio/minio) | 61k | Go | — | 🔴 archived 2026-04 |
| [filebrowser](https://github.com/filebrowser/filebrowser) | 35.8k | Go | — | 🔴 archived 2026-07 |

## 3. What they all agree on

| Pattern | Who does it | Our design |
|---|---|---|
| Hash the content, server says what it lacks | Syncthing (blocks), Immich (`/assets/bulk-upload-check`), restic | 🟢 FileOffer → NeedChunks |
| Content-addressed storage | restic, kopia, borg, git | 🟢 `chunks/ab/cd/<sha256>` |
| Protocol schema in one file | Syncthing `proto/bep/bep.proto`, Immich `open-api/` | 🟢 `protocol/*.proto` |
| One repo: server + mobile + web + docs | Immich, Ente, LocalSend | 🟢 our layout (section 5) |
| TLS everywhere, no open port | Syncthing, LocalSend (HTTPS) | 🟢 TLS + WireGuard |

## 4. What we change because of them

| Change | From | Why |
|---|---|---|
| 🟡 Phone identity = TLS client cert fingerprint (mutual TLS) | Syncthing | No bearer token to leak; TLS checks both sides |
| 🟡 LAN discovery with mDNS | LocalSend (multicast) | App finds the server without typing an IP |
| 🟡 Message names close to BEP | Syncthing | Read their code side by side with ours |
| ⚪ Pack small chunks into pack files | restic | Avoids millions of tiny files on disk |
| ⚪ End-to-end encryption key tree | Ente | Only if the server ever leaves home |
| 🔴 No MinIO / filebrowser dependency | — | Archived, no future fixes |

## 5. One-repo layout (shape of Immich + Ente)

Our final layout is in [architecture.md §12](architecture.md). This table shows where each folder idea came from.

| Their folder | Ours |
|---|---|
| Immich `server/`, Ente `server/` | `server/` |
| Immich `mobile/`, Ente `mobile/` | `mobile/` |
| Immich `open-api/`, Syncthing `proto/` | `protocol/` |
| Immich `packages/`, Ente `rust/` (shared code) | `core/` |
| Ente `cli/`, LocalSend `cli/` | `cli/` |
| Ente `desktop/` | `desktop/` |
| Immich `e2e/` | `e2e/` |
| Immich `docker/`, `deployment/` | `nas/` |
| Ente `architecture/`, Immich `docs/` | `docs/` |

## 6. Reading list (one file each, in this order)

| # | Read | Why |
|---|---|---|
| 1 | [Syncthing `proto/bep/bep.proto`](https://github.com/syncthing/syncthing/blob/main/proto/bep/bep.proto) | A real sync protocol in one file: Hello, ClusterConfig, Index, Request, Response, Ping, Close |
| 2 | [restic `doc/design.rst`](https://github.com/restic/restic/blob/master/doc/design.rst) | How a chunk store is laid out on disk |
| 3 | [LocalSend protocol repo](https://github.com/localsend/protocol) (`README.md`, `v3/`) | Discovery + a simple transfer protocol, well written |
| 4 | [Ente `architecture/README.md`](https://github.com/ente/ente/blob/main/architecture/README.md) | How to explain keys and flows in a doc |
| 5 | [Immich `open-api/immich-openapi-specs.json`](https://github.com/immich-app/immich/tree/main/open-api) | How one API spec feeds server, mobile and web |

## 7. Not checked

| | Item |
|---|---|
| ⚪ | Star counts change daily; numbers are from 2026-11-18 |
| ⚪ | Immich's upload code itself (only its API paths were checked) |
| ⚪ | LocalSend protocol content (only the repo file list was checked: `README.md`, `v1.md`, `v3/`) |
