# HaoTranNAS protocol — version 1

Author: Hao Tran · Status: Draft for freeze (tag `protocol-v1`) · 2026-11-18

This file is the contract. The Rust codec (`core/`) and the Dart codec
(`mobile/lib/protocol/`) are two independent implementations of it. The test
vectors in `vectors/` are the proof that they agree. **If code and spec
disagree, the spec wins.** If the spec is wrong, fix the spec first, bump the
version if the bytes change, then the code.

Key words: **must** = a rule a decoder or server enforces; **should** = advice.

---

## 1. Transport

| Item | Rule |
|---|---|
| Carrier | TCP, inside TLS 1.3. No other TLS version |
| Default port | `47100` |
| Server identity | Self-signed certificate; the client pins `SHA-256(server cert DER)`. **No hostname check**: clients connect by IP |
| Device identity | TLS client certificate issued by the server at pairing (section 7) |
| Dev mode | `--dev-plain`: plain TCP, bound to `127.0.0.1` only, every connection is device 1 (`dev`). For tests up to M2 only. Never on a network |

## 2. Primitive types

All integers are **big-endian**.

| Type | Bytes | Rule |
|---|---|---|
| `u8` `u16` `u32` | 1, 2, 4 | — |
| `u64` | 8 | Value **must** be < 2^63 (top bit clear) so Dart's signed 64-bit `int` holds it |
| `i64` | 8 | Two's complement |
| `bool` | 1 | `0` = false, `1` = true; any other value is malformed |
| `str` | 2 + n | `u16` byte length, then strict UTF-8 (no overlong forms, no surrogates `U+D800–DFFF`, nothing above `U+10FFFF`). Each field has a max length (section 4) |
| `bytes` | 4 + n | `u32` byte length, then raw bytes |
| `hash` | 32 | Raw SHA-256 digest |
| `list<T>` | 4 + … | `u32` item count, then the items |

## 3. Frame

```
 offset 0          4              6                10
 ┌────────────────┬──────────────┬────────────────┬──────────────────┐
 │ length_bytes   │ message_type │ request_id     │ payload          │
 │ u32            │ u16          │ u32            │ length_bytes - 6 │
 └────────────────┴──────────────┴────────────────┴──────────────────┘
 length_bytes counts everything after itself: 6 + payload size.
```

| Rule | Value / behaviour |
|---|---|
| `length_bytes` range | `6 ..= 4 194 304` (`MAX_FRAME_LENGTH_BYTES`). Outside the range → malformed, detected from the 4-byte header alone, **before** reading the body |
| `message_type` | Must be a type in section 5. `0` and unknown types → malformed |
| `request_id` | Set by the client on each request: starts at 1, +1 per request, skips 0 on wrap. A reply copies the request's id. A `Close`, and an `Error` that answers no readable request, use `0` |
| Payload | Must be consumed exactly. Missing bytes or trailing bytes → malformed |
| One reply per request | Every request gets exactly one reply: its reply type or `Error`. `Close` gets no reply |
| Order | The server handles one connection's frames in order and replies in the same order. Clients may pipeline; v1 clients send one request at a time |

**Decoders never panic or throw.** On bad input they return an error value
(`MALFORMED_FRAME` plus a reason text). A list count is checked against the
remaining bytes (`count × smallest item size ≤ remaining`) before anything is
allocated.

## 4. String length limits

Checked by the codec; a longer string → malformed.

| Field | Max bytes |
|---|---|
| `client_software`, `server_software`, `device_name`, `server_name`, `name` in DeviceList, `code` | 64 (`MAX_NAME_BYTES`) |
| `path`, `start_after`, `name` in DirEntries | 1024 (`MAX_PATH_BYTES`) |
| `message` in Close and Error | 1024 (`MAX_MESSAGE_BYTES`) |

## 5. Messages

Direction: C = client (phone, cli), S = server. A request type is odd, and its
reply is request + 1. `Close` and `Error` are the two exceptions.

