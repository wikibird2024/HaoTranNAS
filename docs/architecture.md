# HaoTranNAS — Architecture

Author: Hao Tran · Status: Draft v0.3 · 2026-11-18

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

## 6. Phone app (Flutter, `mobile/`)

Same layering as Protocol Lab: **codec = pure bytes, Link = I/O, screens = glue.**

```
 Background job (workmanager plugin; Wi-Fi only, optional: only while charging; stops at 9 min)
   │
   ▼
 Address book ► mDNS (foreground only: needs the Wi-Fi multicast lock)
   │            else last LAN address that worked, else WireGuard address
   ▼
 Scanner ────► new/changed photos and files (photo_manager; path, size_bytes, modified_time_ms vs local DB)
   │
   ▼
 Chunker ────► 1 MiB chunks + SHA-256 each + whole-file SHA-256 (Dart crypto, in an isolate)
   │
   ▼
 Uploader ───► TLS with client cert → Hello → FileOffer → NeedChunks → ChunkData → Commit
   │
   ▼
 Local DB ───► sqflite: file marked "backed up" with version_id

 Screens: Pairing · Backup status · Browse + restore · Settings · Debug log
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
  ├─ cleanup task    hourly: delete uploads older than 24 h, temp files older than 1 h,
  │                  chunks no committed version uses (after a 24 h grace)
  └─ admin socket    <data_dir>/admin.sock: pair, devices list/remove, scrub-now
```

## 8. Protocol

**The full contract is [protocol/spec.md](../protocol/spec.md).** This
section is only the overview; when the two differ, the spec wins.

```
 ┌──────────────┬──────────────┬──────────────┬──────────────────────────┐
 │ length_bytes │ message_type │ request_id   │ payload                  │
 │ u32          │ u16          │ u32          │ hand-written binary      │
 └──────────────┴──────────────┴──────────────┴──────────────────────────┘
 Big-endian. Max 4 MiB. One reply (or Error) per request, in order.
```

Payloads are hand-written binary (fixed fields, length-prefixed strings and
lists), the same rule as Protocol Lab: you can see every byte. The Rust codec
and the Dart codec are written separately, and both must pass the same test
vectors in `protocol/vectors/`.

| Group | Client → Server | Server → Client | Syncthing BEP twin |
|---|---|---|---|
| Start | `Hello` | `HelloOk` (`device_id` 0 = not paired) | `Hello` |
| Pair (once) | `PairRequest(code)` | `PairOk` (device cert + key) | — (BEP: user accepts device ID) |
| Upload | `FileOffer` (path, size, time, file hash, chunk hashes) | `NeedChunks` (upload id, existing version, missing indexes) | `Index` / `IndexUpdate` |
| Upload | `ChunkData` (upload id, index, hash, bytes) | `ChunkOk` | `Request` / `Response` (reversed) |
| Upload | `Commit` | `CommitOk` | — |
| Browse | `ListDevices`, `ListDir` (paged) | `DeviceList`, `DirEntries` | — (BEP sends full index) |
| Download | `ReadFile`, then `ReadChunk` per chunk | `FileManifest`, `ChunkContent` | `Request` / `Response` |
| Keepalive | `Ping` | `Pong` | `Ping` |
| End | `Close` | `Close` | `Close` |
| Any | — | `Error(code, message)` | `ErrorCode` in `Response` |

Identity comes from TLS (mutual TLS, like Syncthing). There is no `Auth`
message and no token.

### Session state machine (server side)

```
             Hello ok, cert known
 AwaitingHello ─────────────────────────────► Ready ◄──┐ requests
      │  Hello ok, no cert                              └─────────┘
      ▼
   Unpaired ──PairRequest ok──► PairOk + Close ──► phone reconnects with its cert

 Any bad frame or forbidden message → Error + closed
 No Hello in 10 s, or idle 60 s → Close
```

## 9. Storage

### On disk

```
 /srv/haotrannas/
   chunks/ab/cd/abcd…ef      one file per chunk, name = SHA-256 hex, never changed
   tmp/                      chunks being written
   index.sqlite              all metadata (WAL mode)
   tls/server.key server.crt          server identity (clients pin its SHA-256)
   tls/device-ca.key device-ca.crt    signs device certificates at pairing
   admin.sock                local admin commands (mode 0600)
   config.toml
```

