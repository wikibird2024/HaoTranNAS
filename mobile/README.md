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

Status: scaffold. `lib/protocol/limits.dart` and `lib/core/` are real; the
other files are documented skeletons.

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
| `test/integration/server_ping_test.dart` (tag `server`) | Hello → HelloOk(device 1) → 3 pings → Close over real TCP | a dev server; skipped when `NAS_SERVER_ADDR` is not set |

Against a real server (dev mode, plain TCP on 127.0.0.1):

```bash
NAS_SERVER_ADDR=127.0.0.1:47100 flutter test --tags server
```

## Phone-only checks (manual)

These cannot run in CI or on the dev machine; do them on a real phone.

| Check | How | Pass when |
|---|---|---|
| ⚪ Photo access with GPS kept | Back up a photo taken with location on | Server copy has the same bytes and EXIF GPS as the original |
| ⚪ Background backup | Lock the phone on Wi-Fi with new photos | WorkManager job runs and commits them without opening the app |
| ⚪ mDNS discovery on Wi-Fi | Open pairing on the same Wi-Fi as the server | Server is found (multicast lock held), not only by typed address |
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
