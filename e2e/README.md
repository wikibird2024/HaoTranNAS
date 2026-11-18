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
| M1 check (restored hash = source hash) | `e2e/scripts/m1_upload.sh` |
| Lint | `cargo clippy -p haotrannas-e2e --all-targets -- -D warnings` |
| Lint scripts | `shellcheck e2e/scripts/*.sh` |

## Helpers (`src/lib.rs`)

| Helper | What it does |
|---|---|
| `DevServer::start()` | `init` on a fresh temp folder, then `run --dev-plain --listen 127.0.0.1:0`; parses the `listening on` line; SIGKILL on drop |
| `DevServer::start_with_args(&[...])` | Same with extra `run` flags, e.g. `--handshake-timeout-ms 300` |
| `DevServer::stop_gracefully(ms)` | SIGTERM, wait for exit |
| `RawClient` | Plain TCP client that sends any bytes or frames and reads frames back (5 s read timeout) |
| `DevServer::start_on(dir)` | `init` if needed, then `run` on a folder the test owns (restart after a kill) |
| `DevServer::kill_hard()` | SIGKILL (a crash) and wait |
| `run_cli(&[...])` | Runs `haotrannas-cli` and returns its output |
| `cli_upload(addr, file, &[...])` | `haotrannas-cli --server addr upload file --dev-plain ...` |
| `restore_file(dir, path, out)` / `run_server_command(&[...])` | Runs `haotrannas-server restore` / any server command |
| `expect_success(&output)` | Stdout, or an error with stdout + stderr |
| `test_bytes(size, seed)` | Repeatable pseudo-random file bytes |
| `chunk_files(dir)` / `check_every_chunk_file(dir)` | Files under `chunks/`; every one must hash to its own name |
| `version_count(dir, path)` | Committed versions of (device 1, path), read from the catalog |
| `mark_chunk_bad(dir, hash)` | Marks a chunk bad in the catalog, as scrub will (M6) |
| `wait_until(ms, condition)` | Polls every 20 ms |
| `workspace_binary(name)` | Path of a built program; honours `CARGO_TARGET_DIR` |

The raw client uses `haotrannas-core` only to build and read frames; the
server and cli always run as programs. `rusqlite` reads the catalog for
version counts and marks chunks bad.

## Tests (`tests/m0.rs`)

`cli ping` prints Pong · garbage → `MALFORMED_FRAME` (id 0) then end ·
unknown type → `MALFORMED_FRAME` with its id · Hello v2 → `VERSION_MISMATCH` ·
FileOffer / Ping before Hello → `UNEXPECTED_MESSAGE` · not-yet-built request
→ `INTERNAL`, connection stays · handshake timeout → `Close HANDSHAKE_TIMEOUT` ·
two clients at once both get Pong · admin `status` counts connections ·
SIGTERM → `Close SERVER_SHUTDOWN`, clean exit · `--dev-plain` refuses
`0.0.0.0` · `run` without `--dev-plain` exits 2 · `init` twice refused with
the server id · cli without `--dev-plain` exits 2 · cli to a closed port exits 1.

## Tests (`tests/m1_m2.rs`)

| Test | Proves |
|---|---|
| `upload_then_restore_is_byte_equal` | Sizes 0, 1, 1 MiB, 3 MiB + 17 B upload and restore byte-equal; default path = file name |
| `stopped_upload_resumes_with_only_the_missing_chunks` | `--stop-after-chunks 2` on 5 chunks, then a normal upload sends exactly 3; one file per chunk (no duplicates) |
| `same_content_under_another_path_sends_no_chunks` | Dedupe: 0 chunks sent, number of files under `chunks/` unchanged |
| `lost_commit_ok_is_answered_with_the_existing_version` | `--drop-after-commit`, then `already backed up`; exactly 1 version in the catalog |
| `server_killed_mid_upload_loses_nothing_and_the_upload_resumes` | Raw client: 2 chunks stored, 3rd half sent, SIGKILL; every chunk file hashes to its name; restart; cli sends exactly the 4 missing |
| `server_killed_during_a_cli_upload_then_upload_again_completes` | SIGKILL while the real cli uploads 13 chunks; no version; restart; upload resumes and restore matches |
| `corrupted_chunk_is_healed_by_the_next_upload` | Flip a byte + mark bad: restore refuses, re-offer lists it, upload replaces it, restore matches |
| `wrong_file_hash_gets_file_hash_mismatch_and_the_upload_is_dropped` | `FILE_HASH_MISMATCH`, then `UNKNOWN_UPLOAD`; connection stays |
| `upload_errors_have_their_codes_and_the_connection_stays` | `BAD_PATH`, `BAD_ARGUMENT`, `TOO_LARGE`, `UNKNOWN_UPLOAD`, `CHUNK_HASH_MISMATCH` ×2, `CHUNK_SIZE_WRONG`, `CHUNKS_MISSING`; Ping still works |
| `two_clients_upload_different_files_at_once` | Two cli processes at once both commit; both restore |
| `restore_refuses_to_overwrite_without_force` | Exit 1 and the file untouched; `--force` replaces it; unknown path exits 1 |
| `cli_upload_needs_dev_plain_and_a_readable_file` | Exit 2 without `--dev-plain`, exit 1 for a missing file |

Disk use: up to ~100 MB at once under `$TMPDIR` while the tests run in
parallel. Data folders need a short path (admin socket < 108 bytes).

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

### `scripts/m1_upload.sh`

The M1 "Done when" check: builds, starts a dev server via
`start_dev_server.sh`, uploads a random 3 MiB + 17 B file (`head -c` from
`/dev/urandom`) with `haotrannas-cli upload`, stops the server, restores
offline with `haotrannas-server restore`, then `cmp` and `sha256sum` must
match. Prints `m1_upload: OK`.
