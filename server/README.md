# server

Rust daemon that runs on the NAS: listener, handlers, chunk store, SQLite catalog, background jobs.

| | |
|---|---|
| Owns | Storage and the server side of the protocol |
| First milestone | M0 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Run from the repo root (Cargo workspace).

| Step | Command |
|---|---|
| Build | `cargo build -p haotrannas-server` |
| Run | `cargo run -p haotrannas-server -- <init\|run\|pair\|devices\|restore\|scrub-now>` |
| Help | `cargo run -p haotrannas-server -- --help` |
| Test | `cargo test -p haotrannas-server` |
| Lint | `cargo clippy -p haotrannas-server --all-targets -- -D warnings` |

Logs go to stderr; set the level with `RUST_LOG`, for example `RUST_LOG=debug`.
Scaffold for now: every command prints "not implemented yet" and exits with code 2.
