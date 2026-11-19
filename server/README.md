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
| Run (TLS, M3) | `cargo run -p haotrannas-server -- run --data-dir /tmp/htn-data --listen 0.0.0.0:47100` |
| Pairing code | `cargo run -p haotrannas-server -- pair --data-dir /tmp/htn-data` (server must be running) |
| Run (dev, M0–M2) | `cargo run -p haotrannas-server -- run --dev-plain --data-dir /tmp/htn-data --listen 127.0.0.1:47100` |
| Help | `cargo run -p haotrannas-server -- --help` |
| Test | `cargo test -p haotrannas-server` |
| Lint | `cargo clippy -p haotrannas-server --all-targets -- -D warnings` |

Logs go to stderr (default filter `info,rustls=error`; set it with
`RUST_LOG`, for example `RUST_LOG=debug`). `rustls=error` hides one rustls
warning per connection from clients that send an IP literal as SNI (dart:io
does: "Illegal SNI extension: ignoring IP address"). rustls ignores that
name and so does the pin check; TLS behaviour is unchanged. Stop with Ctrl-C or SIGTERM: open connections get
`Close SERVER_SHUTDOWN`, then the server waits up to 2 s for them.

## Commands

| Command | Status | What it does |
|---|---|---|
| `init [--config F] [--data-dir D]` | 🟢 M0 | Makes D (0700): `tls/` identity, `index.sqlite`, `chunks/`, `tmp/`. Prints the server short id. Refuses if `D/tls` exists (and names the id it holds) |
| `run [--config F] [--data-dir D] [--listen A]` | 🟢 M3 | TLS 1.3, mutual TLS (see "TLS mode" below). Prints one stdout line `listening on <ip>:<port>` (port 0 → the real port). Serves Hello, Ping, PairRequest, the upload requests and (M5) browse and download |
| `run ... --dev-plain` | 🟢 M0, M1/M2 | Plain TCP, loopback only, every connection is device 1 (see "Dev mode") |
| `pair [--config F] [--data-dir D]` | 🟢 M3 | Asks the running server (admin socket) for a pairing code; prints one line and exits: `code 482913 · server id 3F9A-C21B-77E0 · valid 120 s`. Exit 1 if no server runs or it is in dev mode |
| `devices [--config F] [--data-dir D] [--revoke N]` | 🟢 M3 | Lists devices, one line each: `<id> <name> paired <ms> [revoked <ms>]` (`no paired devices` when empty). `--revoke N`: device N's certificate is refused from now on; its backups stay restorable (D-025). Prints `revoked device N; its backups stay restorable` |
| `restore [--config F] [--data-dir D] [--device-id N] --path P [--version-id V] --output F [--force]` | 🟢 M1 | Offline (no running server needed; safe next to one). Device 1 and the latest version by default. Re-hashes every chunk and the whole file, writes a temp file next to F, fsyncs, then renames. Prints `restored <path> version <id> (<size> bytes, sha256 <hex>)`. Refuses to overwrite F without `--force`; a damaged or missing chunk → exit 1, no file left behind |
| `scrub-now [--config F] [--data-dir D]` | 🟢 M6 | Asks the running server to re-hash every chunk now. `scrub: <n> chunks checked` on stderr after each 256 chunks, then one stdout line `scrub chunks_checked N bytes_checked N bad_found N missing N repaired N started_at_ms N duration_ms N`. Exit 1 if no server runs or a scrub is already running |
| `scrub-report [--config F] [--data-dir D]` | 🟢 M6 | The last finished scrub, same line (from `D/scrub-report.json`). Exit 1 before the first scrub |
| `cleanup-now [--config F] [--data-dir D]` | 🟢 M6 | Runs cleanup now, orphan pass included: `cleanup expired_uploads N tmp_files N unused_chunks N orphan_files N orphan_pass yes duration_ms N` |

Settings: `--config F` reads `F` (missing file → defaults); without it the
built-in defaults are used. `--data-dir` and `--listen` override the file.

Exit codes: 0 ok, 1 failure (message on stderr). `scrub-now` exits 0 even
when it finds damage: read `bad_found` / `missing` (nas/RUNBOOK.md).

No offline scrub or cleanup: only the running server writes the catalog
(one writer, D-020), so start the server first. `restore` stays offline
because it only reads.

### TLS mode (`run` without `--dev-plain`)

| Rule | Detail |
|---|---|
| Needs `init` first | Loads `D/tls/` (server leaf + device CA); refuses an uninitialized folder |
| Refuses dev data (D-026) | A folder that has the dev device row (used with `--dev-plain`) is refused with a clear message: dev uploads never go on a network |
| Handshake | Inside the connection task, within `HANDSHAKE_TIMEOUT_MS` (10 s) of accept; the same 10 s also covers `Hello` |
| Client cert | None → `HelloOk device_id 0` (Unpaired: Ping, PairRequest, Close). Signed by our device CA and in `devices`, not revoked → that device (Ready). Signed by our CA but unknown or revoked → `Error NOT_PAIRED` (fatal) after `Hello`. From another CA → handshake fails; the client sees it on its first read |
| Catalog lookup fails | Connection dropped without a reply (a paired client must not be told NOT_PAIRED by a disk hiccup) |
| Revoke timing | A revoked device's open connection is not cut; its next connection gets `NOT_PAIRED` |

