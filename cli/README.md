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
| `--server <host:port> ping [--count N] --dev-plain` | 🟢 M0 | `connected: <server_name> (<server_software>), device <id>`, then `Pong in <ms> ms` per ping |
| `--server <host:port> upload <file> [--as <remote-path>] --dev-plain` | 🟢 M1/M2 | Exactly one line: `already backed up: version <id>` or `uploaded <sent> of <total> chunks (<new_bytes> bytes), version <id>` |
| `upload ... --stop-after-chunks N` (test) | 🟢 M2 | Ends after N chunks without `Commit` (a dropped connection): `stopped after <n> chunks (no commit)` |
| `upload ... --drop-after-commit` (test) | 🟢 M2 | Sends `Commit` and disconnects without reading `CommitOk` (a lost reply): `uploaded <sent> of <total> chunks (<new_bytes> bytes), commit sent, reply not read` |
| `ping`, `upload` without `--dev-plain` | ⚪ M3 | "TLS arrives in M3; use --dev-plain", exit 2 |
| `pair upload-dir list download discover` | ⚪ later | "not implemented yet", exit 2 |

How `upload` works: one streaming pass hashes the file (`core::chunker`);
the backup path is `--as` or the file name (path rules checked locally);
`modified_time_ms` comes from the file. For each missing index it reads that
chunk again and re-hashes it; a difference stops with
`file changed during upload` (exit 1). On `CHUNKS_MISSING` at `Commit` it
offers the file again, at most 3 offers in all; it never retries `Commit`
alone.

Exit codes: 0 ok, 1 the server or connection failed (`Error` / `Close` from
the server are shown by name, for example
`server error VERSION_MISMATCH: ...`), 2 not available yet or missing flag.
Connect timeout: `CONNECT_TIMEOUT_MS` (3 s); reply timeout 10 s.