Chunk write is atomic: write to `tmp/` → fsync → re-hash and compare → rename
into `chunks/` → fsync the directory. A crash leaves only junk in `tmp/`, which
cleanup deletes. 🔴 Losing `tls/` means every device must pair again: back it up
with the store.

### Index tables

| Table | Columns | Meaning |
|---|---|---|
| `devices` | id, name, cert_sha256, paired_at_ms | Paired devices, known by TLS cert |
| `files` | id, device_id, path | One row per file path per device |
| `versions` | id, file_id, size_bytes, modified_time_ms, file_sha256, committed_at_ms | Each backup of a file |
| `version_chunks` | version_id, position, chunk_hash | Which chunks, in which order |
| `chunks` | hash, size_bytes, status (ok / bad), created_at_ms | Chunks on disk |
| `uploads` | id, device_id, path, size_bytes, modified_time_ms, file_sha256, created_at_ms | Started, not committed yet |
| `upload_chunks` | upload_id, position, chunk_hash | The offered chunk list |

No reference counts: a chunk is unused when no `version_chunks` or
`upload_chunks` row names it. Cleanup checks that inside the single writer, so
it can never race an upload.

### Disks

🟢 Borrowed: ZFS mirror or mdadm RAID1 under `/srv/haotrannas`.
🟡 RAID is not a backup. Later: copy the whole store to a second disk or offsite
(restic).

## 10. Security

| Layer | How | Status |
|---|---|---|
| Network | No open port to the internet. Outside home: WireGuard only | 🟢 |
| Discovery | mDNS on the LAN only; outside home the app uses the WireGuard address | 🟢 |
| Pairing | LAN source addresses only. `haotrannas-server pair` prints a 6-digit code (single use, 2 min) and the server's short id; the app shows the id it saw, and you compare them | 🟡 trust on first use |
| Device identity | Mutual TLS: the server issues each device its cert at pairing and knows it by SHA-256 fingerprint | 🟢 |
| Server identity | Self-signed cert; the app pins its fingerprint; no hostname check (connect by IP) | 🟢 |
| Limits | Max frame size, 3 bad pair codes → close, pairing rate limit | 🟢 |

## 11. What can go wrong

| Case | What happens | Data safe? |
|---|---|---|
| Wi-Fi drops mid-upload | Re-offer → server asks only for missing chunks | 🟢 |
| Server crash mid-chunk | Junk in `tmp/`, cleanup removes it | 🟢 |
| Server crash before Commit | Upload not visible; phone retries | 🟢 |
| Chunk corrupted in transit | Hash mismatch → `Error`, phone resends | 🟢 |
| `CommitOk` lost | Phone re-offers; server answers "already have version N" | 🟢 |
| Bit rot on disk | Scrub marks the chunk bad. Repaired by the ZFS mirror, or when a phone re-offers the file ("verify backup", M6) | 🟡 needs ZFS or verify |
| Disk full | `Error(DiskFull)` before writing, nothing committed | 🟢 |
| Stolen phone | Delete its row in `devices` → its cert is refused | 🟢 |

## 12. Sub-projects (one repo)

```
                     ┌────────────────────────┐
                     │  protocol              │  the contract everyone obeys
                     │  spec.md + vectors     │
                     └───┬─────────┬──────────┘
          implements +   │         │   implements +
          tests against  │         │   tests against
           ┌─────────────┘         └──────────────┐
           ▼                                      ▼
 ┌──────────────────┐                 ┌──────────────────────────┐
 │ mobile           │                 │ core (Rust library)      │
 │ Flutter (Dart)   │                 │ framing, hashing, chunks,│
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
   protocol/   spec.md + test vectors + vector generator
   core/       Rust library shared by server, cli, desktop
   server/     Rust daemon
   cli/        Rust test client
   desktop/    PC app (M7)
   mobile/     Flutter phone app (new; patterns copied from Protocol Lab)
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
