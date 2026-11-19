# dart_client — shared Dart client logic

Author: Hao Tran

The HaoTranNAS client in Dart, used by the phone app (`mobile/`) and the PC
app (`desktop/`) through a path dependency (decision D-040). It has no UI
and no Android- or desktop-only plugin code (Riverpod state is shared;
widgets are not).

```
 lib/
   protocol/   bytes ⇄ frames ⇄ messages      pure, no I/O, never throws on bad bytes
   core/       Link (TCP, TLS, mDNS socket), hex, session log
   discovery/  find the server (mDNS)
   client/     connection, chunker, upload, download, pairing, identity, address book
   backup/     runner, SQLite state store, controller, MediaSource interface,
               BackupStatusSource types (what the screens see)
   app/        Riverpod state both apps share: identity, connection, pairing, backup source
   text/       numbers, sizes, dates and backup summaries as text for the screens
   testing/    fakes for the apps' tests (fake servers, fake media, test certs)
```

| Rule | Why |
|---|---|
| Codec = pure, Link = I/O (from Protocol Lab) | Tests run on bytes and a `FakeLink` |
| An app gives its platform parts: a `MediaSource` (phone: photo_manager, PC: folders), a sqflite `DatabaseFactory` (phone: plugin, PC: ffi) | One runner for both apps |
| `testing/` holds only fakes; nothing in `lib/` outside it imports them | Test code stays out of the apps |

## Build · Test

```bash
export PUB_CACHE=/mnt/storage/HaoTran/sdk/pub-cache
export PATH=/mnt/storage/HaoTran/sdk/flutter/bin:$PATH
cd dart_client
flutter pub get
flutter analyze
flutter test --exclude-tags server,mdns        # what CI runs
flutter test --tags server                     # needs a running haotrannas-server
flutter test --tags mdns                       # needs a real LAN with multicast
TMPDIR=/tmp ../e2e/scripts/flutter_vs_server.sh   # builds and starts the servers, runs the server tests
```

| Tests | What they check | Needs |
|---|---|---|
| `test/protocol/` | Codec against the golden vectors, fuzz | nothing |
| `test/client/nas_connection_test.dart` | Handshake, request ids, queue, timeouts, keepalive, failures, log redaction; a scripted fake server on `FakeLink` (`lib/testing/fake_server.dart`) | nothing |
| `test/client/chunker_test.dart` | Chunk hashes, file SHA-256 and `readChunk` against `protocol/vectors/chunking.json`; size helpers | nothing |
| `test/client/upload_engine_test.dart` | Upload flow on a fake server with a chunk store (`fake_upload_server.dart`): order, dedup, already backed up, resume, cancel, re-offer, file changed, bad replies, typed errors, progress | nothing |
| `test/core/tls_link_test.dart` | PEM wrap, pin logic; real TLS 1.3 on loopback with openssl-made certs: right pin, wrong pin, TOFU, client cert reaches the server, rejected client cert, SNI, unreachable, timeout, not TLS | `openssl` (else that group is skipped) |
| `test/client/identity_test.dart` | Short id (spec example), fp prefix, key never printed, store round trip, file layout, damaged files | nothing |
| `test/client/pairing_test.dart` | Pairing over a fake TLS connector: success, MITM check, short id, code format, error mapping, attempts left, connection problems | nothing |
| `test/client/address_book_test.dart` | Candidate order, fallback, pin mismatch → next, maybe-not-paired stops, LAN address saved | nothing |
| `test/client/download_engine_test.dart` | Download on a fake server (`fake_download_server.dart`): listing with paging, full download, chunk/file hash and size checks, cancel, NOT_FOUND, connection lost, never overwriting, restore under a free name | nothing |
| `test/backup/media_source_test.dart` | `mediaRemotePath`: Android paths, storage root, `\`, control characters, dots, long names keep their extension, too many parts, fallback; deterministic | nothing |
| `test/backup/backup_state_store_test.dart` | Same contract for the memory and the SQLite store (ffi, system libsqlite3): CRUD, every column, values, run lock, reopen, schema | `libsqlite3` |
| `test/backup/backup_runner_test.dart` | Runner on `FakeUploadServer` + temp-file library (`lib/testing/backup_fakes.dart`): first run all newest first, second run nothing, changed file, moved album, budget between files and inside a file then resume, cancel, per-item errors, connection lost, server offline, no access; verify: all fine, heals a lost chunk, CHUNKS_MISSING, deleted/changed skipped, order, budget | nothing |
| `test/backup/backup_controller_test.dart` | Controller + `BackupStatusSource` adapter: notifications, activity, summaries saved and read back, busy (here or in background), stop, settings saved + rescheduled, schedule failure logged | nothing |
| `test/integration/server_download_test.dart` (tag `server`) | Real server in TLS mode: pair, upload a small tree, list with paging, download every file and compare bytes | `NAS_TLS_SERVER_ADDR`, `NAS_TLS_DATA_DIR`, `NAS_SERVER_BIN`; skipped otherwise |
| `test/integration/server_tls_test.dart` (tag `server`) | Real server in TLS mode: wrong code, pair → mTLS reconnect → ping → upload → already backed up, wrong pin, no cert → NOT_PAIRED, unknown cert refused | `NAS_TLS_SERVER_ADDR`, `NAS_TLS_DATA_DIR`, `NAS_SERVER_BIN`; skipped otherwise |
| `test/integration/server_ping_test.dart` (tag `server`) | Hello → HelloOk(device 1) → 3 pings → Close over real TCP | a dev server; skipped when `NAS_SERVER_ADDR` is not set |
| `test/integration/server_upload_test.dart` (tag `server`) | 3 MiB + 17 B upload, re-upload = already backed up, resume after cancel sends 3 of 5 chunks, same content at a new path sends 0; `haotrannas-server restore` gives the same bytes | a dev server (`NAS_SERVER_ADDR`); the restore check also needs `NAS_SERVER_BIN` and `NAS_DATA_DIR` |

Against a real server (dev mode, plain TCP on 127.0.0.1):

```bash
NAS_SERVER_ADDR=127.0.0.1:47100 flutter test --tags server
# plus the restore check (server binary and its --data-dir):
NAS_SERVER_ADDR=127.0.0.1:47100 NAS_SERVER_BIN=../target/debug/haotrannas-server \
  NAS_DATA_DIR=/tmp/htn-dev flutter test --tags server
```

Against a real server in TLS mode (`e2e/scripts/flutter_vs_server.sh`
sets these; the server must allow pairing from 127.0.0.1):

```bash
NAS_TLS_SERVER_ADDR=127.0.0.1:47101 NAS_TLS_DATA_DIR=/tmp/htn-tls \
  NAS_SERVER_BIN=../target/debug/haotrannas-server \
  flutter test --tags server test/integration/server_tls_test.dart
```
