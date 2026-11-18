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
| Make a data folder | `cargo run -p haotrannas-server -- init --data-dir /tmp/htn-data` |
| Run (dev, M0–M2) | `cargo run -p haotrannas-server -- run --dev-plain --data-dir /tmp/htn-data --listen 127.0.0.1:47100` |
| Help | `cargo run -p haotrannas-server -- --help` |
| Test | `cargo test -p haotrannas-server` |
| Lint | `cargo clippy -p haotrannas-server --all-targets -- -D warnings` |

Logs go to stderr (default level `info`; set it with `RUST_LOG`, for example
`RUST_LOG=debug`). Stop with Ctrl-C or SIGTERM: open connections get
`Close SERVER_SHUTDOWN`, then the server waits up to 2 s for them.

## Commands

| Command | Status | What it does |
|---|---|---|
| `init [--config F] [--data-dir D]` | 🟢 M0 | Makes D (0700): `tls/` identity, `index.sqlite`, `chunks/`, `tmp/`. Prints the server short id. Refuses if `D/tls` exists (and names the id it holds) |
| `run [--config F] [--data-dir D] [--listen A] --dev-plain` | 🟢 M0 | Plain TCP, loopback only. Prints one stdout line `listening on <ip>:<port>` (port 0 → the real port). Serves Hello, Ping; other requests get `Error INTERNAL "not implemented yet (milestone M1+)"` |
| `run` without `--dev-plain` | ⚪ M3 | Prints "TLS mode arrives in M3; use --dev-plain", exit 2 |
| `pair`, `devices`, `restore`, `scrub-now` | ⚪ later | "not implemented yet", exit 2 |

Settings: `--config F` reads `F` (missing file → defaults); without it the
built-in defaults are used. `--data-dir` and `--listen` override the file.

Exit codes: 0 ok, 1 failure (message on stderr), 2 not implemented yet.

### Dev mode (`--dev-plain`)

| Rule | Why |
|---|---|
| Refuses any listen address that is not loopback | Spec §1: never on a network |
| Every connection is device 1, named `dev` | Spec §1 |
| Device row 1 is real: `name = dev`, `cert_sha256` = 32 zero bytes | Later uploads (M1) need a real `devices` row for their foreign keys. No certificate hashes to all zeros, so a TLS client can never be matched to it |
| Refuses a data folder that has other paired devices | Dev mode must never act as a real phone |
| Hidden test flag `--handshake-timeout-ms N` (dev-plain only) | Lets e2e test the handshake timeout without waiting 10 s |

### Admin socket

`<data_dir>/admin.sock`, mode 0600, removed on stop; a stale file from a
crash is replaced, a live one (another server on the same folder) is
refused. Line protocol: `status` → `ok <n> connections`. Try it with
`socat - UNIX-CONNECT:/tmp/htn-data/admin.sock`. Unix socket paths must stay
under 108 bytes, so keep the data folder path short.
