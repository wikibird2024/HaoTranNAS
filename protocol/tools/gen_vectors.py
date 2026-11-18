#!/usr/bin/env python3
"""Generate protocol/vectors/*.json from protocol/spec.md (version 1).

This is a third, independent encoder of the spec. Rust (core/) and Dart
(mobile/lib/protocol/) must both decode every valid vector to exactly its
fields, encode the fields to exactly its bytes, and reject every invalid
vector with MALFORMED_FRAME.

Run from anywhere:  python3 protocol/tools/gen_vectors.py
Then `git diff protocol/vectors` must be empty unless the spec changed.
"""

import hashlib
import json
import struct
from pathlib import Path

VECTORS_DIR = Path(__file__).resolve().parent.parent / "vectors"

PROTOCOL_VERSION = 1
CHUNK_SIZE_BYTES = 1_048_576
MAX_FRAME_LENGTH_BYTES = 4_194_304
MAX_NAME_BYTES = 64
MAX_PATH_BYTES = 1024
MAX_MESSAGE_BYTES = 1024

# ── Message schemas (spec section 5) ─────────────────────────────────────
# Field kinds: u8 u16 u32 u64 i64 bool hash bytes, ("str", max_bytes),
# ("list", item_kind) where item_kind is a kind or ("struct", fields).

NAME = ("str", MAX_NAME_BYTES)
PATH = ("str", MAX_PATH_BYTES)
TEXT = ("str", MAX_MESSAGE_BYTES)

DEVICE_ENTRY = ("struct", [("device_id", "u64"), ("name", NAME),
                           ("paired_at_ms", "i64"), ("is_caller", "bool")])
DIR_ENTRY = ("struct", [("name", PATH), ("kind", "kind"),
                        ("size_bytes", "u64"), ("modified_time_ms", "i64"),
                        ("version_id", "u64")])

MESSAGES = {
    "Hello": (0x0001, [("protocol_version", "u16"), ("client_software", NAME),
                       ("device_name", NAME)]),
    "HelloOk": (0x0002, [("protocol_version", "u16"), ("server_software", NAME),
                         ("server_name", NAME), ("device_id", "u64"),
                         ("chunk_size_bytes", "u32"),
                         ("max_frame_length_bytes", "u32")]),
    "Ping": (0x0003, []),
    "Pong": (0x0004, []),
    "PairRequest": (0x0101, [("code", NAME)]),
    "PairOk": (0x0102, [("device_id", "u64"), ("device_cert_der", "bytes"),
                        ("device_key_pkcs8_der", "bytes"),
                        ("server_cert_sha256", "hash")]),
    "FileOffer": (0x0201, [("path", PATH), ("size_bytes", "u64"),
                           ("modified_time_ms", "i64"), ("file_sha256", "hash"),
                           ("chunk_hashes", ("list", "hash"))]),
    "NeedChunks": (0x0202, [("upload_id", "u64"), ("existing_version_id", "u64"),
                            ("missing_indexes", ("list", "u32"))]),
    "ChunkData": (0x0203, [("upload_id", "u64"), ("chunk_index", "u32"),
                           ("chunk_sha256", "hash"), ("data", "bytes")]),
    "ChunkOk": (0x0204, [("chunk_index", "u32"), ("chunk_sha256", "hash")]),
    "Commit": (0x0205, [("upload_id", "u64")]),
    "CommitOk": (0x0206, [("version_id", "u64")]),
    "ListDevices": (0x0301, []),
    "DeviceList": (0x0302, [("devices", ("list", DEVICE_ENTRY))]),
    "ListDir": (0x0303, [("device_id", "u64"), ("path", PATH),
                         ("start_after", PATH), ("max_entries", "u32")]),
    "DirEntries": (0x0304, [("entries", ("list", DIR_ENTRY)), ("has_more", "bool")]),
    "ReadFile": (0x0401, [("device_id", "u64"), ("path", PATH), ("version_id", "u64")]),
    "FileManifest": (0x0402, [("version_id", "u64"), ("size_bytes", "u64"),
                              ("modified_time_ms", "i64"), ("file_sha256", "hash"),
                              ("chunk_hashes", ("list", "hash"))]),
    "ReadChunk": (0x0403, [("chunk_sha256", "hash")]),
    "ChunkContent": (0x0404, [("chunk_sha256", "hash"), ("data", "bytes")]),
    "Close": (0x00F0, [("reason", "u16"), ("message", TEXT)]),
    "Error": (0x00FF, [("code", "u16"), ("message", TEXT)]),
}


