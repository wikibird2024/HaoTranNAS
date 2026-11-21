# HaoTranNAS — Roadmap

Author: Hao Tran · Updated: 2026-11-21

Status lights: 🟢 done and checked · 🟡 in progress · ⚪ not started · 🔴 blocked

## Where we are now

```
 Phase 0 ──► M0 ──► M1 ──► M2 ──► M3 ──► M4 ──► M5 ──► M6 ──► M7 ──► M8 (iPhone)
  done      done   done   done   done   ▲ HERE: M4–M6 code done and checked on the PC; phone + NAS checks open
                                          M8: code started 2026-11-19 in parallel, on Hao's call
                                          M9 (Yocto image, Pi 5): started 2026-11-21 in parallel, on Hao's call
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
| M4 | Phone auto-backup (Flutter) | mobile | Android background work | New photo appears on server without a tap | 🟡 code + host tests 2026-11-19; first phone test 2026-11-19: pairing 🟢, "Back up now" scanned without numbers and uploaded nothing → fixed by D-037 (albums) + D-038 (upload while scanning, long job with notification, 3-tab UI); phone check open (mobile/README phone checklist) |
| M5 | Browse + download | server, mobile, cli | Read path | Restore a photo to the phone; hash matches | 🟡 Dart app downloads from the real server, bytes match (`flutter_vs_server.sh`, `m5_download.sh`) 2026-11-19; phone check open |
| M6 | Remote + upkeep: WireGuard, scrub, cleanup, phone "verify backup" | nas, server, mobile | Networking, data care | Backup works on 4G; scrub report clean; a corrupted chunk is repaired by verify | 🟡 scrub, cleanup, heal by re-upload proven in `e2e/tests/m6.rs` 2026-11-19; 4G (WireGuard) + phone verify open |
| M7 | Desktop app | desktop, dart_client | Reusing the Dart client, desktop UI, admin over SSH | PC folder backed up and restored | 🟢 2026-11-19 `e2e/scripts/desktop_vs_server.sh`: PC folder (nested, 20 MiB, Unicode, symlink skipped) backed up and restored, every SHA-256 matches; real app on this PC: one-click pairing, 66 files backed up, phone photos browsed, scrub clean. ⚪ SSH admin to the real NAS (M3n), folder picker by hand |
| M8 | iPhone app (same Flutter app, D-043) | mobile | iOS limits: Bonjour, no background work, signing | On a real iPhone: pair, back up a photo by opening the app, restore it; hash matches | 🟡 2026-11-19 code: `ios/` folder, Bonjour finder, iPhone photo folders, restore to Photos, auto backup on open; CI builds an unsigned IPA. ⚪ sideload + every iPhone check (mobile/README) |
| M9 | NAS image built with Yocto for the Raspberry Pi 5 (D-044 to D-046) | yocto | Yocto: layers, recipes, distro, image, cross-build | On a real Pi 5: the image boots, is found as `nas.local`, `haotrannas-server` runs as a service and survives a reboot, and a phone backs up to it | 🟡 2026-11-21: `yocto/` started (kas file, layer, distro, image: boot + SSH + mdadm + avahi). ⚪ first build blocked on this PC by Ubuntu's user-namespace limit (yocto/README); ⚪ server recipe; ⚪ every Pi 5 check |

## Build order and why

```
 protocol ─► core + server + cli ─► nas ─► mobile ─► dart_client ─► desktop
```

| Order | Reason |
|---|---|
| protocol first | Everyone depends on it |
| server + cli together | They test each other; no phone needed |
| nas before mobile | The phone needs a real server to back up to |
| desktop last | The phone's Dart client plus a wide UI, cheap once dart_client exists (D-040) |

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
| HaoTran ecosystem: ID + Kit, then one app at a time (`docs/ecosystem.md`, O-5) | Apple / Google ecosystems | M3n, M4–M6, M8 and M9 checks all passed |
