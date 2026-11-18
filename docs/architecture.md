# HaoTranNAS — Architecture

Author: Hao Tran · Status: Draft v0.2 · 2026-11-18

Read first: [concepts.md](concepts.md), the ideas this design rests on.
See also: [community-research.md](community-research.md), the projects this design borrows from.

Status lights: 🟢 decided · 🟡 decided, revisit later · ⚪ assumed, not confirmed yet

---

## 1. The idea in one line

**My phone backs up its files and photos to my own server, at home or from
anywhere, over a protocol I designed myself.**

Mental hook: **it is "git for my phone's files"**. Files are cut into chunks,
each chunk is named by its hash, and a backup only becomes real when it is
committed.

## 2. Goals and non-goals

| | Item |
|---|---|
| 🟢 Goal | Phone → server backup of photos and files, automatic |
| 🟢 Goal | Browse and download backed-up files from the phone |
| 🟢 Goal | Survive crashes, broken Wi-Fi and full disks without losing data |
| 🟢 Goal | Learn: protocol design, async server, storage, security, networking |
| 🔴 Not v1 | Web UI, many users, sharing links, photo AI / face search |
| 🔴 Never | Own RAID, own crypto, server port open to the internet |

## 3. Big picture

```
        PHONE                                 HOME SERVER (Linux box)
 ┌───────────────────────┐              ┌──────────────────────────────┐
 │ Android app           │              │ haotrannas-server (Rust)     │
 │                       │  TCP + TLS   │                              │
 │  Scanner ─► Hasher ─► │ ───────────► │  Listener ─► Session ─►      │
 │  Uploader             │  frames      │  Handlers ─► Storage         │
 │  Browser   ◄───────── │ ◄─────────── │                              │
 └───────────────────────┘              └──────────────┬───────────────┘
          │                                            │
          │  outside home: WireGuard VPN               ▼
          └──────────────────────────►     ┌──────────────────────┐
                                           │ disks (ZFS mirror /  │
                                           │ RAID1, borrowed)     │
                                           │  chunks/  index.db   │
                                           └──────────────────────┘
```

## 4. Three ideas that make everything work

| # | Idea | What we get from it |
|---|---|---|
| 1 | **Chunks named by their hash** (SHA-256 of the bytes) | Dedupe, integrity check, safe retries |
| 2 | **The server asks for what it is missing** ("NeedChunks") | Resume after a break comes for free; the client stays simple |
| 3 | **Nothing is real until Commit** (one DB transaction) | A crash never leaves a half file visible |

If you remember only this section, you know how the system works.

## 5. Upload: one file, end to end

```
 Phone                                          Server
   │ 1. read file, cut into 1 MiB chunks,         │
   │    SHA-256 each chunk                        │
   │──── FileOffer(path, sizeBytes, hashes[]) ───►│ 2. check which hashes
   │                                              │    already exist on disk
   │◄─── NeedChunks(uploadId, missing[]) ─────────│
   │──── ChunkData(hash, bytes) ─────────────────►│ 3. write tmp, fsync,
   │◄─── ChunkOk(hash) ───────────────────────────│    re-hash, rename
   │      ... repeat for each missing chunk ...   │
   │──── Commit(uploadId) ───────────────────────►│ 4. one SQLite transaction:
   │◄─── CommitOk(versionId) ─────────────────────│    new file version
   │ 5. mark file as backed up in local DB        │
```

Wi-Fi drops after step 3? Phone reconnects and sends the same FileOffer.
The server answers with only the chunks it still needs. That is the resume.

```
 Try 1:  Offer [h1 h2 h3] → Need [h2 h3] → send h2 ✔ → send h3 ✘ WIFI LOST
                                                  │
                                    server now has h1, h2
                                                  │
 Try 2:  Offer [h1 h2 h3] → Need [h3] ────────────┘ → send h3 ✔ → Commit ✔
```

The phone does not have to remember anything special: it sends the same
Offer, and the server's answer shows what is still missing.

## 6. Android app (client)

```
 WorkManager job (on Wi-Fi, optional: only while charging)
   │
   ▼
 Discovery ► finds the server on the LAN via mDNS (_haotrannas._tcp), else last known address
   │
   ▼
 Scanner ──► finds new/changed files (path, sizeBytes, modifiedTimeMs vs local DB)
   │
   ▼
 Hasher  ──► cuts into chunks, SHA-256 each (MessageDigest, built in)
   │
   ▼
 Uploader ─► connect, auth, FileOffer → NeedChunks → ChunkData → Commit
   │
   ▼
 Local DB ─► file marked "backed up" with versionId

 Screens: Pairing · Backup status · Browse server
```

