//! Frames ⇄ messages: encodes a [`Message`] into a frame with [`Writer`] and
//! decodes a payload back with [`Reader`], checking every field against the
//! protocol spec (sections 2–5) and [`crate::limits`].
//!
//! Decoding never panics: bad input gives a [`DecodeError`] (the peer then
//! answers `MALFORMED_FRAME`). The codec checks the wire format only; value
//! rules such as path rules or chunk counts belong to the server.

use crate::chunker::ChunkHash;
use crate::frame::{FrameHeader, RawFrame};
use crate::limits::{
    HASH_BYTES, MAX_FRAME_LENGTH_BYTES, MAX_MESSAGE_BYTES, MAX_NAME_BYTES, MAX_PATH_BYTES,
};
use crate::message::{DeviceEntry, DirEntry, DirEntryKind, Message, MessageType};
use crate::wire::{DecodeError, EncodeError, Reader, Writer};

/// Smallest encoded `u32` list item.
const U32_ITEM_BYTES: usize = 4;
/// Smallest encoded `DeviceEntry`: u64 + empty str + i64 + bool.
const DEVICE_ENTRY_MIN_BYTES: usize = 8 + 2 + 8 + 1;
/// Smallest encoded `DirEntry`: empty str + u8 + u64 + i64 + u64.
const DIR_ENTRY_MIN_BYTES: usize = 2 + 1 + 8 + 8 + 8;

/// Encodes `message` as a whole frame (header + payload) with `request_id`.
/// Fails if a value is out of range (u64 ≥ 2^63, string over its max) or the
/// frame would be over `MAX_FRAME_LENGTH_BYTES`.
pub fn encode_frame(message: &Message, request_id: u32) -> Result<Vec<u8>, EncodeError> {
    let placeholder_header = FrameHeader {
        length_bytes: 0,
        message_type: message.message_type().number(),
        request_id,
    };
    let mut writer = Writer::with_prefix(&placeholder_header.encode());
    write_payload(&mut writer, message)?;
    let after_length_bytes = writer.len_bytes() - 4;
    let length_bytes = u32::try_from(after_length_bytes)
        .ok()
        .filter(|length_bytes| *length_bytes <= MAX_FRAME_LENGTH_BYTES)
        .ok_or_else(|| {
            EncodeError::new(format!(
                "frame length {after_length_bytes} is over {MAX_FRAME_LENGTH_BYTES}"
            ))
        })?;
    writer.patch_u32(0, length_bytes)?;
    Ok(writer.into_bytes())
}

/// Encodes only the payload of `message` (no frame header).
pub fn encode_payload(message: &Message) -> Result<Vec<u8>, EncodeError> {
    let mut writer = Writer::new();
    write_payload(&mut writer, message)?;
    Ok(writer.into_bytes())
}

/// Decodes the payload of a frame whose header says `message_type`. Type 0,
/// unknown types, bad fields, missing bytes and trailing bytes all fail.
pub fn decode_message(message_type: u16, payload: &[u8]) -> Result<Message, DecodeError> {
    let known_type = MessageType::from_number(message_type)
        .ok_or_else(|| DecodeError::new(format!("unknown message type 0x{message_type:04x}")))?;
    let mut reader = Reader::new(payload);
    let message = read_payload(&mut reader, known_type)?;
    reader.finish()?;
    Ok(message)
}

/// Decodes the payload of a frame from [`crate::frame::FrameDecoder`].
pub fn decode_frame(frame: &RawFrame) -> Result<Message, DecodeError> {
    decode_message(frame.header.message_type, &frame.payload)
}

fn write_chunk_hashes(writer: &mut Writer, chunk_hashes: &[ChunkHash]) -> Result<(), EncodeError> {
    writer.write_list_count(chunk_hashes.len())?;
    for chunk_hash in chunk_hashes {
        writer.write_hash(&chunk_hash.0);
    }
    Ok(())
}

fn read_chunk_hashes(reader: &mut Reader<'_>) -> Result<Vec<ChunkHash>, DecodeError> {
    let count_items = reader.read_list_count(HASH_BYTES)?;
    let mut chunk_hashes = Vec::with_capacity(count_items);
    for _ in 0..count_items {
        chunk_hashes.push(ChunkHash(reader.read_hash()?));
    }
    Ok(chunk_hashes)
}

