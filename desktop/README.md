# desktop — HaoTranNAS PC app

Author: Hao Tran

Flutter Linux app (M7, decisions D-039, D-041): backs up chosen PC folders
to the NAS, browses everything on the NAS and restores files or whole
folders, and manages the NAS (devices, pairing codes, scrub, cleanup).
It uses the same client as the phone (`../dart_client`, D-040). Design:
[docs/architecture.md](../docs/architecture.md) §6b.

```
 lib/
   app/      providers: shared client + folder backup + admin target
   backup/   FolderMediaSource (walks PC folders), hourly timer, run lock per process
   admin/    admin.sock line codec (pure), AdminLink (Unix socket), SshTunnel, AdminController
   files/    restore one file or a whole folder (never replaces a PC file)
   ui/       rail + 5 pages: Overview, Backup, Files, NAS, Settings; pairing page
```

| Rule | Why |
|---|---|
| Codec pure, Link = I/O, pages = glue (as in the phone app) | Tests on bytes and lines, no sockets |
| No config editing, no delete in the UI | Data-safety rules (docs/conventions.md §4) |
| Admin goes through admin.sock only: directly, or `ssh -L` to the NAS | No new port, no new server code (D-041) |

| | |
|---|---|
| Owns | PC client UI, folder source, admin client |
| Rules | [docs/conventions.md](../docs/conventions.md) |

## Build · Run

Needs the Linux desktop toolchain (`clang cmake ninja-build pkg-config
libgtk-3-dev`) and `libsqlite3` at run time. CI builds the release bundle
as the artifact `haotrannas-desktop-linux`.

```bash
export PUB_CACHE=/mnt/storage/HaoTran/sdk/pub-cache
export PATH=/mnt/storage/HaoTran/sdk/flutter/bin:$PATH
cd desktop
flutter pub get
flutter run -d linux                      # debug
flutter build linux --release             # → build/linux/x64/release/bundle/haotrannas_desktop
```

App data: `~/.local/share/vn.haotran.haotrannas_desktop/` (pairing key,
`backup_state.db`). Restores go where you pick.

First start: pick the NAS found on the LAN (or type its address), compare
the server id, then type the code, or set up the admin connection and use
**Pair in one click** (the code comes from admin.sock, and the server id
that came with it is compared for you).

## Test

```bash
flutter analyze
flutter test --exclude-tags server             # what CI runs
TMPDIR=/tmp ../e2e/scripts/desktop_vs_server.sh   # real server: M7 Done when
```

| Tests | What they check | Needs |
|---|---|---|
| `test/admin/admin_codec_test.dart` | Every admin reply form (status, pair, devices with spaces, revoke, scrub/cleanup summaries, errors, progress), bad lines never throw | nothing |
| `test/admin/admin_link_test.dart` | Line out, reply in, progress aside over a real Unix socket; no server; silent server; target save format | nothing |
| `test/admin/admin_controller_test.dart` | Refresh, unreachable, pairing code, revoke + reload, scrub progress, cleanup, problems | nothing |
| `test/backup/folder_media_source_test.dart` | Remote paths, counts, symlinks and unreadable folders skipped, Unicode, folder choice rules | nothing |
| `test/backup/desktop_run_lock_test.dart` | A closed app's run lock is freed at start; live, phone and damaged locks kept | nothing |
| `test/files/restore_test.dart` | Folder restore keeps the structure across pages, never replaces, failures, cancel | nothing |
| `test/ui/app_test.dart` | Pairing page; rail with 5 pages; Back up now / Stop; folders (also when settings load late); NAS devices + pairing code | nothing |
| `test/integration/desktop_vs_server_test.dart` (tag `server`) | Real TLS server: pair with an admin.sock code, back up a PC folder, second run sends nothing, restore + SHA-256 of every file, devices, scrub clean, cleanup, revoke locks out | `NAS_TLS_SERVER_ADDR`, `NAS_TLS_DATA_DIR` (the script sets them) |

## Checks by hand

| Check | How | Status |
|---|---|---|
| Real app against a server on this PC | One-click pairing, back up Pictures (66 files), browse phone photos, scrub | 🟢 2026-11-19 |
| Add folder with the system picker | Backup → Add folder | ⚪ (the picker ignored scripted clicks) |
| Restore from the Files page | Pick a file or Restore folder, choose a PC folder | ⚪ by hand (logic covered by the e2e test) |
| SSH admin to the NAS | NAS → Change → NAS over SSH | ⚪ needs M3n and the admin.sock group |
