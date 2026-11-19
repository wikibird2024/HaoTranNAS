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
| M3 check (pair, ping, upload over mutual TLS, restore) | `e2e/scripts/m3_pair.sh` |
| M5 check (list and download a tree over TLS, old version) | `e2e/scripts/m5_download.sh` |
| Lint | `cargo clippy -p haotrannas-e2e --all-targets -- -D warnings` |
| Lint scripts | `shellcheck e2e/scripts/*.sh` |

## Helpers (`src/lib.rs`)

| Helper | What it does |
|---|---|
| `DevServer::start()` | `init` on a fresh temp folder, then `run --dev-plain --listen 127.0.0.1:0`; parses the `listening on` line; SIGKILL on drop |
| `DevServer::start_tls()` / `start_tls_with_args(&[...])` / `start_tls_on(dir)` | Same in TLS mode (`run` without `--dev-plain`) |
| `DevServer::pairing_code()` / `pairing_code(dir)` | Runs `haotrannas-server pair` and parses `code … · server id … · valid … s` into `PairingCode` |
| `cli_pair(addr, identity_dir, code, &[...])` | `haotrannas-cli --server addr --identity-dir D pair --code C ...` |
| `cli_paired(identity_dir, Some(addr), &[...])` | Runs the cli with a saved pairing (TLS) |
| `RawClient::connect_tls(addr, pin, identity)` | Raw frames over TLS 1.3 with the cli's settings; no cert = unpaired |
| `load_client_identity(identity_dir)` | Cert + key the cli saved (to present them to another server) |
| `restore_file_of_device(dir, id, path, out)` | `restore --device-id id` |
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
FileOffer / Ping before Hello → `UNEXPECTED_MESSAGE` · a request error
(`ReadFile` of a missing path → `NOT_FOUND`) is not fatal, connection stays · handshake timeout → `Close HANDSHAKE_TIMEOUT` ·
two clients at once both get Pong · admin `status` counts connections ·
SIGTERM → `Close SERVER_SHUTDOWN`, clean exit · `--dev-plain` refuses
`0.0.0.0` · TLS `run` on a missing folder exits 1 · `init` twice refused with
the server id · cli without `--dev-plain` and without a pairing exits 1
("not paired") · cli to a closed port exits 1.

## Tests (`tests/m1_m2.rs`)

| Test | Proves |
|---|---|
| `upload_then_restore_is_byte_equal` | Sizes 0, 1, 1 MiB, 3 MiB + 17 B upload and restore byte-equal; default path = file name |
| `stopped_upload_resumes_with_only_the_missing_chunks` | `--stop-after-chunks 2` on 5 chunks, then a normal upload sends exactly 3; one file per chunk (no duplicates) |
| `same_content_under_another_path_sends_no_chunks` | Dedupe: 0 chunks sent, number of files under `chunks/` unchanged |
| `lost_commit_ok_is_answered_with_the_existing_version` | `--drop-after-commit`, then `already backed up`; exactly 1 version in the catalog |
| `server_killed_mid_upload_loses_nothing_and_the_upload_resumes` | Raw client: 2 chunks stored, 3rd half sent, SIGKILL; every chunk file hashes to its name; restart; cli sends exactly the 4 missing |
| `server_killed_during_a_cli_upload_then_upload_again_completes` | SIGKILL while the real cli uploads 13 chunks; no version; restart; upload resumes and restore matches |
| `corrupted_chunk_is_healed_by_the_next_upload` | Flip a byte + mark bad: restore refuses, re-offer lists it, upload replaces it, commit answers the healed version 1 (D-029, no duplicate), restore matches |
| `wrong_file_hash_gets_file_hash_mismatch_and_the_upload_is_dropped` | `FILE_HASH_MISMATCH`, then `UNKNOWN_UPLOAD`; connection stays |
| `upload_errors_have_their_codes_and_the_connection_stays` | `BAD_PATH`, `BAD_ARGUMENT`, `TOO_LARGE`, `UNKNOWN_UPLOAD`, `CHUNK_HASH_MISMATCH` ×2, `CHUNK_SIZE_WRONG`, `CHUNKS_MISSING`; Ping still works |
| `two_clients_upload_different_files_at_once` | Two cli processes at once both commit; both restore |
| `restore_refuses_to_overwrite_without_force` | Exit 1 and the file untouched; `--force` replaces it; unknown path exits 1 |
| `cli_upload_needs_a_pairing_or_dev_plain_and_a_readable_file` | Exit 1 "not paired" without `--dev-plain` (empty identity folder), exit 1 for a missing file |

## Tests (`tests/m3.rs`)