| Type | Name | Dir | Payload, in order |
|---|---|---|---|
| `0x0001` | Hello | C→S | `protocol_version u16` · `client_software str` · `device_name str` |
| `0x0002` | HelloOk | S→C | `protocol_version u16` · `server_software str` · `server_name str` · `device_id u64` (0 = not paired on this connection) · `chunk_size_bytes u32` · `max_frame_length_bytes u32` |
| `0x0003` | Ping | C→S | (empty) |
| `0x0004` | Pong | S→C | (empty) |
| `0x0101` | PairRequest | C→S | `code str` |
| `0x0102` | PairOk | S→C | `device_id u64` · `device_cert_der bytes` · `device_key_pkcs8_der bytes` · `server_cert_sha256 hash` |
| `0x0201` | FileOffer | C→S | `path str` · `size_bytes u64` · `modified_time_ms i64` · `file_sha256 hash` · `chunk_hashes list<hash>` |
| `0x0202` | NeedChunks | S→C | `upload_id u64` · `existing_version_id u64` · `missing_indexes list<u32>` |
| `0x0203` | ChunkData | C→S | `upload_id u64` · `chunk_index u32` · `chunk_sha256 hash` · `data bytes` |
| `0x0204` | ChunkOk | S→C | `chunk_index u32` · `chunk_sha256 hash` |
| `0x0205` | Commit | C→S | `upload_id u64` |
| `0x0206` | CommitOk | S→C | `version_id u64` |
| `0x0301` | ListDevices | C→S | (empty) |
| `0x0302` | DeviceList | S→C | `devices list<DeviceEntry>`; DeviceEntry = `device_id u64` · `name str` · `paired_at_ms i64` · `is_caller bool` |
| `0x0303` | ListDir | C→S | `device_id u64` (0 = caller) · `path str` ("" = root) · `start_after str` ("" = from the start) · `max_entries u32` |
| `0x0304` | DirEntries | S→C | `entries list<DirEntry>` · `has_more bool`; DirEntry = `name str` · `kind u8` (1 = directory, 2 = file; other values malformed) · `size_bytes u64` · `modified_time_ms i64` · `version_id u64` |
| `0x0401` | ReadFile | C→S | `device_id u64` (0 = caller) · `path str` · `version_id u64` (0 = latest) |
| `0x0402` | FileManifest | S→C | `version_id u64` · `size_bytes u64` · `modified_time_ms i64` · `file_sha256 hash` · `chunk_hashes list<hash>` |
| `0x0403` | ReadChunk | C→S | `chunk_sha256 hash` |
| `0x0404` | ChunkContent | S→C | `chunk_sha256 hash` · `data bytes` |
| `0x00F0` | Close | both | `reason u16` · `message str` |
| `0x00FF` | Error | S→C | `code u16` · `message str` |

Largest frames: ChunkData = 4 + 6 + 8 + 4 + 32 + 4 + 1 048 576 = 1 048 634 bytes;
FileOffer with 65 536 hashes ≈ 2.1 MB. Both fit under the 4 MiB limit.

## 6. Session states

```
             Hello ok, cert known
 AwaitingHello ─────────────────────────────► Ready ◄──┐ requests
      │  Hello ok, no cert                              └─────────┘
      ▼
   Unpaired ──PairRequest ok──► PairOk + Close(PAIRED_RECONNECT) ──► closed
```

| State | Allowed from the client | Everything else |
|---|---|---|
| AwaitingHello | Hello | `UNEXPECTED_MESSAGE` (fatal) |
| Unpaired | PairRequest, Ping, Close | Ready-only requests → `NOT_PAIRED` (fatal); Hello → `UNEXPECTED_MESSAGE` (fatal) |
| Ready | Ping, FileOffer, ChunkData, Commit, ListDevices, ListDir, ReadFile, ReadChunk, Close | Hello, PairRequest → `UNEXPECTED_MESSAGE` (fatal) |

| Event | Server action |
|---|---|
| Hello with another `protocol_version` | `Error VERSION_MISMATCH` (fatal) |
| Hello, client cert present, fingerprint in `devices` | HelloOk with that `device_id` → Ready |
| Hello, client cert present, fingerprint unknown (revoked) | `Error NOT_PAIRED` (fatal) |
| Hello, no client cert | HelloOk with `device_id = 0` → Unpaired |
| A server-to-client type arrives from the client | `UNEXPECTED_MESSAGE` (fatal) |
| No Hello within `HANDSHAKE_TIMEOUT_MS` (10 000) of accept | `Close HANDSHAKE_TIMEOUT` |
| No frame for `IDLE_TIMEOUT_MS` (60 000) | `Close IDLE_TIMEOUT` |
| Server stopping | `Close SERVER_SHUTDOWN` |