# ── Encoder: returns a list of hex segments, one per field ──────────────
def encode_value(kind, value):
    """Return a list of hex segments for one field value (JSON form)."""
    if kind == "u8" or kind == "kind":
        assert 0 <= value <= 0xFF
        if kind == "kind":
            assert value in (1, 2)
        return [struct.pack(">B", value).hex()]
    if kind == "bool":
        return ["01" if value else "00"]
    if kind == "u16":
        return [struct.pack(">H", value).hex()]
    if kind == "u32":
        return [struct.pack(">I", value).hex()]
    if kind == "u64":
        number = int(value)
        assert 0 <= number < 2**63, "u64 must be < 2^63"
        return [struct.pack(">Q", number).hex()]
    if kind == "i64":
        return [struct.pack(">q", int(value)).hex()]
    if kind == "hash":
        raw = bytes.fromhex(value)
        assert len(raw) == 32
        return [raw.hex()]
    if kind == "bytes":
        raw = bytes.fromhex(value)
        return [struct.pack(">I", len(raw)).hex() + raw.hex()]
    if isinstance(kind, tuple) and kind[0] == "str":
        raw = value.encode("utf-8")
        assert len(raw) <= kind[1], f"string longer than {kind[1]} bytes"
        return [struct.pack(">H", len(raw)).hex() + raw.hex()]
    if isinstance(kind, tuple) and kind[0] == "list":
        segments = [struct.pack(">I", len(value)).hex()]
        for item in value:
            segments += encode_value(kind[1], item)
        return segments
    if isinstance(kind, tuple) and kind[0] == "struct":
        segments = []
        for field_name, field_kind in kind[1]:
            segments += encode_value(field_kind, value[field_name])
        return segments
    raise ValueError(f"unknown kind {kind}")


