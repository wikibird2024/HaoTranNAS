//! Property tests: the decoders never panic on any input, and messages
//! survive an encode → decode round trip.

use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::codec::{decode_frame, decode_message, encode_frame};
use haotrannas_core::frame::FrameDecoder;
use haotrannas_core::limits::{MAX_NAME_BYTES, MAX_PATH_BYTES};
use haotrannas_core::message::{DirEntry, DirEntryKind, Message, MessageType};
use proptest::prelude::*;

/// Values a wire `u64` may carry (top bit clear).
fn wire_u64() -> impl Strategy<Value = u64> {
    0..=u64::MAX >> 1
}

/// Any UTF-8 text of at most `max_bytes` bytes.
fn text_up_to(max_bytes: usize) -> impl Strategy<Value = String> {
    any::<String>().prop_map(move |text| {
        let mut end = text.len().min(max_bytes);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text[..end].to_owned()
    })
}

fn chunk_hash() -> impl Strategy<Value = ChunkHash> {
    any::<[u8; 32]>().prop_map(ChunkHash)
}

fn hello() -> impl Strategy<Value = Message> {
    (
        any::<u16>(),
        text_up_to(MAX_NAME_BYTES),
        text_up_to(MAX_NAME_BYTES),
    )
        .prop_map(
            |(protocol_version, client_software, device_name)| Message::Hello {
                protocol_version,
                client_software,
                device_name,
            },
        )
}

fn file_offer() -> impl Strategy<Value = Message> {
    (
        text_up_to(MAX_PATH_BYTES),
        wire_u64(),
        any::<i64>(),
        any::<[u8; 32]>(),
        prop::collection::vec(chunk_hash(), 0..40),
    )
        .prop_map(
            |(path, size_bytes, modified_time_ms, file_sha256, chunk_hashes)| Message::FileOffer {
                path,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            },
        )
}

fn dir_entry() -> impl Strategy<Value = DirEntry> {
    (
        text_up_to(MAX_PATH_BYTES),
        prop_oneof![Just(DirEntryKind::Directory), Just(DirEntryKind::File)],
        wire_u64(),
        any::<i64>(),
        wire_u64(),
    )
        .prop_map(
            |(name, kind, size_bytes, modified_time_ms, version_id)| DirEntry {
                name,
                kind,
                size_bytes,
                modified_time_ms,
                version_id,
            },
        )
}

fn dir_entries() -> impl Strategy<Value = Message> {
    (prop::collection::vec(dir_entry(), 0..20), any::<bool>())
        .prop_map(|(entries, has_more)| Message::DirEntries { entries, has_more })
}

fn chunk_data() -> impl Strategy<Value = Message> {
    (
        wire_u64(),
        any::<u32>(),
        chunk_hash(),
        prop::collection::vec(any::<u8>(), 0..4096),
    )
        .prop_map(
            |(upload_id, chunk_index, chunk_sha256, data)| Message::ChunkData {
                upload_id,
                chunk_index,
                chunk_sha256,
                data,
            },
        )
}

/// Message type numbers to try: every known type plus 0 and random ones.
fn message_type_number() -> impl Strategy<Value = u16> {
    prop_oneof![
        prop::sample::select(
            MessageType::ALL
                .iter()
                .map(|message_type| message_type.number())
                .collect::<Vec<_>>()
        ),
        Just(0_u16),
        any::<u16>(),
    ]
}

proptest! {
    #[test]
    fn decode_message_never_panics(
        message_type in message_type_number(),
        payload in prop::collection::vec(any::<u8>(), 0..2048),
    ) {
        // Ok or Err are both fine; a panic fails the test.
        let _ = decode_message(message_type, &payload);
    }

    #[test]
    fn frame_decoder_never_panics(
        pieces in prop::collection::vec(prop::collection::vec(any::<u8>(), 0..64), 0..32),
    ) {
        let mut decoder = FrameDecoder::new();
        for piece in &pieces {
            decoder.push(piece);
            while let Some(result) = decoder.next_frame() {
                match result {
                    Ok(frame) => {
                        let _ = decode_frame(&frame);
                    }
                    Err(_) => break,
                }
            }
        }
    }

    /// Random bytes rarely start with a valid length; this one does, so the
    /// body and payload decoding paths get random input too.
    #[test]
    fn frames_with_valid_length_and_random_body_never_panic(
        length_bytes in 6_u32..300,
        message_type in message_type_number(),
        body in prop::collection::vec(any::<u8>(), 0..400),
    ) {
        let mut stream = length_bytes.to_be_bytes().to_vec();
        stream.extend_from_slice(&message_type.to_be_bytes());
        stream.extend_from_slice(&body);
        let mut decoder = FrameDecoder::new();
        decoder.push(&stream);
        while let Some(Ok(frame)) = decoder.next_frame() {
            let _ = decode_frame(&frame);
        }
    }

    #[test]
    fn generated_messages_round_trip(
        message in prop_oneof![hello(), file_offer(), dir_entries(), chunk_data()],
        request_id in any::<u32>(),
    ) {
        let bytes = encode_frame(&message, request_id).expect("in-range message encodes");
        let mut decoder = FrameDecoder::new();
        decoder.push(&bytes);
        let frame = decoder.next_frame().expect("whole frame").expect("valid frame");
        prop_assert!(decoder.next_frame().is_none());
        prop_assert_eq!(frame.header.request_id, request_id);
        prop_assert_eq!(decode_frame(&frame).expect("decodes"), message);
    }
}
