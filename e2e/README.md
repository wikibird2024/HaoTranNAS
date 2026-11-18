# e2e

End-to-end tests: run the real server and drive it with the cli. No phone needed.

| | |
|---|---|
| Owns | Resume, dedupe, crash-safety and pairing tests; dev-server scripts for client harnesses |
| First milestone | M0 |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run · Test

Run from the repo root (Cargo workspace). The tests start the real
programs from `target/debug/` (or `$CARGO_TARGET_DIR/debug/`), so build them
first.

| Step | Command |
|---|---|
| Build the programs | `cargo build --workspace --bins` |
| Test | `cargo test -p haotrannas-e2e` |
| M0 check (`cli ping` gets `Pong`) | `e2e/scripts/m0_ping.sh` |
| Lint | `cargo clippy -p haotrannas-e2e --all-targets -- -D warnings` |
| Lint scripts | `shellcheck e2e/scripts/*.sh` |

## Helpers (`src/lib.rs`)

| Helper | What it does |
|---|---|
| `DevServer::start()` | `init` on a fresh temp folder, then `run --dev-plain --listen 127.0.0.1:0`; parses the `listening on` line; SIGKILL on drop |
| `DevServer::start_with_args(&[...])` | Same with extra `run` flags, e.g. `--handshake-timeout-ms 300` |
| `DevServer::stop_gracefully(ms)` | SIGTERM, wait for exit |
| `RawClient` | Plain TCP client that sends any bytes or frames and reads frames back (5 s read timeout) |
| `run_cli(&[...])` | Runs `haotrannas-cli` and returns its output |
| `workspace_binary(name)` | Path of a built program; honours `CARGO_TARGET_DIR` |

The raw client uses `haotrannas-core` only to build and read frames; the
server and cli always run as programs.

## Tests (`tests/m0.rs`)

`cli ping` prints Pong · garbage → `MALFORMED_FRAME` (id 0) then end ·
unknown type → `MALFORMED_FRAME` with its id · Hello v2 → `VERSION_MISMATCH` ·
FileOffer / Ping before Hello → `UNEXPECTED_MESSAGE` · not-yet-built request
→ `INTERNAL`, connection stays · handshake timeout → `Close HANDSHAKE_TIMEOUT` ·
two clients at once both get Pong · admin `status` counts connections ·
SIGTERM → `Close SERVER_SHUTDOWN`, clean exit · `--dev-plain` refuses
`0.0.0.0` · `run` without `--dev-plain` exits 2 · `init` twice refused with
the server id · cli without `--dev-plain` exits 2 · cli to a closed port exits 1.

## Scripts

### `scripts/start_dev_server.sh <data-dir>` (for the Dart harness)

Builds the server, runs `init` if `<data-dir>` is new, starts
`run --dev-plain --listen 127.0.0.1:0` in the background and prints exactly
two lines on stdout, then exits 0:

```
NAS_SERVER_ADDR=127.0.0.1:<port>
NAS_SERVER_PID=<pid>
```

| Item | Detail |
|---|---|
| Stop | `kill <pid>` (SIGTERM: clients get `Close SERVER_SHUTDOWN`) |
| Logs | `<data-dir>/dev-server.log` (stderr), `<data-dir>/dev-server.stdout` |
| Build output | stderr only, so stdout stays the two lines |
| Path length | Keep `<data-dir>` short (e.g. `mktemp -d /tmp/htn.XXXXXX`): the admin socket path inside it must stay under 108 bytes |
| Failure | Exit 1 and the server log on stderr if it does not listen within 10 s |
| Server fds | stdin/stdout/stderr go to files, so a caller waiting for the script's stdout to close (Dart `Process.run`) does not hang |

### `scripts/m0_ping.sh`

The M0 "Done when" check: builds, starts a dev server on a temp folder via
`start_dev_server.sh`, runs `haotrannas-cli ping --dev-plain --count 3`,
prints its output, stops the server, exits non-zero without a `Pong`.