**Fatal** means the server sends the `Error` and closes the connection; no
`Close` frame follows. Clients send `Ping` after `PING_INTERVAL_MS` (20 000)
without traffic.

**TLS 1.3 note for clients:** the server checks the client certificate after
the client's handshake has finished. A rejected certificate shows up as a TLS
alert or end-of-stream on the first read, not as a connect error. A client
that loses the connection before `HelloOk` must treat it as "maybe not paired".

## 7. Pairing

```
 admin: haotrannas-server pair  →  "code 482913 · server id 3F9A-C21B-77E0 · valid 120 s"
 phone: TLS without client cert → records server fingerprint (trust on first use)
        Hello → HelloOk(device_id 0) → PairRequest("482913")
 server: checks network, window, code → issues device cert → PairOk → Close(PAIRED_RECONNECT)
 phone: checks PairOk.server_cert_sha256 == fingerprint it saw, shows the short id,
        stores cert + key, reconnects with the client cert
```

| Rule | Value |
|---|---|
| Code | 6 ASCII digits, uniformly random, single use, valid `PAIRING_CODE_TTL_MS` (120 000) |
| Compare | Constant time |
| Network | Source IP must be in the config's `pairing_networks` (LAN). Else `PAIRING_NOT_ALLOWED_FROM_NETWORK` (fatal) |
| No open window | `PAIRING_NOT_OPEN` (not fatal) |
| Wrong code | `BAD_PAIRING_CODE`; fatal on the 3rd failure in one connection (`MAX_PAIR_FAILURES_PER_CONNECTION`) |
| Too many failures | After 10 failures (`MAX_PAIR_FAILURES_PER_WINDOW`) the window closes; further tries get `TOO_MANY_ATTEMPTS` (fatal) |
| Device cert | ECDSA P-256, signed by the server's device CA, CN `device-<device_id>`, EKU clientAuth, valid from now − 1 day for 100 years |
| Key format | `device_key_pkcs8_der` is PKCS#8 DER. Clients wrap cert and key in PEM for their TLS library |
| Fingerprint | `SHA-256(cert DER)` |
| Short id | First 6 bytes of a fingerprint, uppercase hex, in groups of 4 joined by `-`: `3F9A-C21B-77E0` |
| Logging | The key in PairOk must never be logged. Debug output prints `<key redacted>` |

🟡 Known weakness: the code does not authenticate the server. Someone actively
in the middle on the LAN during the 2-minute window could take the device key.
The short-id comparison by the user is the v1 defence; QR code or PAKE later.

## 8. Upload

### Chunking

| Rule | Value |
|---|---|
| Chunk size | `CHUNK_SIZE_BYTES` = 1 048 576 (1 MiB) |
| Chunk count | `ceil(size_bytes / CHUNK_SIZE_BYTES)`; a 0-byte file has 0 chunks |
| Chunk sizes | Every chunk is 1 MiB except the last, which holds the rest |
| Max chunks | `MAX_CHUNKS_PER_FILE` = 65 536 (64 GiB) |
| `chunk_hashes[i]` | SHA-256 of chunk `i`'s bytes |
| `file_sha256` | SHA-256 of the whole file (for 0 bytes: SHA-256 of empty input) |

### Flow

```
 FileOffer ──► NeedChunks(upload_id, existing_version_id, missing_indexes)
   existing_version_id ≠ 0 → already backed up, done (no Commit)
   else for each i in missing_indexes: ChunkData(upload_id, i, hash, data) ──► ChunkOk
 Commit(upload_id) ──► CommitOk(version_id)
```