### Pairing (spec §7, `src/pairing.rs`, `src/handlers/pair.rs`)

Checks in spec order: source IP in `pairing_networks` or loopback (D-028)
else `PAIRING_NOT_ALLOWED_FROM_NETWORK` (fatal) · window open else
`PAIRING_NOT_OPEN` (not fatal) · window locked else `TOO_MANY_ATTEMPTS`
(fatal) · code (constant-time compare) else `BAD_PAIRING_CODE` (fatal on the
3rd in one connection). Success: device row + certificate (CN
`device-<id>`) in one catalog transaction, name = the `Hello` `device_name`,
`PairOk`, then `Close PAIRED_RECONNECT`. The key is never logged; the code is
shown only on the admin socket.

| Window rule | Value |
|---|---|
| Code | 6 digits from the thread CSPRNG, single use, `PAIRING_CODE_TTL_MS` (120 s) |
| New `pair` | Replaces the open window (new code, failure count 0) |
| 10 wrong codes in a window | Locked: every try gets `TOO_MANY_ATTEMPTS` until the window would have expired, or until the admin runs `pair` again |
| Hidden test flag `--pairing-code-ttl-ms N` (TLS only) | Short code lifetime for the e2e "expired code" test |
| Hidden test flag `--handshake-timeout-ms N` | Both modes now |
| A code accepted but the catalog write fails | `Error INTERNAL` (not fatal); the code is used up, run `pair` again |

### Dev mode (`--dev-plain`)

| Rule | Why |
|---|---|
| Refuses any listen address that is not loopback | Spec §1: never on a network |
| Every connection is device 1, named `dev` | Spec §1 |
| Device row 1 is real: `name = dev`, `cert_sha256` = 32 zero bytes | Uploads need a real `devices` row for their foreign keys. No certificate hashes to all zeros, so a TLS client can never be matched to it |
| Refuses a data folder that has other paired devices | Dev mode must never act as a real phone |
| Hidden test flag `--handshake-timeout-ms N` | Lets e2e test the handshake timeout without waiting 10 s |
| No pairing | `pair` on the admin socket answers `error pairing needs TLS mode` |

### Upload (spec §8, `src/handlers/upload.rs`)

Every check of the spec table, in its order, with its error code. Upload
errors are not fatal: the connection stays open.

| Request | Checks, in order → error | Then |
|---|---|---|
| FileOffer | path rules → `BAD_PATH` · more than 65 536 chunks (list or size) → `TOO_LARGE` · list ≠ `ceil(size / 1 MiB)` → `BAD_ARGUMENT` | catalog: existing version (same size, time, hash, no bad chunk) or new upload + missing indexes |
| ChunkData | upload of this device → `UNKNOWN_UPLOAD` · index < count → `BAD_ARGUMENT` · hash = offered → `CHUNK_HASH_MISMATCH` · size → `CHUNK_SIZE_WRONG` · SHA-256(data) → `CHUNK_HASH_MISMATCH` | stored+ok: `ChunkOk`, no write · bad: atomic replace · else atomic put (a file left by a crash is re-hashed first) · then mark ok · `DISK_FULL` / `INTERNAL` |
| Commit | upload of this device → `UNKNOWN_UPLOAD` · every chunk stored+ok → `CHUNKS_MISSING` · one streaming pass re-hashes each chunk (a damaged one is marked bad → `CHUNKS_MISSING`) and the whole file → `FILE_HASH_MISMATCH` (upload dropped) | one catalog transaction → `CommitOk`. If the latest version is the same file (size, time, hash, all chunks ok) the upload is dropped and that version's id is returned: no duplicate (D-029) |

Hashing and chunk files run in `spawn_blocking`. Idle time counts from the
last reply, so a long Commit is not idle time.

### Browse and download (spec §9, `src/handlers/{browse,download}.rs`)

Ready only (paired, or dev mode). Errors are not fatal. `device_id 0` = the
caller; another id must be a device row, revoked ones included (D-025:
their backups stay restorable), else `NOT_FOUND`.

| Request | Checks, in order → error | Reply |
|---|---|---|
| ListDevices | — | `DeviceList`: devices not revoked, by id; `is_caller` marks the asker |
| ListDir | `max_entries` 1..=1000 → `BAD_ARGUMENT` · device → `NOT_FOUND` · path "" = root, else path rules → `BAD_PATH` · non-root folder with no children → `NOT_FOUND` | `DirEntries`: direct children of the latest version of each file, byte-wise by name, names `> start_after`, `has_more`; folders (size 0, mtime 0, version 0) win over a file of the same name |
| ReadFile | device → `NOT_FOUND` · path rules → `BAD_PATH` · path / version (0 = latest) → `NOT_FOUND` | `FileManifest` |
| ReadChunk | stored with status ok and used by a committed version → else `NOT_FOUND` | re-hash on the blocking pool: intact → `ChunkContent`; damaged or missing → marked bad (writer) → `NOT_FOUND`. Bad bytes never leave |

