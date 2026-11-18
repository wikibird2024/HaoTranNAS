//! Golden vectors: fixed bytes from `protocol/vectors/` (made by the Python
//! reference encoder from the spec) that the Rust codec must decode to the
//! same fields and encode to the same bytes. The Dart codec runs the same
//! files.

use std::path::PathBuf;

use haotrannas_core::chunker::{ChunkHash, chunk_reader};
use haotrannas_core::codec::{decode_frame, encode_frame};
use haotrannas_core::frame::{FrameDecoder, RawFrame};
use haotrannas_core::message::{DeviceEntry, DirEntry, DirEntryKind, Message};
use haotrannas_core::path_rules::validate_path;
use serde_json::Value;

const EXPECTED_VALID_COUNT: usize = 38;
const EXPECTED_INVALID_COUNT: usize = 18;
const EXPECTED_PATH_COUNT: usize = 20;
const EXPECTED_CHUNKING_FILE_COUNT: usize = 6;

fn load_vectors(file_name: &str) -> Value {
    let path: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "..",
        "protocol",
        "vectors",
        file_name,
    ]
    .iter()
    .collect();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("parse {file_name}: {error}"))
}

fn frame_bytes(vector: &Value) -> Vec<u8> {
    let segments = vector["frame_hex"].as_array().expect("frame_hex is a list");
    let joined: String = segments
        .iter()
        .map(|segment| segment.as_str().expect("hex segment is a string"))
        .collect();
    hex::decode(joined).expect("frame_hex is hex")
}

// ── JSON field → Rust value (spec section 15: JSON encoding) ─────────────

fn field<'json>(fields: &'json Value, name: &str) -> &'json Value {
    fields
        .get(name)
        .unwrap_or_else(|| panic!("missing field {name} in {fields}"))
}

fn json_u8(fields: &Value, name: &str) -> u8 {
    u8::try_from(field(fields, name).as_u64().expect("u8 is a number")).expect("u8 range")
}

fn json_u16(fields: &Value, name: &str) -> u16 {
    u16::try_from(field(fields, name).as_u64().expect("u16 is a number")).expect("u16 range")
}

fn json_u32(fields: &Value, name: &str) -> u32 {
    u32::try_from(field(fields, name).as_u64().expect("u32 is a number")).expect("u32 range")
}

fn json_u64(fields: &Value, name: &str) -> u64 {
    field(fields, name)
        .as_str()
        .expect("u64 is a decimal string")
        .parse()
        .expect("u64 parses")
}

fn json_i64(fields: &Value, name: &str) -> i64 {
    field(fields, name)
        .as_str()
        .expect("i64 is a decimal string")
        .parse()
        .expect("i64 parses")
}

fn json_bool(fields: &Value, name: &str) -> bool {
    field(fields, name).as_bool().expect("bool")
}

fn json_string(fields: &Value, name: &str) -> String {
    field(fields, name).as_str().expect("str").to_owned()
}

fn json_bytes(fields: &Value, name: &str) -> Vec<u8> {
    hex::decode(field(fields, name).as_str().expect("bytes are hex")).expect("hex")
}

fn hash_from_hex(text: &str) -> [u8; 32] {
    ChunkHash::from_hex(text).expect("hash is 64 hex chars").0
}

fn json_hash(fields: &Value, name: &str) -> [u8; 32] {
    hash_from_hex(field(fields, name).as_str().expect("hash is hex"))
}

fn json_chunk_hash(fields: &Value, name: &str) -> ChunkHash {
    ChunkHash(json_hash(fields, name))
}

fn json_list<'json>(fields: &'json Value, name: &str) -> &'json Vec<Value> {
    field(fields, name).as_array().expect("list")
}

fn json_chunk_hashes(fields: &Value, name: &str) -> Vec<ChunkHash> {
    json_list(fields, name)
        .iter()
        .map(|item| ChunkHash(hash_from_hex(item.as_str().expect("hash is hex"))))
        .collect()
}

