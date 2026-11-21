# HaoTranNAS — Architecture

Author: Hao Tran · Status: Draft v0.5 · 2026-11-21

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
Everything below the screens that is not Android-only lives in the shared
package `dart_client/` (D-040), so the PC app (M7) runs the same client:

```
 dart_client/  protocol · core (Link, TLS, log) · discovery · client (pairing, upload,
               download, identity, address book) · backup (runner, store, controller,
               MediaSource interface) · app (Riverpod state: identity, connection,
               pairing) · text (formatting, backup summaries) · testing (fakes)
     ▲                                   ▲
 mobile/  photo_manager source,      desktop/  (M7)
          workmanager jobs, multicast lock, phone UI
```

```
 Background job (workmanager plugin; Wi-Fi only, optional: only while charging; stops at 9 min)
 "Back up now" (workmanager one-off job, foreground service + notification, up to 5 h, D-038)
   │
   ▼
 Address book ► mDNS (foreground only: needs the Wi-Fi multicast lock)
   │            else last LAN address that worked, else WireGuard address
   ▼
 Scanner ────► chosen albums (Camera by default, D-037), newest first, streamed: each new/changed
   │           photo is uploaded as soon as it is found (path, size_bytes, modified_time_ms vs local DB)
   │
   ▼
 Chunker ────► 1 MiB chunks + SHA-256 each + whole-file SHA-256 (Dart crypto, in an isolate)
   │
   ▼
 Uploader ───► TLS with client cert → Hello → FileOffer → NeedChunks → ChunkData → Commit
   │
   ▼
 Local DB ───► sqflite: file marked "backed up" with version_id

 Screens: Pairing (searches Wi-Fi on open) ─► Home with 3 tabs:
          Backup (headline "Backed up?", live numbers, Stop, auto on/off, folders, last check)
          · Files (this phone first ─► folders ─► restore: photo/video ─► gallery, D-042)
          · Settings (Wi-Fi/charging for auto backup, unpair; Advanced: debug log)
```

| Rule | Why |
|---|---|
| A run uploads newest first and stops at its budget (9 min background, 5 h "Back up now" job); the next run re-offers and sends only missing chunks (D-032, D-038) | Today's photo must not wait behind 20,000 old ones |
| Only chosen albums are backed up; never chosen = Camera (D-037) | A first backup of a whole phone is too big to start with |
| The app and the "Back up now" job run in different isolates: progress goes job → app through workmanager, Stop goes app → job through the `stop_requested` value (D-038) | The job outlives the app screen |
| Backup state, settings, last reports and a run lock live in one SQLite file (D-033) | The app and the background job share it; the lock stops both uploading at once |
| "Back up now" ignores the Wi-Fi/charging settings; they shape only the background job (D-034) | A tap is an explicit request |
| "Check backup" (verify) re-offers every backed-up file; the server asks for any chunk scrub marked bad (spec §8) | Repair without ZFS (M6) |
| A restored photo or video goes into the gallery album `HaoTranNAS`; other files stay in the app (D-042) | A path inside the app's private folder is useless to the user |

### iPhone (same app, M8, D-043)

```
 Android                                   iPhone
 mDNS raw socket + multicast lock   ──►    Bonjour (bonsoir, NSBonjourServices)
 WorkManager every 15 min + 5 h job ──►    a run each time the app opens / comes back
 DCIM/Camera/IMG_1.jpg              ──►    iPhone/2026-11/IMG_0042.HEIC
 restore ─► album HaoTranNAS        ──►    restore ─► Photos (Recents)
 APK, fixed key, CI                 ──►    unsigned IPA from CI, sideloaded (free Apple ID, 7 days)
 dart_client, screens, pairing, TLS, upload, browse: the same code
```

| Rule | Why |
|---|---|
| iPhone backs up only while the app is open | iOS gives no long background time; our protocol is TLS, not HTTP |
| Folder = UTC month of the photo | Deterministic path (no re-upload after a trip); no IMG_xxxx clash |

## 6b. PC app (Flutter desktop, `desktop/`, M7)