How `ListDir` stays fast with 100k files in one folder
(`catalog/reader.rs`, `FolderListing`): no folder table; it seeks in the
existing `UNIQUE (device_id, path)` index of `files`. A folder `p` is the
path range `["p/", "p0")` (`'0'` is the byte after `/`). The next child after
name `A` is the first committed path in `(p/A, p/A/)`, else the first one
`>= p/A0`, which jumps over A's whole subtree in one seek. Path order and
name order differ only around bytes below `/` (`-`, `.`, space): folder `D`
sorts after `D.txt` in path order, so shorter names are tried as folders
(and a folder seen after `A` is skipped). Each entry costs about four
`ORDER BY path LIMIT 1` seeks, whatever the folder size: a 1000-entry page of
a 20 000-file folder takes ~140 ms in a debug build (test
`list_directory_stays_fast_with_20k_files_in_one_folder`); a brute-force
model test covers the ordering corner cases.

### Background jobs (`src/jobs/`)

Both start after the listener is bound, in TLS and dev-plain mode, and
wait one full interval before their first run (a restart does not start a
week-long scrub). On SIGTERM they stop; a running scrub stops at its next
page of 256 chunks and saves no report. One scrub and one cleanup at a time.

| Job | When | What |
|---|---|---|
| Scrub | every `scrub_interval_hours` (168), or `scrub-now` | Walks `chunks` in hash order, 256 rows a page. Re-hashes each file (`spawn_blocking`), at most 64 MiB/s (no catch-up bursts). Damaged (or EIO) → marked bad, `bad_found`; no file → marked bad, `missing`; marked bad but intact now (ZFS repair, re-upload) → marked ok, `repaired`. Saves `D/scrub-report.json` (temp file, fsync, rename) and logs it (warning when `bad_found` or `missing` > 0) |
| Cleanup | every `cleanup_interval_minutes` (60), or `cleanup-now` | 1 uploads older than `upload_expiry_hours` (24). 2 `tmp/` files older than 1 h. 3 unused chunks (no `version_chunks`, no `upload_chunks` row) created more than 24 h ago: rows deleted, commit, then files deleted, all in ONE writer job per 500 (D-020). 4 orphan pass, at most daily: chunk files older than 24 h with no `chunks` row (a crash between step 3's commit and its file delete), re-checked inside the writer |

Why cleanup cannot race an upload: a `FileOffer` is a writer job too. If it
runs first, its `upload_chunks` rows keep the chunk; if it runs after, the
chunk has no row, so it is listed missing and the client sends it again.
`ReadChunk` of a deleted chunk answers `NOT_FOUND`.

| Hidden test flag on `run` | Effect |
|---|---|
| `--upload-expiry-ms N` | Uploads expire after N ms instead of `upload_expiry_hours` |
| `--unused-chunk-grace-ms N` | Unused chunks and orphan files are deleted after N ms instead of 24 h |

### Admin socket

`<data_dir>/admin.sock`, mode 0600, removed on stop; a stale file from a
crash is replaced, a live one (another server on the same folder) is
refused. Unix socket paths must stay under 108 bytes, so keep the data
folder path short. Try it with `socat - UNIX-CONNECT:/tmp/htn-data/admin.sock`.

Line protocol: one command per line. Every reply is one line, except
`devices` and `scrub-now`. Failures are `error <text>`.

| Command | Reply |
|---|---|
| `status` | `ok <n> connections` |
| `pair` | `code <6 digits> server-id <XXXX-XXXX-XXXX> valid <s> s` (TLS mode only) |
| `devices` | `<id> <name> paired <ms> [revoked <ms>]` per device (control characters in names shown as `?`), then `ok <n> devices` |
| `revoke <id>` | `ok revoked device <id>` · `error no device <id>` · `error device <id> was already revoked at <ms>` |
| `scrub-now` | `progress <chunks checked>` after each page of 256, then `ok scrub <summary>` · `error scrub: a scrub is already running`. A big store takes hours (64 MiB/s); a client that hangs up does not stop the scrub |
| `scrub-report` | `ok scrub <summary>` of the last finished scrub · `error no scrub has finished yet (run scrub-now)` |
| `cleanup-now` | `ok cleanup <summary>` · `error cleanup: a cleanup is already running` |

The `pair` / `devices` subcommands send one command, half-close, and read
the reply to the end.

### Catalog schema

Version 2 adds `devices.revoked_at_ms INTEGER NULL` (D-025): a revoked
device keeps its row and its backups; `device_by_cert` skips it. A version-1
file is migrated on open.