## 7. Server inside: layers

Each layer only talks to the one below it.

```
 ┌────────────────────────────────────────────────────────────┐
 │ net       TLS listener, accept loop, one task per client   │
 ├────────────────────────────────────────────────────────────┤
 │ codec     bytes ⇄ frames (length prefix), frames ⇄ messages│
 ├────────────────────────────────────────────────────────────┤
 │ session   state machine, auth, timeouts, limits            │
 ├────────────────────────────────────────────────────────────┤
 │ handlers  FileOffer, ChunkData, Commit, ListDir, ReadFile  │
 ├────────────────────────────────────────────────────────────┤
 │ storage   chunk store (files on disk) + index (SQLite)     │
 └────────────────────────────────────────────────────────────┘
   background jobs: scrub (re-hash chunks) · cleanup (old uploads, unused chunks)
```

### Runtime (who runs what)

```
 tokio runtime
  ├─ accept loop ──► spawn 1 session task per connection
  │                    read frame → handle → write reply (in order, v1)
  ├─ db writer task ◄── all SQLite writes go through one channel (no lock fights)
  ├─ scrub task      weekly: re-hash every chunk, report bad ones
  └─ cleanup task    hourly: delete uploads older than 24 h, chunks with refCount 0
```

## 8. Protocol

### Frame (on the wire, inside TLS)

```
 ┌────────────┬────────────┬──────────────┬─────────────────────┐
 │ lengthBytes│ type       │ requestId    │ payload             │
 │ u32 BE     │ u16 BE     │ u32 BE       │ protobuf bytes      │
 └────────────┴────────────┴──────────────┴─────────────────────┘
 lengthBytes = size of everything after it. Max frame: 4 MiB → else close.
 requestId   = set by the client, copied in the reply (lets us pipeline later).
```

Framing is hand-written (that is the learning part). Payloads use protobuf, so
the `.proto` file is the single contract between Kotlin and Rust.

### Messages

Identity comes from TLS itself (mutual TLS, like Syncthing): each phone has
its own certificate, and the server knows phones by the SHA-256 fingerprint of
that certificate. There is no `Auth` message and no token.

| Group | Client → Server | Server → Client | Syncthing BEP twin |
|---|---|---|---|
| Start | `Hello(protocolVersion, deviceName)` | `HelloOk(serverVersion, paired)` | `Hello` |
| Pair (once) | `PairRequest(code, deviceName)` | `PairOk` (server saves cert fingerprint) | — (BEP: user accepts device ID) |
| Upload | `FileOffer(path, sizeBytes, modifiedTimeMs, chunkHashes[])` | `NeedChunks(uploadId, missing[])` | `Index` / `IndexUpdate` |
| Upload | `ChunkData(hash, bytes)` | `ChunkOk(hash)` | `Request` / `Response` (reversed) |
| Upload | `Commit(uploadId)` | `CommitOk(versionId)` | — |
| Browse | `ListDir(path)` | `DirEntries(entries[])` | — (BEP sends full index) |
| Download | `ReadFile(path, versionId?)` | `FileManifest(hashes[])` then `ChunkData`… | `Request` / `Response` |
| Keepalive | `Ping` | `Pong` | `Ping` |
| End | `Close(reason)` | `Close(reason)` | `Close` |
| Any | — | `Error(code, message)` | `ErrorCode` in `Response` |

We keep our own names (they say what an upload does); the last column lets us
read Syncthing's `bep.proto` side by side with ours.

### Session state machine (server side)

```
            Hello ok         cert known / Pair ok
 Connected ─────────► Greeted ─────────────────────► Ready ◄──┐
     │                   │                             │  requests
     │                   │ 3 bad pair codes            └──────┘
     ▼                   ▼                             │
   Closed ◄──────────── Closed ◄───────────────────────┘
   (no Hello in         (bad frame, idle > 60 s, client close)
    10 s)
```

| Timer / limit | Value |
|---|---|
| `handshakeTimeoutMs` | 10 000 |
| `idleTimeoutMs` (client pings every 20 s) | 60 000 |
| `maxFrameBytes` | 4 MiB |
| `maxPairFailures` per connection | 3 |

## 9. Storage

### On disk

```
 /srv/haotrannas/
   chunks/ab/cd/abcd…ef      one file per chunk, name = SHA-256 hex, never changed
   tmp/                      chunks being written
   index.sqlite              all metadata (WAL mode)
   tls/cert.pem key.pem
   config.toml
```

Chunk write is atomic: write to `tmp/` → fsync → re-hash and compare → rename
into `chunks/`. A crash leaves only junk in `tmp/`, which cleanup deletes.

