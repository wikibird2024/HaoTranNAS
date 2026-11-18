# HaoTranNAS — Decisions

Author: Hao Tran · Updated: 2026-11-18

Status lights: 🟢 decided · 🟡 decided, revisit at the trigger · ⚪ assumed, needs confirming

Rules:
- One row per decision. Never delete a row; mark it **Replaced by D-xxx** instead.
- A design change starts here, then `architecture.md` is updated in the same commit.

## Decided

| ID | Decision | Why | Status | Revisit when |
|---|---|---|---|---|
| D-001 | One git repo for every part (server, mobile, desktop, nas, protocol) | Immich and Ente do it; one change can touch the protocol and both sides at once | 🟢 | — |
| D-002 | Root `docs/` + a README per sub-project | One home per topic, no drift | 🟢 | A README passes ~1 page |
| D-003 | Server in Rust + tokio | Learning goal; safe and fast async | ⚪ | Hao confirms |
| D-004 | Shared Rust `core` crate for server, cli, desktop | Write the protocol once; the cli tests what the desktop runs | 🟡 | — |
| D-005 | Android stays Kotlin with its own protocol code | Existing app; a second implementation tests the spec | ⚪ | Language confirmed / code drifts |
| D-006 | Own protocol: length-prefixed frames + protobuf payload | Hand-written framing to learn; protobuf gives one schema for Kotlin + Rust | 🟡 | — |
| D-007 | Content-addressed chunks, SHA-256, fixed 1 MiB | Dedupe, integrity, resume; SHA-256 is built into Android | 🟡 | CDC trigger in roadmap |
| D-008 | Upload = FileOffer → NeedChunks → ChunkData → Commit | Resume and dedupe for free; same idea as Syncthing / Immich | 🟢 | — |
| D-009 | SQLite catalog, written by one task only | Simple, crash-safe, no write races | 🟢 | — |
| D-010 | Device identity = mutual TLS cert fingerprint; first pairing by 6-digit code on LAN | Syncthing model; no token to leak | 🟡 | — |
| D-011 | No port open to the internet; remote access only via WireGuard | Smallest attack surface | 🟢 | — |
| D-012 | LAN discovery via mDNS | LocalSend model; no IP typing | 🟡 | — |
| D-013 | Disks: ZFS mirror (borrowed, not built) | Mistakes in disk code lose data | 🟡 | Hardware known |
| D-014 | Desktop app after M6 (M7) | Not needed for phone backup | 🟢 | — |
| D-015 | No dependency on MinIO or filebrowser | Both archived in 2026 | 🟢 | — |

## Open questions

| ID | Question | Blocks |
|---|---|---|
| O-1 | Where is the Android app repo? Import with history (`git subtree`)? | Phase 0 import, M4 |
| O-2 | What protocol does the existing Android app speak? Reuse any of it? | M4 |
| O-3 | Server hardware (PC, Raspberry Pi, disks)? | M3n, D-013 |
| O-4 | Desktop app: which OS, backup only or also browse? | M7 |

## Template for a new decision

```
| D-0xx | <what we chose> | <why, one line> | 🟢/🟡/⚪ | <trigger to look again> |
```