| Message | Server checks, in order | Error |
|---|---|---|
| FileOffer | Path rules (section 10) | `BAD_PATH` |
| | Chunk count > 65 536 | `TOO_LARGE` |
| | Chunk count ≠ `ceil(size / 1 MiB)` | `BAD_ARGUMENT` |
| | Latest version of (device, path) has the same `size_bytes`, `modified_time_ms` and `file_sha256`, **and none of its chunks is marked bad** → reply `upload_id 0`, `existing_version_id` = that version, empty list | — |
| | Otherwise: new upload (random `upload_id`, 1 ..< 2^63); `missing_indexes` = for each **distinct** hash not stored (or marked bad), the **first** index that has it, ascending | — |
| ChunkData | Upload exists and belongs to this device | `UNKNOWN_UPLOAD` |
| | `chunk_index` < chunk count | `BAD_ARGUMENT` |
| | `chunk_sha256` = offered hash at that index | `CHUNK_HASH_MISMATCH` |
| | `data` length = expected size for that index | `CHUNK_SIZE_WRONG` |
| | `SHA-256(data)` = `chunk_sha256` | `CHUNK_HASH_MISMATCH` |
| | Chunk already stored **and not bad** → ChunkOk without writing (safe to repeat). A chunk marked bad is overwritten (atomic replace) and marked ok again | — |
| | Store atomically (temp file, fsync, verify, rename, fsync directory) | `DISK_FULL`, `INTERNAL` |
| Commit | Upload exists and belongs to this device | `UNKNOWN_UPLOAD` |
| | Every distinct hash is stored and not bad | `CHUNKS_MISSING` |
| | SHA-256 of the chunks in order = `file_sha256` | `FILE_HASH_MISMATCH` (upload dropped) |
| | One transaction: file row (if new), version, version chunks; upload removed | — |

A client that loses `CommitOk` sends the same FileOffer again. The server answers
with `existing_version_id`, so no duplicate version is made.

On `CHUNKS_MISSING` (a chunk was marked bad by scrub after the offer) the client
sends the same FileOffer again and uploads what the new NeedChunks asks for.
It never retries `Commit` alone.

**Repair of bit rot:** scrub marks a damaged chunk bad. It is repaired when any
device offers a file that contains it again: the offer lists the chunk as
missing and the upload overwrites it. A phone re-offers files it already backed
up only through its "verify backup" action (M6); the ZFS mirror is the other
repair path.

## 9. Browse and download

| Message | Rule |
|---|---|
| ListDevices | Every paired device; `is_caller` marks the asking one |
| ListDir | `max_entries` 1 ..= 1000, else `BAD_ARGUMENT`. Unknown device → `NOT_FOUND`. Path "" = root; otherwise path rules apply (`BAD_PATH`) |
| | Shows the direct children of `path` from the latest version of each file. Directories are implied by file paths. Sorted by name, byte-wise ascending. Only names `> start_after` (byte-wise). `has_more` = more entries exist after this page |
| | Directory entry: `size_bytes 0`, `modified_time_ms 0`, `version_id 0`. If a name is both a file and a directory (changed over time), the directory is shown |
| | A non-root path with no children → `NOT_FOUND`. An empty root → empty list |
| ReadFile | Unknown device, path or version → `NOT_FOUND`. `version_id 0` = latest |
| ReadChunk | Chunk must be stored, not bad, and used by a committed version; else `NOT_FOUND` |

Download = ReadFile, then ReadChunk for each hash in order. The client writes
to a temp file, checks `file_sha256`, then renames.

## 10. Path rules

Both sides check them. Vectors: `vectors/path_rules.json`.

