# cli

Rust command-line client: talks to the server without a phone. Used for tests and later as the desktop engine.

| | |
|---|---|
| Owns | Test and scripting commands (`ping`, `upload`, `list`, `download`) |
| First milestone | M0 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Run from the repo root (Cargo workspace).

| Step | Command |
|---|---|
| Build | `cargo build -p haotrannas-cli` |
| Pair (M3) | `cargo run -p haotrannas-cli -- --server 127.0.0.1:47100 pair --code 482913 --expect-server-id 3F9A-C21B-77E0` |
| Ping (TLS, paired) | `cargo run -p haotrannas-cli -- ping --count 3` |
| Run (dev, M0) | `cargo run -p haotrannas-cli -- --server 127.0.0.1:47100 ping --dev-plain --count 3` |
| Upload (dev, M1/M2) | `cargo run -p haotrannas-cli -- --server 127.0.0.1:47100 upload photo.jpg --as camera/photo.jpg --dev-plain` |
| Help | `cargo run -p haotrannas-cli -- --help` |
| Test | `cargo test -p haotrannas-cli` |
| Lint | `cargo clippy -p haotrannas-cli --all-targets -- -D warnings` |

Start a server for it first (see `server/README.md`, or
`e2e/scripts/start_dev_server.sh <data-dir>`). Logs go to stderr
(`RUST_LOG=debug`).

## Commands

| Command | Status | Output |
|---|---|---|
| `--server <host:port> pair --code C [--expect-server-id ID] [--device-name N]` | 🟢 M3 | `paired as device <id> with server <short id>` (identity folder on stderr) |
| `[--server <host:port>] ping [--count N]` | 🟢 M3 | Over mutual TLS with the saved pairing; output as with `--dev-plain` |
| `[--server <host:port>] upload <file> [--as <remote-path>]` | 🟢 M3 | Over mutual TLS; output as with `--dev-plain` |
| `--server <host:port> ping [--count N] --dev-plain` | 🟢 M0 | `connected: <server_name> (<server_software>), device <id>`, then `Pong in <ms> ms` per ping |
| `--server <host:port> upload <file> [--as <remote-path>] --dev-plain` | 🟢 M1/M2 | Exactly one line: `already backed up: version <id>` or `uploaded <sent> of <total> chunks (<new_bytes> bytes), version <id>` |
| `upload ... --stop-after-chunks N` (test) | 🟢 M2 | Ends after N chunks without `Commit` (a dropped connection): `stopped after <n> chunks (no commit)` |
| `upload ... --drop-after-commit` (test) | 🟢 M2 | Sends `Commit` and disconnects without reading `CommitOk` (a lost reply): `uploaded <sent> of <total> chunks (<new_bytes> bytes), commit sent, reply not read` |
| `upload-dir list download` | ⚪ later | "not implemented yet", exit 2 |

How `upload` works: one streaming pass hashes the file (`core::chunker`);
the backup path is `--as` or the file name (path rules checked locally);
`modified_time_ms` comes from the file. For each missing index it reads that
chunk again and re-hashes it; a difference stops with
`file changed during upload` (exit 1). On `CHUNKS_MISSING` at `Commit` it
offers the file again, at most 3 offers in all; it never retries `Commit`
alone.

### Pairing and identity (M3)

Global `--identity-dir <dir>`; default `$XDG_CONFIG_HOME/haotrannas`, else
`~/.config/haotrannas`.

| File | Content |
|---|---|
| `device.crt.pem` | This device's certificate from `PairOk` |
| `device.key.pem` | Its PKCS#8 key, mode 0600, never printed |
| `server.json` | `{"server_cert_sha256": <64 hex>, "device_id": n, "last_address": "host:port"}`, written last (the "paired" mark) |

`pair`: TLS without a client cert, any server cert accepted and its
fingerprint recorded (trust on first use) → `Hello` (must say device 0) →
`PairRequest` → `PairOk` → `PairOk.server_cert_sha256` must equal the
recorded fingerprint, and the short id must equal `--expect-server-id` when
given; otherwise nothing is saved (exit 1). Files are written temp + fsync +
rename. A folder that already holds a pairing is refused.

`ping` / `upload` without `--dev-plain`: TLS pinned to `server.json`'s
fingerprint, with the saved certificate; `--server` overrides the saved
address.

| Situation | Message (stderr), exit 1 |
|---|---|
| No pairing in the identity folder | `not paired: run `haotrannas-cli pair` first` |
| Server cert ≠ pin | `server identity changed (expected <pinned short id>, got <seen short id>)` |
| `NOT_PAIRED`, or the connection ends before `HelloOk` (TLS 1.3 shows a refused cert on the first read) | `this device is not paired (or was revoked)` |

Exit codes: 0 ok, 1 the server or connection failed (`Error` / `Close` from
the server are shown by name, for example
`server error VERSION_MISMATCH: ...`; not paired, identity changed), 2 not
available yet or missing flag (`--server` with `--dev-plain` or `pair`).
Connect timeout: `CONNECT_TIMEOUT_MS` (3 s); reply timeout 10 s.
