# core

Rust library shared by server, cli and desktop: framing, hashing, chunking, session state, TLS.

| | |
|---|---|
| Owns | Everything both sides of a connection need |
| First milestone | M0 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Run from the repo root (Cargo workspace).

| Step | Command |
|---|---|
| Build | `cargo build -p haotrannas-core --all-features` |
| Test | `cargo test -p haotrannas-core --all-features` |
| Lint | `cargo clippy -p haotrannas-core --all-targets --all-features -- -D warnings` |

Library only, nothing to run. Cargo features: `tokio` (async frame I/O,
`io.rs`) and `tls` (rustls + ring, TLS 1.3 only, `tls.rs`). Server and cli
turn both on.

`session.rs` is the spec §6 state machine (pure: state + message type →
allowed, or the fatal error code). `io.rs` reads and writes whole frames on
any tokio stream; the length field is checked from its 4 bytes before the
body is awaited, and a dropped read loses no bytes.