#[allow(clippy::too_many_lines, reason = "one match arm per spec message")]
fn write_payload(writer: &mut Writer, message: &Message) -> Result<(), EncodeError> {
    match message {
        Message::Hello {
            protocol_version,
            client_software,
            device_name,
        } => {
            writer.write_u16(*protocol_version);
            writer.write_string(client_software, MAX_NAME_BYTES)?;
            writer.write_string(device_name, MAX_NAME_BYTES)?;
        }
        Message::HelloOk {
            protocol_version,
            server_software,
            server_name,
            device_id,
            chunk_size_bytes,
            max_frame_length_bytes,
        } => {
            writer.write_u16(*protocol_version);
            writer.write_string(server_software, MAX_NAME_BYTES)?;
            writer.write_string(server_name, MAX_NAME_BYTES)?;
            writer.write_u64(*device_id)?;
            writer.write_u32(*chunk_size_bytes);
            writer.write_u32(*max_frame_length_bytes);
        }
        Message::Ping | Message::Pong | Message::ListDevices | Message::ThumbnailOk => {}
        Message::PairRequest { code } => writer.write_string(code, MAX_NAME_BYTES)?,
        Message::PairOk {
            device_id,
            device_cert_der,
            device_key_pkcs8_der,
            server_cert_sha256,
        } => {
            writer.write_u64(*device_id)?;
            writer.write_bytes(device_cert_der)?;
            writer.write_bytes(device_key_pkcs8_der)?;
            writer.write_hash(server_cert_sha256);
        }
        Message::FileOffer {
            path,
            size_bytes,
            modified_time_ms,
            file_sha256,
            chunk_hashes,
        } => {
            writer.write_string(path, MAX_PATH_BYTES)?;
            writer.write_u64(*size_bytes)?;
            writer.write_i64(*modified_time_ms);
            writer.write_hash(file_sha256);
            write_chunk_hashes(writer, chunk_hashes)?;
        }
        Message::NeedChunks {
            upload_id,
            existing_version_id,
            missing_indexes,
        } => {
            writer.write_u64(*upload_id)?;
            writer.write_u64(*existing_version_id)?;
            writer.write_list_count(missing_indexes.len())?;
            for missing_index in missing_indexes {
                writer.write_u32(*missing_index);
            }
        }
        Message::ChunkData {
            upload_id,
            chunk_index,
            chunk_sha256,
            data,
        } => {
            writer.write_u64(*upload_id)?;
            writer.write_u32(*chunk_index);
            writer.write_hash(&chunk_sha256.0);
            writer.write_bytes(data)?;
        }
        Message::ChunkOk {
            chunk_index,
            chunk_sha256,
        } => {
            writer.write_u32(*chunk_index);
            writer.write_hash(&chunk_sha256.0);
        }
        Message::Commit { upload_id } => writer.write_u64(*upload_id)?,
        Message::CommitOk { version_id } => writer.write_u64(*version_id)?,
        Message::DeviceList { devices } => {
            writer.write_list_count(devices.len())?;
            for device in devices {
                writer.write_u64(device.device_id)?;
                writer.write_string(&device.name, MAX_NAME_BYTES)?;
                writer.write_i64(device.paired_at_ms);
                writer.write_bool(device.is_caller);
            }
        }
        Message::ListDir {
            device_id,
            path,
            start_after,
            max_entries,
        } => {
            writer.write_u64(*device_id)?;
            writer.write_string(path, MAX_PATH_BYTES)?;
            writer.write_string(start_after, MAX_PATH_BYTES)?;
            writer.write_u32(*max_entries);
        }
        Message::DirEntries { entries, has_more } => {
            writer.write_list_count(entries.len())?;
            for entry in entries {
                writer.write_string(&entry.name, MAX_PATH_BYTES)?;
                writer.write_u8(entry.kind.number());
                writer.write_u64(entry.size_bytes)?;
                writer.write_i64(entry.modified_time_ms);
                writer.write_u64(entry.version_id)?;
            }
            writer.write_bool(*has_more);
        }
        Message::ReadFile {
            device_id,
            path,
            version_id,
        }
        | Message::ReadThumbnail {
            device_id,
            path,
            version_id,
        } => {
            writer.write_u64(*device_id)?;
            writer.write_string(path, MAX_PATH_BYTES)?;
            writer.write_u64(*version_id)?;
        }
        Message::FileManifest {
            version_id,
            size_bytes,
            modified_time_ms,
            file_sha256,
            chunk_hashes,
        } => {
            writer.write_u64(*version_id)?;
            writer.write_u64(*size_bytes)?;
            writer.write_i64(*modified_time_ms);
            writer.write_hash(file_sha256);
            write_chunk_hashes(writer, chunk_hashes)?;
        }
        Message::ReadChunk { chunk_sha256 } => writer.write_hash(&chunk_sha256.0),
        Message::ChunkContent { chunk_sha256, data } => {
            writer.write_hash(&chunk_sha256.0);
            writer.write_bytes(data)?;
        }
        Message::PutThumbnail {
            file_sha256,
            jpeg_data,
        } => {
            writer.write_hash(file_sha256);
            writer.write_bytes(jpeg_data)?;
        }
        Message::Thumbnail { jpeg_data } => writer.write_bytes(jpeg_data)?,
        Message::Close { reason, message } => {
            writer.write_u16(*reason);
            writer.write_string(message, MAX_MESSAGE_BYTES)?;
        }
        Message::Error { code, message } => {
            writer.write_u16(*code);
            writer.write_string(message, MAX_MESSAGE_BYTES)?;
        }
    }
    Ok(())
}