### Index tables

| Table | Columns | Meaning |
|---|---|---|
| `devices` | id, name, certFingerprint, pairedAtMs | Paired phones, known by TLS cert |
| `files` | id, deviceId, path | One row per file path per phone |
| `versions` | id, fileId, sizeBytes, modifiedTimeMs, committedAtMs | Each backup of a file |
| `version_chunks` | versionId, position, chunkHash | Which chunks, in which order |
| `chunks` | hash, sizeBytes, refCount | Chunks that exist on disk |
| `uploads` | id, deviceId, path, manifest, createdAtMs | Started, not committed yet |

### Disks

🟢 Borrowed: ZFS mirror or mdadm RAID1 under `/srv/haotrannas`.
🟡 RAID is not a backup. Later: copy the whole store to a second disk or offsite
(restic).

## 10. Security

| Layer | How | Status |
|---|---|---|
| Network | No open port to the internet. Outside home: WireGuard only | 🟢 |
| Discovery | mDNS on the LAN only; outside home the app uses the WireGuard address | 🟢 |
| Pairing | LAN only. Server prints a 6-digit code (valid 2 min); app sends it once | 🟢 |
| Device identity | Mutual TLS: each phone has its own cert; server stores its SHA-256 fingerprint | 🟢 (Syncthing) |
| Server identity | Self-signed cert; app pins its fingerprint at pairing | 🟡 trust on first use |
| Limits | Max frame size, 3 bad pair codes → close, pairing rate limit | 🟢 |

## 11. What can go wrong

| Case | What happens | Data safe? |
|---|---|---|
| Wi-Fi drops mid-upload | Re-offer → server asks only for missing chunks | 🟢 |
| Server crash mid-chunk | Junk in `tmp/`, cleanup removes it | 🟢 |
| Server crash before Commit | Upload not visible; phone retries | 🟢 |
| Chunk corrupted in transit | Hash mismatch → `Error`, phone resends | 🟢 |
| Bit rot on disk | Scrub finds it; mirror repairs it (ZFS) | 🟡 needs ZFS |
| Disk full | `Error(DiskFull)` before writing, nothing committed | 🟢 |
| Stolen phone | Delete its row in `devices` → its cert is refused | 🟢 |

## 12. Sub-projects (one repo)

```
                     ┌────────────────────────┐
                     │  protocol              │  the contract everyone obeys
                     │  haotrannas.proto      │
                     └───┬─────────┬──────────┘
            generates    │         │   generates
           ┌─────────────┘         └──────────────┐
           ▼                                      ▼
 ┌──────────────────┐                 ┌──────────────────────────┐
 │ mobile           │                 │ core (Rust library)      │
 │ Android, Kotlin  │                 │ framing, hashing, chunks,│
 │                  │                 │ TLS, session             │
 └────────┬─────────┘                 └──┬──────────┬──────────┬─┘
          │                              ▼          ▼          ▼
          │      TLS              ┌──────────┐ ┌─────────┐ ┌──────────┐
          └──────────────────────►│ server   │ │ cli     │ │ desktop  │
                                  │ daemon   │ │ (test)  │ │ (M7)     │
                                  └────┬─────┘ └─────────┘ └──────────┘
                                       │ runs on
                                       ▼
                              ┌───────────────────────────┐
                              │ nas: Linux, ZFS mirror,   │
                              │ WireGuard, systemd, backup│
                              └───────────────────────────┘
```

```
 HaoTranNAS/
   docs/       concepts, architecture, roadmap, decisions, conventions, research
   protocol/   haotrannas.proto + spec
   core/       Rust library shared by server, cli, desktop
   server/     Rust daemon
   cli/        Rust test client
   desktop/    PC app (M7)
   mobile/     Android app (imported with history)
   nas/        host setup: ZFS, WireGuard, systemd, config
   e2e/        cli ⇄ server end-to-end tests
```

What each folder owns and the dependency rules: [conventions.md](conventions.md).

## 13. Milestones

Moved to [roadmap.md](roadmap.md) (single source of truth for plan and status).

## 14. Decisions

Moved to [decisions.md](decisions.md) (single source of truth for decisions and open questions).

## 15. Learn from the community

Full report with star counts and a reading list: [community-research.md](community-research.md).

| Project | What to copy |
|---|---|
| git | Content-addressed objects, commit = snapshot |
| Syncthing (BEP protocol) | Block hashes, index exchange, device pairing |
| restic / borg | Chunk store, content-defined chunking, scrub |
| Immich | Phone backup flow, Android background jobs |
