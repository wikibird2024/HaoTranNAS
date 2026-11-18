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
| Run | `cargo run -p haotrannas-cli -- --server <host:port> --identity-dir <folder> ping` |
| Help | `cargo run -p haotrannas-cli -- --help` |
| Test | `cargo test -p haotrannas-cli` |
| Lint | `cargo clippy -p haotrannas-cli --all-targets -- -D warnings` |

Commands: `ping pair upload upload-dir list download discover`. Logs go to
stderr (`RUST_LOG=debug`). Scaffold for now: every command prints "not
implemented yet" and exits with code 2.
