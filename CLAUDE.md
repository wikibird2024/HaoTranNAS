# HaoTranNAS — project rules for Claude

One-repo learning project: phone/PC backup to a self-built server on a home NAS.

## Read before working

| When | Read |
|---|---|
| Any design question | `docs/architecture.md`, `docs/decisions.md` |
| Picking the next task | `docs/roadmap.md` (current milestone and its "Done when") |
| Writing code or adding files | `docs/conventions.md` (folder ownership, dependency rules, naming) |

## Project facts

- Sub-projects: `protocol core server cli desktop mobile nas e2e`; system docs live only in root `docs/`.
- `protocol/spec.md` is the single source of truth for the wire format. Change it first, regenerate vectors (`python3 protocol/tools/gen_vectors.py`), then the Rust and Dart codecs. The spec wins over code.
- Casing follows each language: Rust `snake_case`, Dart `lowerCamelCase` (files `snake_case.dart`), types `PascalCase`. Units go in names (`idle_timeout_ms`).
- Phone app = Flutter (`mobile/`), patterns from Protocol Lab (`/mnt/storage/PERSONAL/Learning/Android-app-to-learn-protocol-and-communication`): codec pure, Link = I/O, decoders never throw.
- Flutter: `/mnt/storage/HaoTran/sdk/flutter/bin` on PATH, `PUB_CACHE=/mnt/storage/HaoTran/sdk/pub-cache`. APKs are built only in GitHub CI.
- Build/run/test commands live in each sub-project's `README.md`.
- CI pins Rust 1.98.1 (= this PC's stable). Upgrade both on purpose. Keep build output, worktrees and SDKs on `/mnt/storage`; never add a `rust-toolchain.toml` that makes rustup download into `~/.rustup`.
- e2e tests are fsync-heavy: run them with `TMPDIR` on the root SSD (`/tmp`) when it has a few GB free. `/mnt/storage` is a slow disk for fsync (~280 ms each) and makes parallel e2e tests time out.

## Hard rules

- Data safety rules in `docs/conventions.md` §4 are never weakened without asking Hao.
- Work outside the current milestone goes to "Later" in `docs/roadmap.md`, not into code.
- A design change adds a row to `docs/decisions.md` and updates `docs/architecture.md` in the same commit.
- Update the status lights in `docs/roadmap.md` when a milestone check passes.
