# HaoTran ecosystem: the idea (parked)

Author: Hao Tran · 2026-11-21 · Status: 🟡 idea, parked in `roadmap.md` "Later"

## 1. The idea in one line

One account, one home cloud, and devices that know each other, the way the
Apple and Google ecosystems feel, built **on top of** Android, iOS and Linux.
It is not a new operating system.

## 2. Layers

```
 ┌──────────── Apps (Flutter) ─────────────┐
 │  Photos   Files   Send   Notes   Find   │
 └───────────────────┬─────────────────────┘
 ┌───────────────────▼─────────────────────┐
 │ HaoTran Kit: ID · pairing · sync · push │  ← grows out of dart_client + core
 └───────────────────┬─────────────────────┘
 ┌───────────────────▼─────────────────────┐
 │ HaoTran Cloud = the NAS server (Rust)   │
 └───────────────────┬─────────────────────┘
     Android · iPhone · PC · Pi 5 (Yocto)
```

## 3. Pieces

| Piece | Like | Reuses | Verdict |
|---|---|---|---|
| 🟢 HaoTran ID (trusted devices) | Apple ID | M3 pairing, mTLS | first |
| 🟢 Photos backup | iCloud Photos | M4–M8 | exists today |
| 🟢 Files sync | iCloud Drive | chunks, M7 | first new app |
| 🟡 Send to my device | AirDrop | mDNS, mTLS | quick win |
| 🟡 Notes / contacts sync | iCloud sync | new sync layer | hard: edit clashes |
| 🟡 Find my devices | Find My | WireGuard (M6) | later |
| 🔴 Own OS or app store | Android, App Store | nothing | not doing it |

## 4. Order

1. Finish the open checks: M3n, M4–M6 on the phone, M8, M9.
2. One milestone, "HaoTran ID + Kit": one trusted-device list for every app,
   one place for sync and push, used by the existing backup first.
3. Then one app at a time, each with its own "Done when" check in `roadmap.md`.

## 5. Known hard parts

| Part | Why it is hard |
|---|---|
| 🟡 Sync with edit clashes | Two devices change the same thing offline; design it once, in the Kit |
| 🟡 Upkeep | Every app is one more thing to keep working; AI speeds up the code, not the device tests |
| 🟡 iPhone limits | No background work without a paid account (D-043) |
| 🟡 Leaving home | Outside the home LAN it needs end-to-end encryption and better pairing ("Later" rows) |

## 6. Before starting

This doc is only the idea. When the trigger in `roadmap.md` "Later" is met,
answer O-5 in `decisions.md`, then the chosen design goes into
`decisions.md` and `architecture.md` like any other design change.