| Test | Proves |
|---|---|
| `unpaired_tls_client_can_ping_but_not_offer_a_file` | TLS without a cert: `HelloOk device_id 0`, Ping works, FileOffer → `NOT_PAIRED` and the end |
| `paired_cli_pings_uploads_and_restores_over_mutual_tls` | `pair --expect-server-id`, key file 0600, ping shows the device id, 3-chunk upload, restore byte-equal; the key is not in the server log |
| `third_wrong_code_closes_the_connection` | `BAD_PAIRING_CODE` ×3, then the end; the window still works |
| `ten_wrong_codes_across_connections_lock_the_window` | 3+3+3+1 wrong codes, then even the right code → `TOO_MANY_ATTEMPTS` (fatal); a new `pair` works |
| `pairing_code_is_single_use` | Second pair with the same code → `PAIRING_NOT_OPEN`, nothing saved |
| `expired_code_is_not_open` | `--pairing-code-ttl-ms 300`, wait → `PAIRING_NOT_OPEN` |
| `wrong_expected_server_id_saves_nothing` | `--expect-server-id` mismatch → exit 1, no `server.json` |
| `certificate_from_another_server_is_refused_and_the_pin_is_checked` | Another server's device cert → no HelloOk (first read fails); cli pinned to B, sent to A → `server identity changed (expected B, got A)` |
| `revoked_device_is_refused_but_its_backups_restore` | `devices` lists it, `devices --revoke`, cli → "not paired (or was revoked)", listing shows `revoked`, restore still byte-equal |
| `tls_run_refuses_a_data_folder_with_the_dev_device` | D-026 |
| `admin_pair_needs_tls_mode` | `pair` on a dev-plain server → exit 1 |
| `identical_uploads_racing_commit_to_one_version` | D-029: two uploads offered before either commit → same version id, 1 version |

## Tests (`tests/m5.rs`)

TLS server, paired cli; a raw TLS client with the cli's certificate checks
exact replies.

| Test | Proves |
|---|---|
| `tree_lists_exactly_as_the_spec_says_and_every_file_downloads_byte_equal` | Tree with folders, a 0-byte file, 3 MiB + 17 B, Vietnamese names, folder `2024` next to `2024.txt`: `cli list` of root and folders (order, kinds, columns); `ListDevices` (is_caller); `ListDir` paging 2 per page (`has_more`, folder entries 0/0/0); `BAD_ARGUMENT` (0, 1001), `BAD_PATH`, `NOT_FOUND` (device, folder, a file as folder), connection stays; every file downloads byte-equal; unknown path → `NOT_FOUND`, nothing written; existing output needs `--force`; no temp file left |
| `old_version_downloads_by_its_version_id` | Re-upload a changed file: `list` shows the new version; `--version <old id>` gives the old bytes; unknown version → `NOT_FOUND` |
| `new_phone_lists_and_downloads_the_old_phones_files_even_after_revoke` | Second cli identity: `ListDevices` shows both, `list --device`, `download --device` byte-equal; after `devices --revoke` the old phone is hidden from `ListDevices` but its files still download (D-025) |
| `corrupt_chunk_fails_the_download_with_not_found_and_is_marked_bad` | One flipped byte in chunk 1 on disk → download exit 1 with `NOT_FOUND` at chunk 1, no output, no temp file; catalog status `bad`; the next upload repairs it and download works |
| `chunk_only_in_an_uncommitted_upload_is_not_found` | `upload --stop-after-chunks 1`: the stored chunk (status ok) → `ReadChunk` `NOT_FOUND`; unknown hash → `NOT_FOUND`; root listing empty |

Disk use: up to ~100 MB at once under `$TMPDIR` while the tests run in
parallel. Data folders need a short path (admin socket < 108 bytes).

## Scripts

### `scripts/start_dev_server.sh [--tls] <data-dir>` (for the Dart harness)

Builds the server, runs `init` if `<data-dir>` is new, starts
`run --dev-plain --listen 127.0.0.1:0` (with `--tls`: `run --listen
127.0.0.1:0`, TLS mode) in the background and prints exactly two lines on
stdout, then exits 0:

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

### `scripts/m3_pair.sh`

The M3 pairing check: builds, `init` + TLS `run` via `start_dev_server.sh
--tls`, `haotrannas-server pair`, `haotrannas-cli pair --expect-server-id`,
`ping`, `upload` (2 MiB + 5 B), stops the server, restores offline with
`--device-id`, `cmp`. Prints `m3_pair: OK`.

### `scripts/m5_download.sh`

The M5 browse and download check: builds, TLS `run`, pairs the cli, uploads
a tree (a folder, a 0-byte file, 3 MiB + 17 B, a Vietnamese name), checks
`list` of the root and `photos`, downloads every file and `cmp`s it, then
uploads a changed `top.txt` and downloads the old version by id. Prints
`m5_download: OK`.

### `scripts/flutter_vs_server.sh`

Starts a dev-plain server and a TLS server on two temp folders and runs
`flutter test --tags server` (in `mobile/`) with `NAS_SERVER_ADDR`,
`NAS_DATA_DIR` (dev-plain, unchanged), `NAS_TLS_SERVER_ADDR`,
`NAS_TLS_DATA_DIR` (TLS) and `NAS_SERVER_BIN`. The Dart tests get pairing
codes with `$NAS_SERVER_BIN pair --data-dir $NAS_TLS_DATA_DIR`. Both servers
are stopped and both folders removed on exit.
