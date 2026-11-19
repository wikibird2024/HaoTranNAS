# HaoTranNAS — Roadmap

Author: Hao Tran · Updated: 2026-11-18

Status lights: 🟢 done and checked · 🟡 in progress · ⚪ not started · 🔴 blocked

## Where we are now

```
 Phase 0 ──► M0 ──► M1 ──► M2 ──► M3 ──► M4 ──► M5 ──► M6 ──► M7
  done      done   done   done   done   ▲ HERE (wave 5: phone backup, browse + restore, scrub, verify)
```

## Phase 0: foundation

| Step | Status |
|---|---|
| Concepts, architecture, research docs | 🟢 |
| Sub-project folders | 🟢 |
| Roadmap, decisions, conventions | 🟢 |
| First commit + push | 🟢 |
| Protocol spec v1 + vectors (`protocol/`) | 🟢 frozen, tag `protocol-v1` |
| Rust workspace + Flutter app + NAS script scaffolds | 🟢 CI green |

## Milestones

Rule: a milestone is done only when its **Done when** check has passed and
been shown. Code alone doesn't count.

| # | Goal | Sub-projects | You learn | Done when | Status |
|---|---|---|---|---|---|
| M0 | Frames + Hello/Ping over plain TCP | protocol, core, server, cli, mobile | Framing, state machine, async | Unit tests pass; `cli ping` gets `Pong`; Dart client pings the Rust server (`e2e/scripts/flutter_vs_server.sh`) | 🟢 2026-11-18 |
| M1 | Upload one small file (no resume) | core, server, cli, mobile | Hashing | Server file hash = source file hash (`e2e/scripts/m1_upload.sh`) | 🟢 2026-11-18 |
| M2 | Chunks + NeedChunks + Commit | core, server, cli, e2e, mobile | Chunking, idempotency, atomicity | e2e test: kill connection mid-upload, resume works, no duplicate chunks (`e2e/tests/m1_m2.rs`) | 🟢 2026-11-18 |
| M3 | Pairing + mutual TLS + mDNS | core, server, cli, mobile | Trust, certificates | Unpaired client refused; paired client works (`e2e/tests/m3.rs`, `m3_pair.sh`); Dart app pairs + uploads over mTLS (`flutter_vs_server.sh`) | 🟢 2026-11-19 |
| M3n | NAS host ready | nas | Linux admin, ZFS | Server runs as a service on the NAS; survives reboot | ⚪ |
| M4 | Phone auto-backup (Flutter) | mobile | Android background work | New photo appears on server without a tap | ⚪ |
| M5 | Browse + download | server, mobile, cli | Read path | Restore a photo to the phone; hash matches | ⚪ |
| M6 | Remote + upkeep: WireGuard, scrub, cleanup, phone "verify backup" | nas, server, mobile | Networking, data care | Backup works on 4G; scrub report clean; a corrupted chunk is repaired by verify | ⚪ |
| M7 | Desktop app | desktop, core | Reusing core | PC folder backed up and restored | ⚪ |

## Build order and why

```
 protocol ─► core + server + cli ─► nas ─► mobile ─► desktop
```

| Order | Reason |
|---|---|
| protocol first | Everyone depends on it |
| server + cli together | They test each other; no phone needed |
| nas before mobile | The phone needs a real server to back up to |
| desktop last | It's the cli plus a UI, cheap once core exists |

## Later (parked on purpose)

Don't start these before the trigger happens. This list stops scope creep.

| Idea | From | Start when |
|---|---|---|
| Content-defined chunking | restic | M6 done and edited files are common |
| Pack small chunks into pack files | restic | Chunk count passes ~1 million |
| Offsite copy of the store | restic | M6 done |
| End-to-end encryption | Ente | The server ever leaves home |
| Rust core inside the phone app (flutter_rust_bridge) | — | Dart and Rust codecs drift apart despite the vectors |
| QR-code or PAKE pairing; phone-made key + CSR | Syncthing, Signal | Pairing outside a trusted home LAN |
| Web UI | Immich | M7 done and still wanted |
| Photo search / AI | Immich | Never in this project; use Immich if needed |
