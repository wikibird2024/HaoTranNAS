# mobile — HaoTranNAS phone app

Author: Hao Tran

## What

Flutter Android app that backs up the phone's photos and files to the
HaoTranNAS server, and lets me browse and download them. Design:
[docs/architecture.md](../docs/architecture.md) §6.

```
 lib/
   protocol/   bytes ⇄ frames ⇄ messages   pure, no I/O, never throws on bad bytes
   core/       Link (TCP, TLS, mDNS socket), hex, session log
   discovery/  find the server (mDNS, else last known address)
   client/     connection, chunker, upload, download, pairing
   backup/     photo scan, local state (SQLite), background job
   ui/         screens: glue only, never parse bytes
```

Rules kept from Protocol Lab: codec = pure (no I/O), Link = I/O, screens =
glue; decoders never throw on bad bytes; byte formats are hand-written;
check a package's license before adding it.

Status: `lib/protocol/`, `lib/core/` and in `lib/client/` the connection,
chunker, upload engine, TLS link, identity store, pairing and address book
are real; the other files are documented skeletons.

## Upload (spec §8)

```
 UploadEngine.upload(localPath, remotePath, modifiedTimeMs)
   path rules ─► chunkFile (isolate, 1 MiB reads) ─► FileOffer
   NeedChunks: existing version → alreadyBackedUp (nothing sent)
               else each missing chunk: read + re-hash ─► ChunkData ─► ChunkOk
   Commit ─► CommitOk → uploaded      CHUNKS_MISSING → offer again (max 3)
```

| Result | Meaning |
|---|---|
| `UploadUploaded` | Committed; `chunksSent` = what this call sent |
| `UploadAlreadyBackedUp` | Same path, size, time and content already on the server |
| `UploadCancelled` | `UploadCancel.cancel()` between chunks; not committed |
| `UploadFailed(kind)` | `badPath`, `tooLarge`, `diskFull`, `fileChangedDuringUpload`, `fileUnreadable`, `chunksStillMissing`, `badReply`, `serverRejected`, `connectionLost`; not committed |

`upload()` never throws for file, server or network problems. Resume = call
`upload()` again: the server only asks for the chunks it lacks. A chunk
whose bytes no longer match the offered hash stops the upload before it is
sent (no Commit).

## TLS, pairing and identity (spec §1, §6, §7)

```
 pairing (once, on the home Wi-Fi)
   TlsLink: no client cert, trust on first use ─► fingerprint seen
   Hello ─► HelloOk(device 0) ─► show short id 3F9A-C21B-77E0
   PairRequest(code) ─► PairOk: server_cert_sha256 == fingerprint seen?
   ─► IdentityStore.save ─► server sends Close(PAIRED_RECONNECT)

 every later connection
   AddressBook.connectPaired: mDNS (fp= matches) ─► last LAN ─► WireGuard
   TlsLink: fixed pin + client cert ─► Hello ─► HelloOk(our device id)
   closed before HelloOk / NOT_PAIRED ─► "maybe not paired", stop
```

| Piece | File | Notes |
|---|---|---|
| `TlsLink.connect(ip, port, pin:, clientCertificate:)` | `lib/core/transport/tls_link.dart` | TLS 1.3 only, no public roots; pin = SHA-256 of server cert DER, checked in `onBadCertificate` and again on `peerCertificate`. Throws `TlsPinMismatch` or `TlsConnectFailure(unreachable, timeout, handshakeFailed, badClientCertificate)` |
| `pairWithServer(...)`, `PairingSession` | `lib/client/pairing.dart` | Never throws; `PairingFailed(kind, message, attemptsLeft)` with plain-English messages. A session takes up to 3 codes on one connection |
| `DeviceIdentity`, `IdentityStore`, `shortId` | `lib/client/identity.dart` | `toString` prints `<key redacted>` |
| `AddressBook.connectPaired` | `lib/client/address_book.dart` | Saves a LAN address that worked |

Identity files (D-022: app-private files, not secure storage), in
`getApplicationSupportDirectory()/identity/`, each written to `.tmp`,
flushed, renamed; `server.json` last:

| File | Holds |
|---|---|
| `device_cert.der` | Device certificate from PairOk |
| `device_key.pk8` | Device key, PKCS#8 DER. Secret, never logged |
| `server.json` | Device id, both fingerprints (hex), last LAN and WireGuard address |

dart:io facts checked on this PC (`test/core/tls_link_test.dart`):