#[allow(clippy::too_many_lines, reason = "one match arm per spec message")]
fn read_payload(
    reader: &mut Reader<'_>,
    message_type: MessageType,
) -> Result<Message, DecodeError> {
    let message = match message_type {
        MessageType::Hello => Message::Hello {
            protocol_version: reader.read_u16()?,
            client_software: reader.read_string(MAX_NAME_BYTES)?,
            device_name: reader.read_string(MAX_NAME_BYTES)?,
        },
        MessageType::HelloOk => Message::HelloOk {
            protocol_version: reader.read_u16()?,
            server_software: reader.read_string(MAX_NAME_BYTES)?,
            server_name: reader.read_string(MAX_NAME_BYTES)?,
            device_id: reader.read_u64()?,
            chunk_size_bytes: reader.read_u32()?,
            max_frame_length_bytes: reader.read_u32()?,
        },
        MessageType::Ping => Message::Ping,
        MessageType::Pong => Message::Pong,
        MessageType::PairRequest => Message::PairRequest {
            code: reader.read_string(MAX_NAME_BYTES)?,
        },
        MessageType::PairOk => Message::PairOk {
            device_id: reader.read_u64()?,
            device_cert_der: reader.read_bytes()?,
            device_key_pkcs8_der: reader.read_bytes()?,
            server_cert_sha256: reader.read_hash()?,
        },
        MessageType::FileOffer => Message::FileOffer {
            path: reader.read_string(MAX_PATH_BYTES)?,
            size_bytes: reader.read_u64()?,
            modified_time_ms: reader.read_i64()?,
            file_sha256: reader.read_hash()?,
            chunk_hashes: read_chunk_hashes(reader)?,
        },
        MessageType::NeedChunks => {
            let upload_id = reader.read_u64()?;
            let existing_version_id = reader.read_u64()?;
            let count_items = reader.read_list_count(U32_ITEM_BYTES)?;
            let mut missing_indexes = Vec::with_capacity(count_items);
            for _ in 0..count_items {
                missing_indexes.push(reader.read_u32()?);
            }
            Message::NeedChunks {
                upload_id,
                existing_version_id,
                missing_indexes,
            }
        }
        MessageType::ChunkData => Message::ChunkData {
            upload_id: reader.read_u64()?,
            chunk_index: reader.read_u32()?,
            chunk_sha256: ChunkHash(reader.read_hash()?),
            data: reader.read_bytes()?,
        },
        MessageType::ChunkOk => Message::ChunkOk {
            chunk_index: reader.read_u32()?,
            chunk_sha256: ChunkHash(reader.read_hash()?),
        },
        MessageType::Commit => Message::Commit {
            upload_id: reader.read_u64()?,
        },
        MessageType::CommitOk => Message::CommitOk {
            version_id: reader.read_u64()?,
        },
        MessageType::ListDevices => Message::ListDevices,
        MessageType::DeviceList => {
            let count_items = reader.read_list_count(DEVICE_ENTRY_MIN_BYTES)?;
            let mut devices = Vec::with_capacity(count_items);
            for _ in 0..count_items {
                devices.push(DeviceEntry {
                    device_id: reader.read_u64()?,
                    name: reader.read_string(MAX_NAME_BYTES)?,
                    paired_at_ms: reader.read_i64()?,
                    is_caller: reader.read_bool()?,
                });
            }
            Message::DeviceList { devices }
        }
        MessageType::ListDir => Message::ListDir {
            device_id: reader.read_u64()?,
            path: reader.read_string(MAX_PATH_BYTES)?,
            start_after: reader.read_string(MAX_PATH_BYTES)?,
            max_entries: reader.read_u32()?,
        },
        MessageType::DirEntries => {
            let count_items = reader.read_list_count(DIR_ENTRY_MIN_BYTES)?;
            let mut entries = Vec::with_capacity(count_items);
            for _ in 0..count_items {
                let name = reader.read_string(MAX_PATH_BYTES)?;
                let kind_number = reader.read_u8()?;
                let kind = DirEntryKind::from_number(kind_number).ok_or_else(|| {
                    DecodeError::new(format!("kind must be 1 or 2, got {kind_number}"))
                })?;
                entries.push(DirEntry {
                    name,
                    kind,
                    size_bytes: reader.read_u64()?,
                    modified_time_ms: reader.read_i64()?,
                    version_id: reader.read_u64()?,
                });
            }
            Message::DirEntries {
                entries,
                has_more: reader.read_bool()?,
            }
        }
        MessageType::ReadFile => Message::ReadFile {
            device_id: reader.read_u64()?,
            path: reader.read_string(MAX_PATH_BYTES)?,
            version_id: reader.read_u64()?,
        },
        MessageType::FileManifest => Message::FileManifest {
            version_id: reader.read_u64()?,
            size_bytes: reader.read_u64()?,
            modified_time_ms: reader.read_i64()?,
            file_sha256: reader.read_hash()?,
            chunk_hashes: read_chunk_hashes(reader)?,
        },
        MessageType::ReadChunk => Message::ReadChunk {
            chunk_sha256: ChunkHash(reader.read_hash()?),
        },
        MessageType::ChunkContent => Message::ChunkContent {
            chunk_sha256: ChunkHash(reader.read_hash()?),
            data: reader.read_bytes()?,
        },
        MessageType::PutThumbnail => Message::PutThumbnail {
            file_sha256: reader.read_hash()?,
            jpeg_data: reader.read_bytes()?,
        },
        MessageType::ThumbnailOk => Message::ThumbnailOk,
        MessageType::ReadThumbnail => Message::ReadThumbnail {
            device_id: reader.read_u64()?,
            path: reader.read_string(MAX_PATH_BYTES)?,
            version_id: reader.read_u64()?,
        },
        MessageType::Thumbnail => Message::Thumbnail {
            jpeg_data: reader.read_bytes()?,
        },
        MessageType::Close => Message::Close {
            reason: reader.read_u16()?,
            message: reader.read_string(MAX_MESSAGE_BYTES)?,
        },
        MessageType::Error => Message::Error {
            code: reader.read_u16()?,
            message: reader.read_string(MAX_MESSAGE_BYTES)?,
        },
    };
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::{decode_message, encode_frame, encode_payload};
    use crate::message::Message;

    #[test]
    fn ping_frame_bytes() {
        let frame = encode_frame(&Message::Ping, 2).unwrap();
        assert_eq!(frame, vec![0, 0, 0, 6, 0, 3, 0, 0, 0, 2]);
        assert_eq!(decode_message(3, &[]).unwrap(), Message::Ping);
    }

    #[test]
    fn type_zero_and_unknown_are_rejected() {
        assert!(decode_message(0, &[]).is_err());
        assert!(decode_message(0x0999, &[]).is_err());
    }

    #[test]
    fn too_long_string_is_not_encoded() {
        let message = Message::PairRequest {
            code: "1".repeat(65),
        };
        assert!(encode_frame(&message, 1).is_err());
        assert!(encode_payload(&message).is_err());
    }

    #[test]
    fn u64_top_bit_is_not_encoded() {
        let message = Message::CommitOk {
            version_id: 1 << 63,
        };
        assert!(encode_frame(&message, 1).is_err());
    }

    #[test]
    fn frame_over_max_is_not_encoded() {
        let message = Message::ChunkContent {
            chunk_sha256: crate::chunker::ChunkHash([0; 32]),
            data: vec![0; 4_194_304],
        };
        assert!(encode_frame(&message, 1).is_err());
    }

    #[test]
    fn largest_chunk_data_frame_is_encoded() {
        let message = Message::ChunkData {
            upload_id: 1,
            chunk_index: 0,
            chunk_sha256: crate::chunker::ChunkHash([0; 32]),
            data: vec![0; 1_048_576],
        };
        let frame = encode_frame(&message, 1).unwrap();
        assert_eq!(frame.len(), 1_048_634);
    }
}
