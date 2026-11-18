# e2e

End-to-end tests: run the real server and drive it with the cli. No phone needed.

| | |
|---|---|
| Owns | Resume, dedupe, crash-safety and pairing tests |
| First milestone | M2 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Run from the repo root (Cargo workspace). The tests start the real
programs from `target/debug/`, so build them first.

| Step | Command |
|---|---|
| Build the programs | `cargo build --workspace --bins` |
| Test | `cargo test -p haotrannas-e2e` |
| Lint | `cargo clippy -p haotrannas-e2e --all-targets -- -D warnings` |

Helpers live in `src/lib.rs` (`workspace_binary("haotrannas-server")`
gives the program path; honours `CARGO_TARGET_DIR`).
