# HaoTranNAS — Conventions

Author: Hao Tran · Updated: 2026-11-18

The rules that keep every sub-project the same shape. If a rule blocks you,
change it here first (with a row in `decisions.md`), then follow the new rule.

## 1. Sub-projects and who owns what

| Folder | Owns | Must NOT |
|---|---|---|
| `protocol/` | Message definitions (`.proto`), frame layout, protocol spec | Contain code beyond generated output |
| `core/` | Framing, hashing, chunking, session state, TLS setup (Rust library) | Know about SQLite, disks paths or a UI |
| `server/` | Listener, handlers, chunk store, catalog, background jobs | Contain protocol logic that belongs in `core` |
| `cli/` | Command-line client for testing and scripting | Have features the server doesn't support yet |
| `desktop/` | PC app (M7) | Re-implement anything `core` has |
| `mobile/` | Android app | Change the wire format without changing `protocol/` first |
| `nas/` | Host setup: ZFS, WireGuard, systemd, config, backup scripts | Contain application code |
| `e2e/` | End-to-end tests: cli ⇄ server | Depend on a real phone |

## 2. Who may depend on whom

```
            protocol            ← everyone reads the contract
           ▲        ▲
           │        │
         core     mobile
        ▲  ▲  ▲
        │  │  │
   server cli desktop          e2e ──► cli + server (as programs)

   nas: no code dependencies; it runs the server
```

| Allowed | Forbidden |
|---|---|
| server → core → protocol | core → server |
| cli / desktop → core | server → cli, or anything → desktop |
| mobile → protocol | anything → mobile |

## 3. Protocol changes

| Rule | Why |
|---|---|
| Change the `.proto` file first, then the code | It is the contract |
| Never reuse or renumber a protobuf field | Old clients would misread data |
| Breaking change → bump `protocolVersion` | `Hello` rejects mismatched peers cleanly |
| Every new message gets an e2e test | Proves both sides agree |

## 4. Data safety rules (never weaken without asking Hao)

| Rule |
|---|
| A chunk is written to `tmp/`, fsynced, hash-checked, then renamed. Never written in place |
| A file version exists only after `Commit` (one SQLite transaction) |
| The server checks every chunk's hash before storing it |
| No port is open to the internet; remote access goes through WireGuard only |
| Limits stay on: max frame size, handshake / idle timeouts, pairing attempts |

## 5. Naming

| Rule | Example |
|---|---|
| Plain words that say what the thing is | `chunk_store`, not `cs` |
| Units in the name | `idle_timeout_ms`, `size_bytes`, `max_frame_bytes` |
| No one- or two-letter names | `chunk_hash`, not `h` |
| Casing follows the language | Rust and proto: `snake_case` · Kotlin: `camelCase` · types: `PascalCase` |

## 6. Done means checked

| Rule |
|---|
| Each sub-project README lists its build, run and test commands |
| "Works" means the build and tests ran and the output was shown |
| A milestone is done only when its **Done when** check in `roadmap.md` passed |
| Say what was not checked (for example: "needs a test on the real NAS") |

## 7. Git

| Rule | Example |
|---|---|
| Commit message starts with the sub-project | `server: add chunk store` · `docs: update roadmap` |
| One topic per commit | Don't mix a fix with a refactor |
| A design change updates the docs in the same commit | `decisions.md` row + `architecture.md` |
| Never commit secrets | Keys, certs, `config.toml` with real values |
