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
| `ping` without `--dev-plain` | ⚪ M3 | "TLS arrives in M3; use --dev-plain", exit 2 |
| `pair upload upload-dir list download discover` | ⚪ later | "not implemented yet", exit 2 |

Exit codes: 0 ok, 1 the server or connection failed (`Error` / `Close` from
the server are shown by name, for example
`server error VERSION_MISMATCH: ...`), 2 not available yet or missing flag.
Connect timeout: `CONNECT_TIMEOUT_MS` (3 s); reply timeout 10 s.