/// Builds the expected [`Message`] from a vector's `message` and `fields`.
#[allow(clippy::too_many_lines, reason = "one match arm per spec message")]
fn message_from_json(message_name: &str, fields: &Value) -> Message {
    match message_name {
        "Hello" => Message::Hello {
            protocol_version: json_u16(fields, "protocol_version"),
            client_software: json_string(fields, "client_software"),
            device_name: json_string(fields, "device_name"),
        },
        "HelloOk" => Message::HelloOk {
            protocol_version: json_u16(fields, "protocol_version"),
            server_software: json_string(fields, "server_software"),
            server_name: json_string(fields, "server_name"),
            device_id: json_u64(fields, "device_id"),
            chunk_size_bytes: json_u32(fields, "chunk_size_bytes"),
            max_frame_length_bytes: json_u32(fields, "max_frame_length_bytes"),
        },
        "Ping" => Message::Ping,
        "Pong" => Message::Pong,
        "PairRequest" => Message::PairRequest {
            code: json_string(fields, "code"),
        },
        "PairOk" => Message::PairOk {
            device_id: json_u64(fields, "device_id"),
            device_cert_der: json_bytes(fields, "device_cert_der"),
            device_key_pkcs8_der: json_bytes(fields, "device_key_pkcs8_der"),
            server_cert_sha256: json_hash(fields, "server_cert_sha256"),
        },
        "FileOffer" => Message::FileOffer {
            path: json_string(fields, "path"),
            size_bytes: json_u64(fields, "size_bytes"),
            modified_time_ms: json_i64(fields, "modified_time_ms"),
            file_sha256: json_hash(fields, "file_sha256"),
            chunk_hashes: json_chunk_hashes(fields, "chunk_hashes"),
        },
        "NeedChunks" => Message::NeedChunks {
            upload_id: json_u64(fields, "upload_id"),
            existing_version_id: json_u64(fields, "existing_version_id"),
            missing_indexes: json_list(fields, "missing_indexes")
                .iter()
                .map(|item| u32::try_from(item.as_u64().expect("u32")).expect("u32 range"))
                .collect(),
        },
        "ChunkData" => Message::ChunkData {
            upload_id: json_u64(fields, "upload_id"),
            chunk_index: json_u32(fields, "chunk_index"),
            chunk_sha256: json_chunk_hash(fields, "chunk_sha256"),
            data: json_bytes(fields, "data"),
        },
        "ChunkOk" => Message::ChunkOk {
            chunk_index: json_u32(fields, "chunk_index"),
            chunk_sha256: json_chunk_hash(fields, "chunk_sha256"),
        },
        "Commit" => Message::Commit {
            upload_id: json_u64(fields, "upload_id"),
        },
        "CommitOk" => Message::CommitOk {
            version_id: json_u64(fields, "version_id"),
        },
        "ListDevices" => Message::ListDevices,
        "DeviceList" => Message::DeviceList {
            devices: json_list(fields, "devices")
                .iter()
                .map(|item| DeviceEntry {
                    device_id: json_u64(item, "device_id"),
                    name: json_string(item, "name"),
                    paired_at_ms: json_i64(item, "paired_at_ms"),
                    is_caller: json_bool(item, "is_caller"),
                })
                .collect(),
        },
        "ListDir" => Message::ListDir {
            device_id: json_u64(fields, "device_id"),
            path: json_string(fields, "path"),
            start_after: json_string(fields, "start_after"),
            max_entries: json_u32(fields, "max_entries"),
        },
        "DirEntries" => Message::DirEntries {
            entries: json_list(fields, "entries")
                .iter()
                .map(|item| DirEntry {
                    name: json_string(item, "name"),
                    kind: DirEntryKind::from_number(json_u8(item, "kind")).expect("kind 1 or 2"),
                    size_bytes: json_u64(item, "size_bytes"),
                    modified_time_ms: json_i64(item, "modified_time_ms"),
                    version_id: json_u64(item, "version_id"),
                })
                .collect(),
            has_more: json_bool(fields, "has_more"),
        },
        "ReadFile" => Message::ReadFile {
            device_id: json_u64(fields, "device_id"),
            path: json_string(fields, "path"),
            version_id: json_u64(fields, "version_id"),
        },
        "FileManifest" => Message::FileManifest {
            version_id: json_u64(fields, "version_id"),
            size_bytes: json_u64(fields, "size_bytes"),
            modified_time_ms: json_i64(fields, "modified_time_ms"),
            file_sha256: json_hash(fields, "file_sha256"),
            chunk_hashes: json_chunk_hashes(fields, "chunk_hashes"),
        },
        "ReadChunk" => Message::ReadChunk {
            chunk_sha256: json_chunk_hash(fields, "chunk_sha256"),
        },
        "ChunkContent" => Message::ChunkContent {
            chunk_sha256: json_chunk_hash(fields, "chunk_sha256"),
            data: json_bytes(fields, "data"),
        },
        "Close" => Message::Close {
            reason: json_u16(fields, "reason"),
            message: json_string(fields, "message"),
        },
        "Error" => Message::Error {
            code: json_u16(fields, "code"),
            message: json_string(fields, "message"),
        },
        other => panic!("unknown message name {other} in vectors"),
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

fn valid_vectors() -> Vec<Value> {
    load_vectors("messages.json")["valid"]
        .as_array()
        .expect("valid is a list")
        .clone()
}

fn json_request_id(vector: &Value) -> u32 {
    u32::try_from(vector["request_id"].as_u64().expect("request_id")).expect("u32 range")
}

/// Feeds `bytes` into a fresh decoder in one piece and returns its frames.
fn decode_all_frames(bytes: &[u8]) -> Vec<RawFrame> {
    let mut decoder = FrameDecoder::new();
    decoder.push(bytes);
    let mut frames = Vec::new();
    while let Some(result) = decoder.next_frame() {
        frames.push(result.expect("valid frame"));
    }
    assert_eq!(
        decoder.buffered_len_bytes(),
        0,
        "bytes left after the frames"
    );
    frames
}

#[test]
fn valid_vectors_decode_and_encode_exactly() {
    let vectors = valid_vectors();
    let mut checked_count = 0;
    for vector in &vectors {
        let name = vector["name"].as_str().expect("name");
        let expected_bytes = frame_bytes(vector);
        let expected_message = message_from_json(
            vector["message"].as_str().expect("message"),
            &vector["fields"],
        );
        let request_id = json_request_id(vector);

        let frames = decode_all_frames(&expected_bytes);
        assert_eq!(frames.len(), 1, "{name}: one frame");
        let frame = &frames[0];
        assert_eq!(frame.header.request_id, request_id, "{name}: request_id");
        assert_eq!(
            frame.header.message_type,
            expected_message.message_type().number(),
            "{name}: message type"
        );
        let decoded = decode_frame(frame).unwrap_or_else(|error| panic!("{name}: {error}"));
        assert_eq!(decoded, expected_message, "{name}: decoded fields");

        let encoded = encode_frame(&expected_message, request_id)
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        assert!(encoded == expected_bytes, "{name}: encoded bytes differ");
        checked_count += 1;
    }
    eprintln!("golden vectors: {checked_count} valid frames decoded and re-encoded exactly");
    assert_eq!(checked_count, EXPECTED_VALID_COUNT);
}

#[test]
fn invalid_vectors_are_rejected() {
    let messages = load_vectors("messages.json");
    let vectors = messages["invalid"].as_array().expect("invalid is a list");
    let mut header_count = 0;
    let mut payload_count = 0;
    for vector in vectors {
        let name = vector["name"].as_str().expect("name");
        assert_eq!(vector["expect_error"], "MALFORMED_FRAME", "{name}");
        let bytes = frame_bytes(vector);
        let mut decoder = FrameDecoder::new();
        decoder.push(&bytes);
        let frame_result = decoder.next_frame();
        match vector["stage"].as_str().expect("stage") {
            "header" => {
                match frame_result {
                    Some(Err(error)) => eprintln!("  rejected {name}: {error}"),
                    other => panic!("{name}: FrameDecoder must reject the header, got {other:?}"),
                }
                header_count += 1;
            }
            "payload" => {
                match frame_result {
                    Some(Ok(frame)) => match decode_frame(&frame) {
                        Err(error) => eprintln!("  rejected {name}: {error}"),
                        Ok(message) => panic!("{name}: decoded a malformed payload: {message:?}"),
                    },
                    Some(Err(error)) => eprintln!("  rejected {name} at the frame: {error}"),
                    None => panic!("{name}: frame is incomplete, expected a whole frame"),
                }
                payload_count += 1;
            }
            other => panic!("{name}: unknown stage {other}"),
        }
    }
    eprintln!(
        "golden vectors: {} invalid frames rejected ({header_count} at the header, {payload_count} in the payload)",
        header_count + payload_count
    );
    assert_eq!(header_count + payload_count, EXPECTED_INVALID_COUNT);
}

/// Tiny fixed-seed generator (64-bit LCG, Knuth's constants) so the split
/// points are the same on every run and in every language.
struct SimpleLcg {
    state: u64,
}

impl SimpleLcg {
    fn next_piece_size_bytes(&mut self) -> usize {
        self.state = self
            .state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let top_bits = self.state >> 33;
        usize::try_from(top_bits % 97).expect("small") + 1
    }
}

#[test]
fn valid_frames_split_in_random_pieces_decode_in_order() {
    let vectors = valid_vectors();
    let mut stream = Vec::new();
    let mut expected = Vec::new();
    for vector in &vectors {
        stream.extend_from_slice(&frame_bytes(vector));
        expected.push((
            json_request_id(vector),
            message_from_json(
                vector["message"].as_str().expect("message"),
                &vector["fields"],
            ),
        ));
    }

    let mut generator = SimpleLcg { state: 20_261_118 };
    let mut decoder = FrameDecoder::new();
    let mut decoded_messages = Vec::new();
    let mut position_bytes = 0;
    let mut piece_count = 0;
    while position_bytes < stream.len() {
        let piece_size_bytes = generator
            .next_piece_size_bytes()
            .min(stream.len() - position_bytes);
        decoder.push(&stream[position_bytes..position_bytes + piece_size_bytes]);
        position_bytes += piece_size_bytes;
        piece_count += 1;
        while let Some(result) = decoder.next_frame() {
            let frame = result.expect("valid frame");
            let message = decode_frame(&frame).expect("valid payload");
            decoded_messages.push((frame.header.request_id, message));
        }
    }
    assert_eq!(decoder.buffered_len_bytes(), 0);
    assert_eq!(decoded_messages.len(), expected.len());
    assert!(
        decoded_messages == expected,
        "split stream decoded differently"
    );
    eprintln!(
        "golden vectors: {} frames ({} bytes) fed in {piece_count} pieces of 1..=97 bytes",
        decoded_messages.len(),
        stream.len()
    );
}

#[test]
fn path_rule_vectors_match() {
    let vectors = load_vectors("path_rules.json");
    let paths = vectors["paths"].as_array().expect("paths is a list");
    for entry in paths {
        let path = entry["path"].as_str().expect("path");
        let is_valid = entry["valid"].as_bool().expect("valid");
        let result = validate_path(path);
        assert_eq!(
            result.is_ok(),
            is_valid,
            "{}: {result:?}",
            entry["why"].as_str().unwrap_or_default()
        );
    }
    eprintln!("golden vectors: {} paths checked", paths.len());
    assert_eq!(paths.len(), EXPECTED_PATH_COUNT);
}

#[test]
fn chunking_vectors_match() {
    let vectors = load_vectors("chunking.json");
    assert_eq!(vectors["chunk_size_bytes"], 1_048_576);
    let files = vectors["files"].as_array().expect("files is a list");
    for file in files {
        let size_bytes = json_u64(file, "size_bytes");
        let file_bytes: Vec<u8> = (0..size_bytes)
            .map(|index| u8::try_from(index % 251).expect("below 251"))
            .collect();
        let chunk_list = chunk_reader(file_bytes.as_slice()).expect("read from memory");
        assert_eq!(chunk_list.size_bytes, size_bytes);
        assert_eq!(
            chunk_list.chunk_hashes,
            json_chunk_hashes(file, "chunk_hashes"),
            "size {size_bytes}: chunk hashes"
        );
        assert_eq!(
            chunk_list.file_sha256,
            json_hash(file, "file_sha256"),
            "size {size_bytes}: file_sha256"
        );
    }
    eprintln!("golden vectors: {} chunking files checked", files.len());
    assert_eq!(files.len(), EXPECTED_CHUNKING_FILE_COUNT);
}
