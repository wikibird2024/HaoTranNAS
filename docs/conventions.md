# HaoTranNAS — Conventions

Author: Hao Tran · Updated: 2026-11-19

The rules that keep every sub-project the same shape. If a rule blocks you,
change it here first (with a row in `decisions.md`), then follow the new rule.

## 1. Sub-projects and who owns what

| Folder | Owns | Must NOT |
|---|---|---|
| `protocol/` | `spec.md`, test vectors, the vector generator script | Contain app code |
| `core/` | Framing, hashing, chunking, session state, TLS setup (Rust library) | Know about SQLite, disks paths or a UI |
| `server/` | Listener, handlers, chunk store, catalog, background jobs | Contain protocol logic that belongs in `core` |
| `cli/` | Command-line client for testing and scripting | Have features the server doesn't support yet |
| `dart_client/` | Dart client logic shared by the apps: codec, Link/TLS, discovery, pairing, upload/download, backup runner (D-040) | Contain UI or Android/desktop-only plugin code |
| `desktop/` | Flutter PC app (M7): folder source, admin client, PC UI | Re-implement anything `dart_client` has |
| `mobile/` | Flutter phone app: photo source, background jobs, phone UI | Change the wire format without changing `protocol/` first; hold logic the PC app also needs |
| `nas/` | Host setup: ZFS, WireGuard, systemd, config, backup scripts | Contain application code |
| `e2e/` | End-to-end tests: cli ⇄ server | Depend on a real phone |

## 2. Who may depend on whom

```
            protocol              ← everyone reads the contract
           ▲        ▲
           │        │
         core     dart_client
        ▲    ▲     ▲       ▲
        │    │     │       │
   server   cli  mobile  desktop      e2e ──► cli + server (as programs)

   nas: no code dependencies; it runs the server
```

| Allowed | Forbidden |
|---|---|
| server → core → protocol | core → server |
| cli → core | server → cli, or anything → desktop |
| mobile / desktop → dart_client → protocol | anything → mobile; dart_client → an app |

## 3. Protocol changes

| Rule | Why |
|---|---|
| Change `spec.md` first, regenerate vectors, then the code | It is the contract |
| Never reuse or renumber a message type, error code or close reason | Old clients would misread data |
| Any change to the bytes → bump `PROTOCOL_VERSION` | `Hello` rejects mismatched peers cleanly |
| Every message has vectors that both Rust and Dart pass | Proves both codecs agree byte for byte |
| Code and spec disagree → the spec wins | Never "fix" a vector to match code |
| Every new message gets an e2e test | Proves the whole path works |

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
| Casing follows the language | Rust: `snake_case` · Dart: `lowerCamelCase`, files `snake_case.dart` · types: `PascalCase` |

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