def encode_frame(message, request_id, fields):
    message_type, schema = MESSAGES[message]
    assert set(fields) == {name for name, _ in schema}, f"{message}: field names"
    payload_segments = []
    for field_name, field_kind in schema:
        payload_segments += encode_value(field_kind, fields[field_name])
    payload_bytes = sum(len(segment) // 2 for segment in payload_segments)
    length_bytes = 6 + payload_bytes
    assert length_bytes <= MAX_FRAME_LENGTH_BYTES
    header = [struct.pack(">I", length_bytes).hex(),
              struct.pack(">H", message_type).hex(),
              struct.pack(">I", request_id).hex()]
    return header + payload_segments


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pattern_file(size_bytes: int) -> bytes:
    """The chunking test file: byte[i] = i mod 251."""
    return bytes(index % 251 for index in range(size_bytes))


def chunk_hashes(data: bytes):
    return [sha256_hex(data[start:start + CHUNK_SIZE_BYTES])
            for start in range(0, len(data), CHUNK_SIZE_BYTES)]


# ── Valid message vectors ────────────────────────────────────────────────
def valid_vectors():
    hello_hash = sha256_hex(b"hello")
    big_file = pattern_file(3_145_745)
    big_hashes = chunk_hashes(big_file)
    server_fingerprint = sha256_hex(b"example server certificate")
    long_name = "n" * MAX_NAME_BYTES
    long_path = "/".join(["a" * 255, "b" * 255, "c" * 255, "d" * 254, "e"])
    assert len(long_path.encode()) == MAX_PATH_BYTES

    cases = [
        ("hello_basic", "Hello", 1,
         {"protocol_version": 1, "client_software": "haotrannas-cli/0.1.0",
          "device_name": "pixel-7"}),
        ("hello_vietnamese_name", "Hello", 1,
         {"protocol_version": 1, "client_software": "haotrannas-mobile/0.1.0",
          "device_name": "Điện thoại của Hào"}),
        ("hello_name_at_max_length", "Hello", 1,
         {"protocol_version": 1, "client_software": "", "device_name": long_name}),
        ("hello_ok_unpaired", "HelloOk", 1,
         {"protocol_version": 1, "server_software": "haotrannas-server/0.1.0",
          "server_name": "home-nas", "device_id": "0",
          "chunk_size_bytes": CHUNK_SIZE_BYTES,
          "max_frame_length_bytes": MAX_FRAME_LENGTH_BYTES}),
        ("hello_ok_paired", "HelloOk", 1,
         {"protocol_version": 1, "server_software": "haotrannas-server/0.1.0",
          "server_name": "home-nas", "device_id": "7",
          "chunk_size_bytes": CHUNK_SIZE_BYTES,
          "max_frame_length_bytes": MAX_FRAME_LENGTH_BYTES}),
        ("ping", "Ping", 2, {}),
        ("pong", "Pong", 2, {}),
        ("ping_request_id_max", "Ping", 0xFFFFFFFF, {}),
        ("pair_request", "PairRequest", 3, {"code": "482913"}),
        ("pair_ok", "PairOk", 3,
         {"device_id": "7", "device_cert_der": "3082010a0201",
          "device_key_pkcs8_der": "308187020100", "server_cert_sha256": server_fingerprint}),
        ("file_offer_three_mib", "FileOffer", 5,
         {"path": "DCIM/Camera/IMG_0001.jpg", "size_bytes": str(len(big_file)),
          "modified_time_ms": "1731916800000", "file_sha256": sha256_hex(big_file),
          "chunk_hashes": big_hashes}),
        ("file_offer_empty_file_negative_time", "FileOffer", 5,
         {"path": "notes/empty.txt", "size_bytes": "0", "modified_time_ms": "-1000",
          "file_sha256": sha256_hex(b""), "chunk_hashes": []}),
        ("file_offer_emoji_path", "FileOffer", 5,
         {"path": "Ảnh/📷 bãi biển.jpg", "size_bytes": "5",
          "modified_time_ms": "0", "file_sha256": hello_hash,
          "chunk_hashes": [hello_hash]}),
        ("need_chunks_some_missing", "NeedChunks", 5,
         {"upload_id": "1234567890123", "existing_version_id": "0",
          "missing_indexes": [0, 2]}),
        ("need_chunks_already_backed_up", "NeedChunks", 5,
         {"upload_id": "0", "existing_version_id": "42", "missing_indexes": []}),
        ("chunk_data_small", "ChunkData", 7,
         {"upload_id": "1234567890123", "chunk_index": 3, "chunk_sha256": hello_hash,
          "data": b"hello".hex()}),
        ("chunk_data_empty", "ChunkData", 7,
         {"upload_id": "1", "chunk_index": 0, "chunk_sha256": sha256_hex(b""),
          "data": ""}),
        ("chunk_ok", "ChunkOk", 7, {"chunk_index": 3, "chunk_sha256": hello_hash}),
        ("commit", "Commit", 9, {"upload_id": "1234567890123"}),
        ("commit_ok", "CommitOk", 9, {"version_id": "42"}),
        ("commit_ok_u64_max", "CommitOk", 9, {"version_id": str(2**63 - 1)}),
        ("list_devices", "ListDevices", 11, {}),
        ("device_list_two", "DeviceList", 11,
         {"devices": [
             {"device_id": "7", "name": "pixel-7", "paired_at_ms": "1731916800000",
              "is_caller": True},
             {"device_id": "8", "name": "old-phone", "paired_at_ms": "1700000000000",
              "is_caller": False}]}),
        ("device_list_empty", "DeviceList", 11, {"devices": []}),
        ("list_dir_root", "ListDir", 13,
         {"device_id": "0", "path": "", "start_after": "", "max_entries": 1000}),
        ("list_dir_page_two", "ListDir", 13,
         {"device_id": "7", "path": "DCIM/Camera", "start_after": "IMG_0001.jpg",
          "max_entries": 50}),
        ("dir_entries_mixed", "DirEntries", 13,
         {"entries": [
             {"name": "Camera", "kind": 1, "size_bytes": "0",
              "modified_time_ms": "0", "version_id": "0"},
             {"name": "IMG_0001.jpg", "kind": 2, "size_bytes": str(len(big_file)),
              "modified_time_ms": "1731916800000", "version_id": "42"}],
          "has_more": False}),
        ("dir_entries_empty_more", "DirEntries", 13, {"entries": [], "has_more": True}),
        ("read_file_latest", "ReadFile", 15,
         {"device_id": "0", "path": "DCIM/Camera/IMG_0001.jpg", "version_id": "0"}),
        ("read_file_long_path", "ReadFile", 15,
         {"device_id": "7", "path": long_path, "version_id": "42"}),
        ("file_manifest", "FileManifest", 15,
         {"version_id": "42", "size_bytes": str(len(big_file)),
          "modified_time_ms": str(-(2**63)), "file_sha256": sha256_hex(big_file),
          "chunk_hashes": big_hashes}),
        ("read_chunk", "ReadChunk", 17, {"chunk_sha256": hello_hash}),
        ("chunk_content", "ChunkContent", 17,
         {"chunk_sha256": hello_hash, "data": b"hello".hex()}),
        ("close_normal", "Close", 0, {"reason": 0, "message": ""}),
        ("close_paired_reconnect", "Close", 0,
         {"reason": 5, "message": "paired, reconnect with your certificate"}),
        ("error_unknown_upload", "Error", 9, {"code": 25, "message": "unknown upload"}),
        ("error_unknown_code", "Error", 9, {"code": 999, "message": "from a newer server"}),
    ]
    vectors = []
    for name, message, request_id, fields in cases:
        vectors.append({"name": name, "message": message, "request_id": request_id,
                        "fields": fields,
                        "frame_hex": encode_frame(message, request_id, fields)})
    covered = {vector["message"] for vector in vectors}
    assert covered == set(MESSAGES), f"missing vectors for {set(MESSAGES) - covered}"
    return vectors


# ── Invalid frames: every decoder must reject with MALFORMED_FRAME ───────
def invalid_vectors():
    def header(length_bytes, message_type, request_id=1):
        return [struct.pack(">I", length_bytes).hex(),
                struct.pack(">H", message_type).hex(),
                struct.pack(">I", request_id).hex()]

    def frame(message_type, payload_segments, request_id=1):
        payload_bytes = sum(len(segment) // 2 for segment in payload_segments)
        return header(6 + payload_bytes, message_type, request_id) + payload_segments

    def text(value: bytes):
        return struct.pack(">H", len(value)).hex() + value.hex()

    cases = [
        ("length_zero", ["00000000"], "header",
         "length_bytes 0 is below 6"),
        ("length_five", ["00000005", "0003", "000000"], "header",
         "length_bytes 5 is below 6"),
        ("length_over_max", [struct.pack(">I", MAX_FRAME_LENGTH_BYTES + 1).hex()], "header",
         "length_bytes above 4 MiB, rejected from the header alone"),
        ("type_zero", header(6, 0x0000), "payload", "message type 0"),
        ("type_unknown", header(6, 0x0999), "payload", "unknown message type"),
        ("ping_trailing_byte", frame(0x0003, ["00"]), "payload",
         "Ping has an empty payload"),
        ("hello_truncated", frame(0x0001, ["0001"]), "payload",
         "payload ends before client_software"),
        ("hello_string_length_past_end", frame(0x0001, ["0001", "003f616263"]), "payload",
         "string length 63 (under the 64-byte limit) but only 3 bytes left"),
        ("hello_invalid_utf8", frame(0x0001, ["0001", text(b""), text(b"\xff")]), "payload",
         "0xff is never valid UTF-8"),
        ("hello_utf8_surrogate", frame(0x0001, ["0001", text(b""), text(b"\xed\xa0\x80")]),
         "payload", "encoded surrogate U+D800"),
        ("hello_utf8_overlong", frame(0x0001, ["0001", text(b""), text(b"\xc0\xaf")]),
         "payload", "overlong encoding of '/'"),
        ("hello_name_too_long", frame(0x0001, ["0001", text(b""), text(b"n" * 65)]),
         "payload", "device_name longer than 64 bytes"),
        ("commit_ok_u64_top_bit", frame(0x0206, ["8000000000000000"]), "payload",
         "u64 must be < 2^63"),
        ("dir_entries_bool_two", frame(0x0304, ["00000000", "02"]), "payload",
         "bool must be 0 or 1"),
        ("dir_entries_kind_three", frame(0x0304, [
            "00000001", text(b"x"), "03", "0000000000000000", "0000000000000000",
            "0000000000000000", "00"]), "payload", "kind must be 1 or 2"),
        ("need_chunks_count_past_end", frame(0x0202, [
            "0000000000000001", "0000000000000000", "ffffffff"]), "payload",
         "list count larger than the bytes left"),
        ("read_chunk_short_hash", frame(0x0403, ["00" * 31]), "payload",
         "hash needs 32 bytes"),
        ("close_trailing_bytes", frame(0x00F0, ["0000", text(b""), "0000"]), "payload",
         "bytes left after the last field"),
    ]
    return [{"name": name, "frame_hex": segments, "stage": stage,
             "expect_error": "MALFORMED_FRAME", "why": why}
            for name, segments, stage, why in cases]


# ── Path rules (spec section 10) ─────────────────────────────────────────
def path_rule_vectors():
    cases = [
        ("DCIM/Camera/IMG_0001.jpg", True, "normal path"),
        ("a", True, "single component"),
        ("Ảnh/📷 bãi biển.jpg", True, "UTF-8, spaces, emoji"),
        ("a/b.c/..d/...", True, "dots inside names are fine"),
        ("/".join(["a" * 255, "b" * 255, "c" * 255, "d" * 254, "e"]), True,
         "exactly 1024 bytes"),
        ("/".join(["p"] * 32), True, "exactly 32 components"),
        ("x" * 255, True, "component of exactly 255 bytes"),
        ("", False, "empty"),
        ("/a", False, "leading slash"),
        ("a/", False, "trailing slash"),
        ("a//b", False, "empty component"),
        (".", False, "dot component"),
        ("a/./b", False, "dot component"),
        ("..", False, "dot-dot component"),
        ("a/../b", False, "dot-dot component"),
        ("a\\b", False, "backslash"),
        ("a\u0000b", False, "NUL"),
        ("/".join(["a" * 255, "b" * 255, "c" * 255, "d" * 255, "e"]), False,
         "1025 bytes"),
        ("/".join(["p"] * 33), False, "33 components"),
        ("x" * 256, False, "component of 256 bytes"),
    ]
    return [{"path": path, "valid": valid, "why": why} for path, valid, why in cases]


# ── Chunking (spec section 8) ────────────────────────────────────────────
def chunking_vectors():
    sizes = [0, 1, CHUNK_SIZE_BYTES - 1, CHUNK_SIZE_BYTES, CHUNK_SIZE_BYTES + 1,
             3 * CHUNK_SIZE_BYTES + 17]
    vectors = []
    for size_bytes in sizes:
        data = pattern_file(size_bytes)
        vectors.append({"size_bytes": str(size_bytes),
                        "chunk_hashes": chunk_hashes(data),
                        "file_sha256": sha256_hex(data)})
    return {"generator": "byte[i] = i mod 251", "chunk_size_bytes": CHUNK_SIZE_BYTES,
            "files": vectors}


def write_json(name, content):
    path = VECTORS_DIR / name
    path.write_text(json.dumps(content, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {path}")


def main():
    VECTORS_DIR.mkdir(parents=True, exist_ok=True)
    write_json("messages.json", {"protocol_version": PROTOCOL_VERSION,
                                 "valid": valid_vectors(),
                                 "invalid": invalid_vectors()})
    write_json("path_rules.json", {"protocol_version": PROTOCOL_VERSION,
                                   "paths": path_rule_vectors()})
    write_json("chunking.json", chunking_vectors())


if __name__ == "__main__":
    main()