| Rule |
|---|
| UTF-8, 1 ..= 1024 bytes |
| Components separated by `/`; at most 32 components; each component 1 ..= 255 bytes |
| No leading or trailing `/`, no empty component (`a//b`) |
| No component equal to `.` or `..` |
| No NUL (`U+0000`) and no backslash `\` anywhere |
| No Unicode normalization: stored exactly as sent |

## 11. Error codes

Never reuse or renumber a code.

| Code | Name | Fatal | When |
|---|---|---|---|
| 1 | MALFORMED_FRAME | yes | Bad frame or payload (sections 2–5) |
| 2 | VERSION_MISMATCH | yes | Hello with another version |
| 3 | UNEXPECTED_MESSAGE | yes | Message not allowed in this state or direction |
| 4 | NOT_PAIRED | yes | Ready-only request while unpaired, or unknown client cert |
| 5 | PAIRING_NOT_OPEN | no | No pairing window open |
| 6 | BAD_PAIRING_CODE | 3rd time | Wrong code |
| 7 | TOO_MANY_ATTEMPTS | yes | Window locked after too many failures |
| 8 | PAIRING_NOT_ALLOWED_FROM_NETWORK | yes | Pairing from outside `pairing_networks` |
| 20 | BAD_PATH | no | Path rules broken |
| 21 | BAD_ARGUMENT | no | A value out of range (index, count, `max_entries`) |
| 22 | TOO_LARGE | no | More than 65 536 chunks |
| 23 | CHUNK_HASH_MISMATCH | no | Chunk hash wrong |
| 24 | CHUNK_SIZE_WRONG | no | Chunk length wrong for its index |
| 25 | UNKNOWN_UPLOAD | no | No such open upload for this device |
| 26 | CHUNKS_MISSING | no | Commit before all chunks arrived |
| 27 | FILE_HASH_MISMATCH | no | Whole-file hash wrong at Commit |
| 28 | DISK_FULL | no | No space to store |
| 40 | NOT_FOUND | no | Device, path, version or chunk not found |
| 50 | INTERNAL | no | Server bug or I/O error |
| 51 | SHUTTING_DOWN | yes | Server is stopping |

An unknown code received by a client is shown as `UNKNOWN(<code>)`, not malformed.

## 12. Close reasons

| Reason | Name |
|---|---|
| 0 | NORMAL |
| 1 | HANDSHAKE_TIMEOUT |
| 2 | IDLE_TIMEOUT |
| 3 | PROTOCOL_ERROR |
| 4 | SERVER_SHUTDOWN |
| 5 | PAIRED_RECONNECT |

An unknown reason received is shown as `UNKNOWN(<reason>)`, not malformed.

## 13. Discovery (mDNS)

| Item | Value |
|---|---|
| Service | `_haotrannas._tcp.local` |
| Port | The server's TLS port |
| TXT | `v=1`, `fp=<first 16 lowercase hex chars of the server fingerprint>` |
| Client | Accept a result only if `fp` matches the pinned fingerprint. Use the IPv4 (A record) address: the NAS firewall opens the port on IPv4 only. Then connect and check the full pin |

## 14. Limits (same names in Rust `core/src/limits.rs` and Dart `lib/protocol/limits.dart`)

| Name | Value |
|---|---|
| PROTOCOL_VERSION | 1 |
| FRAME_HEADER_BYTES | 10 |
| MIN_FRAME_LENGTH_BYTES | 6 |
| MAX_FRAME_LENGTH_BYTES | 4 194 304 |
| CHUNK_SIZE_BYTES | 1 048 576 |
| MAX_CHUNKS_PER_FILE | 65 536 |
| HASH_BYTES | 32 |
| MAX_PATH_BYTES | 1024 |
| MAX_PATH_COMPONENTS | 32 |
| MAX_NAME_BYTES | 64 |
| MAX_MESSAGE_BYTES | 1024 |
| MAX_LIST_DIR_ENTRIES | 1000 |
| PAIRING_CODE_DIGITS | 6 |
| HANDSHAKE_TIMEOUT_MS | 10 000 |
| IDLE_TIMEOUT_MS | 60 000 |
| PING_INTERVAL_MS | 20 000 |
| PAIRING_CODE_TTL_MS | 120 000 |
| MAX_PAIR_FAILURES_PER_CONNECTION | 3 |
| MAX_PAIR_FAILURES_PER_WINDOW | 10 |
| CONNECT_TIMEOUT_MS | 3 000 |

Component length (255 bytes) is a path rule, not a shared limit constant.

## 15. Test vectors

Generated by `tools/gen_vectors.py` (a third, independent encoder in Python),
reviewed by hand, then committed. Regenerate with
`python3 protocol/tools/gen_vectors.py` and check `git diff` is empty.

| File | Contents |
|---|---|
| `vectors/messages.json` | `valid`: at least one frame per message type plus edge cases; `invalid`: frames each decoder must reject |
| `vectors/path_rules.json` | Paths with `valid` true/false and the reason |
| `vectors/chunking.json` | Files from `byte[i] = i mod 251` at edge sizes, with expected chunk hashes and `file_sha256` |

JSON encoding of field values: `u8 u16 u32` = numbers; `u64 i64` = decimal
**strings**; `bool` = true/false; `str` = JSON string; `bytes` and `hash` =
lowercase hex strings; lists = arrays; list items = objects. `frame_hex` is a
list of hex segments (header fields, then one per payload field) so a person
can check it against this spec; decoders join the segments.

Every implementation must, for each valid vector, decode the joined bytes to
exactly `fields` and encode `fields` to exactly the bytes; and for each invalid
vector, reject it with `MALFORMED_FRAME`. It must also decode all valid frames
concatenated and fed in random-sized pieces (fixed seed) to the same messages.