| Fact | Meaning |
|---|---|
| 🟢 PKCS#8 DER wrapped as `PRIVATE KEY` PEM loads as a client key | No key conversion on the phone |
| 🟢 A rejected client cert: connect succeeds, first read fails (`Connection reset by peer`) | Spec §6 note holds; `NasConnection` reports `closedBeforeHello` |
| 🟡 dart:io sends the IP literal as SNI (RFC 6066 says it must not) | rustls 0.23 ignores an IP SNI (with a warning in its log) |
| 🟡 `SecureSocket.connect(timeout:)` covers only TCP connect | `TlsLink` adds its own deadline over the handshake |

## Build

APKs are built only in GitHub CI (`.github/workflows/mobile.yml`), not on
the dev machine. Each CI run uploads the artifact `haotrannas-mobile-apk`.
versionCode = CI run number.

Release signing uses the repo secrets `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
Without them the APK is signed with a throwaway debug key and CI shows a
warning (that APK will not install over an earlier one).

## Run

```bash
export PUB_CACHE=/mnt/storage/HaoTran/sdk/pub-cache
export PATH=/mnt/storage/HaoTran/sdk/flutter/bin:$PATH
cd mobile
flutter pub get
flutter run            # phone connected over USB, debug build
```

## Test

```bash
export PUB_CACHE=/mnt/storage/HaoTran/sdk/pub-cache
export PATH=/mnt/storage/HaoTran/sdk/flutter/bin:$PATH
cd mobile
flutter analyze
flutter test                                   # everything
flutter test --exclude-tags server,mdns        # what CI runs
flutter test --tags server                     # needs a running haotrannas-server
flutter test --tags mdns                       # needs a real LAN with multicast
```

| Tests | What they check | Needs |
|---|---|---|
| `test/protocol/` | Codec against the golden vectors, fuzz | nothing |
| `test/client/nas_connection_test.dart` | Handshake, request ids, queue, timeouts, keepalive, failures, log redaction; a scripted fake server on `FakeLink` (`test/client/fake_server.dart`) | nothing |
| `test/client/chunker_test.dart` | Chunk hashes, file SHA-256 and `readChunk` against `protocol/vectors/chunking.json`; size helpers | nothing |
| `test/client/upload_engine_test.dart` | Upload flow on a fake server with a chunk store (`fake_upload_server.dart`): order, dedup, already backed up, resume, cancel, re-offer, file changed, bad replies, typed errors, progress | nothing |
| `test/core/tls_link_test.dart` | PEM wrap, pin logic; real TLS 1.3 on loopback with openssl-made certs: right pin, wrong pin, TOFU, client cert reaches the server, rejected client cert, SNI, unreachable, timeout, not TLS | `openssl` (else that group is skipped) |
| `test/client/identity_test.dart` | Short id (spec example), fp prefix, key never printed, store round trip, file layout, damaged files | nothing |
| `test/client/pairing_test.dart` | Pairing over a fake TLS connector: success, MITM check, short id, code format, error mapping, attempts left, connection problems | nothing |
| `test/client/address_book_test.dart` | Candidate order, fallback, pin mismatch → next, maybe-not-paired stops, LAN address saved | nothing |
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

## Phone-only checks (manual)

These cannot run in CI or on the dev machine; do them on a real phone.

| Check | How | Pass when |
|---|---|---|
| ⚪ Photo access with GPS kept | Back up a photo taken with location on | Server copy has the same bytes and EXIF GPS as the original |
| ⚪ Background backup | Lock the phone on Wi-Fi with new photos | WorkManager job runs and commits them without opening the app |
| ⚪ mDNS discovery on Wi-Fi | Open pairing on the same Wi-Fi as the server | Server is found (multicast lock held), not only by typed address |
| ⚪ Pairing on Wi-Fi | Pair with the code from `haotrannas-server pair` | Short id on the phone = the one the server printed; reconnect works |
| ⚪ SHA-256 speed | Hash a large video on the phone | Speed in MB/s is noted; backup is not blocked by hashing |

## Packages

Licenses checked 2026-11-18. All permissive.

| Package | Version | License | Used for |
|---|---|---|---|
| crypto | 3.0.8 | BSD-3 | SHA-256 of chunks |
| path_provider | 2.1.6 | BSD-3 | App folders |
| sqflite | 2.4.6 | BSD-2 | Local backup state |
| photo_manager | 3.12.0 | Apache-2.0 | Photo and video list (pulls in Glide, BSD/MIT/Apache) |
| workmanager | 0.10.10 | MIT | Background backup |
| flutter_riverpod | 3.5.0 | MIT | App state |
| collection | 1.19.1 | BSD-3 | List and map helpers |
| fake_async (dev) | 1.3.3 | Apache-2.0 | Timer tests |
| sqflite_common_ffi (dev) | 2.4.7 | BSD-2 | SQLite in host tests |
| flutter_lints (dev) | 6.0.0 | BSD-3 | Lints |