Same client as the phone (`dart_client/`, D-040), a wide UI, and the NAS
admin panel (D-039, D-041).

```
 ┌───────────────┬───────────────────────────────────────────┐
 │ rail:         │ Overview  NAS card + this PC's backup     │
 │ Overview      │ Backup    folders, Back up now / Stop, hourly while open
 │ Backup        │ Files     devices ─► folders ─► restore file / folder (hash checked)
 │ Files         │ NAS       devices, revoke, pairing code, scrub, cleanup
 │ NAS           │ Settings  pairing, debug log, unpair
 │ Settings      │                                           │
 └───────────────┴───────────────────────────────────────────┘
 FolderMediaSource ─► BackupRunner (shared) ─► TLS ─► server
 AdminController ─► AdminLink ─► admin.sock (this PC) │ ssh -L ─► NAS admin.sock
```

| Rule | Why |
|---|---|
| Backup runs only while the app is open (timer, first run 30 s after start, then hourly) | No service or tray to maintain yet (D-039) |
| Restore never replaces a PC file: a taken name becomes `name (2)` | A restore must not destroy newer local work |
| Admin is read-mostly: pairing code, revoke (backups stay, D-025), scrub, cleanup | No config editing and no delete from a GUI |
| Pairing can take the code from admin.sock and compares the server id it came with | "Pair in one click" on the NAS owner's PC, still MITM-checked |

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
  ├─ scrub task      every scrub_interval_hours: re-hash every chunk (≤ 64 MiB/s),
  │                  mark bad / missing / repaired → <data_dir>/scrub-report.json
  ├─ cleanup task    hourly: delete uploads older than 24 h, temp files older than 1 h,
  │                  chunks no committed version uses (after a 24 h grace);
  │                  once a day: orphan chunk files with no catalog row (D-036)
  └─ admin socket    <data_dir>/admin.sock: pair, devices list/remove,
                     scrub-now, scrub-report, cleanup-now (D-035)
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

 /etc/haotrannas/config.toml settings (root:haotrannas 0640), see nas/config.example.toml
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
🟡 The Yocto image (M9, Raspberry Pi 5) uses mdadm RAID1 only (D-046).
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
| Stolen phone | `haotrannas-server devices --revoke <id>` → its cert is refused; its backups stay restorable and it stays in `ListDevices` so a new phone can restore from it (D-025, D-031) | 🟢 |

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
 ┌──────────────────────┐             ┌──────────────────────────┐
 │ dart_client          │             │ core (Rust library)      │
 │ Dart client logic    │             │ framing, hashing, chunks,│
 │ (D-040)              │             │ TLS, session             │
 └──┬────────────────┬──┘             └──┬──────────┬────────────┘
    ▼                ▼                   ▼          ▼
 ┌────────┐   ┌──────────┐ TLS    ┌──────────┐ ┌─────────┐
 │ mobile │   │ desktop  │───────►│ server   │ │ cli     │
 │ phone  │   │ PC (M7)  │        │ daemon   │ │ (test)  │
 └───┬────┘   └──────────┘        └────┬─────┘ └─────────┘
     └──────────────TLS───────────────►│
                                       │ runs on
                                       ▼
                              ┌───────────────────────────┐
                              │ nas: Linux, ZFS mirror,   │
                              │ WireGuard, systemd, backup│
                              │ or yocto: Pi 5 image (M9) │
                              └───────────────────────────┘
```

```
 HaoTranNAS/
   docs/       concepts, architecture, roadmap, decisions, conventions, research
   protocol/   spec.md + test vectors + vector generator
   core/       Rust library shared by server and cli
   server/     Rust daemon
   cli/        Rust test client
   dart_client/ Dart client logic shared by mobile and desktop (D-040)
   desktop/    Flutter PC app (M7)
   mobile/     Flutter phone app (patterns copied from Protocol Lab)
   nas/        host setup: ZFS, WireGuard, systemd, config
   yocto/      NAS image built with Yocto for the Raspberry Pi 5 (M9, D-044)
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
