//! Every protocol message as one Rust enum, plus its message type number
//! (protocol spec section 5).
//!
//! The spec is the source of truth for the message list and fields; field
//! names here are exactly the spec's. `Close` and `Error` keep their reason
//! and code as raw `u16` so a number from a newer peer survives decoding (see
//! [`crate::error_code`]).

use std::fmt;

use crate::chunker::ChunkHash;
use crate::limits::HASH_BYTES;

/// Message type numbers (spec section 5). A request type is odd and its
/// reply is request + 1; `Close` and `Error` are the exceptions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u16)]
pub enum MessageType {
    /// C→S, opens a connection.
    Hello = 0x0001,
    /// S→C, reply to `Hello`.
    HelloOk = 0x0002,
    /// C→S, keepalive.
    Ping = 0x0003,
    /// S→C, reply to `Ping`.
    Pong = 0x0004,
    /// C→S, pairing code.
    PairRequest = 0x0101,
    /// S→C, the new device certificate and key.
    PairOk = 0x0102,
    /// C→S, a file to back up.
    FileOffer = 0x0201,
    /// S→C, which chunks to send.
    NeedChunks = 0x0202,
    /// C→S, one chunk.
    ChunkData = 0x0203,
    /// S→C, chunk stored.
    ChunkOk = 0x0204,
    /// C→S, finish an upload.
    Commit = 0x0205,
    /// S→C, the new version.
    CommitOk = 0x0206,
    /// C→S, list paired devices.
    ListDevices = 0x0301,
    /// S→C, the paired devices.
    DeviceList = 0x0302,
    /// C→S, list a directory.
    ListDir = 0x0303,
    /// S→C, one page of directory entries.
    DirEntries = 0x0304,
    /// C→S, ask for a file's manifest.
    ReadFile = 0x0401,
    /// S→C, a file version's chunk list.
    FileManifest = 0x0402,
    /// C→S, ask for one chunk.
    ReadChunk = 0x0403,
    /// S→C, one chunk's bytes.
    ChunkContent = 0x0404,
    /// C→S, a thumbnail for a backed-up file (v2, spec §16).
    PutThumbnail = 0x0501,
    /// S→C, thumbnail stored (v2).
    ThumbnailOk = 0x0502,
    /// C→S, ask for a file's thumbnail (v2).
    ReadThumbnail = 0x0503,
    /// S→C, the thumbnail's JPEG bytes (v2).
    Thumbnail = 0x0504,
    /// Either side, ends the connection; gets no reply.
    Close = 0x00F0,
    /// S→C, a request failed.
    Error = 0x00FF,
}

impl MessageType {
    /// Every message type, in spec table order.
    pub const ALL: [Self; 26] = [
        Self::Hello,
        Self::HelloOk,
        Self::Ping,
        Self::Pong,
        Self::PairRequest,
        Self::PairOk,
        Self::FileOffer,
        Self::NeedChunks,
        Self::ChunkData,
        Self::ChunkOk,
        Self::Commit,
        Self::CommitOk,
        Self::ListDevices,
        Self::DeviceList,
        Self::ListDir,
        Self::DirEntries,
        Self::ReadFile,
        Self::FileManifest,
        Self::ReadChunk,
        Self::ChunkContent,
        Self::PutThumbnail,
        Self::ThumbnailOk,
        Self::ReadThumbnail,
        Self::Thumbnail,
        Self::Close,
        Self::Error,
    ];

    /// The number sent in the frame header.
    pub const fn number(self) -> u16 {
        self as u16
    }

    /// The type for `number`, or `None` for 0 and unknown numbers.
    pub fn from_number(number: u16) -> Option<Self> {
        Self::ALL.into_iter().find(|known| known.number() == number)
    }

    /// True for a client request that gets exactly one reply (odd types,
    /// except `Error`; `Close` gets no reply).
    pub const fn is_request(self) -> bool {
        self.number() % 2 == 1 && !matches!(self, Self::Error)
    }

    /// The reply type of a request (request + 1), `None` for anything else.
    pub fn reply_type(self) -> Option<Self> {
        if self.is_request() {
            Self::from_number(self.number() + 1)
        } else {
            None
        }
    }

    /// The spec name, for example `HelloOk`.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Hello => "Hello",
            Self::HelloOk => "HelloOk",
            Self::Ping => "Ping",
            Self::Pong => "Pong",
            Self::PairRequest => "PairRequest",
            Self::PairOk => "PairOk",
            Self::FileOffer => "FileOffer",
            Self::NeedChunks => "NeedChunks",
            Self::ChunkData => "ChunkData",
            Self::ChunkOk => "ChunkOk",
            Self::Commit => "Commit",
            Self::CommitOk => "CommitOk",
            Self::ListDevices => "ListDevices",
            Self::DeviceList => "DeviceList",
            Self::ListDir => "ListDir",
            Self::DirEntries => "DirEntries",
            Self::ReadFile => "ReadFile",
            Self::FileManifest => "FileManifest",
            Self::ReadChunk => "ReadChunk",
            Self::ChunkContent => "ChunkContent",
            Self::PutThumbnail => "PutThumbnail",
            Self::ThumbnailOk => "ThumbnailOk",
            Self::ReadThumbnail => "ReadThumbnail",
            Self::Thumbnail => "Thumbnail",
            Self::Close => "Close",
            Self::Error => "Error",
        }
    }
}

/// One paired device in `DeviceList`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceEntry {
    /// The device's id.
    pub device_id: u64,
    /// The name it sent in `Hello` when it paired.
    pub name: String,
    /// When it paired, Unix time in milliseconds.
    pub paired_at_ms: i64,
    /// True for the device asking.
    pub is_caller: bool,
}

/// Whether a `DirEntry` is a directory or a file (wire `u8`; other values
/// are malformed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum DirEntryKind {
    /// Implied by file paths below it.
    Directory = 1,
    /// A backed-up file.
    File = 2,
}

impl DirEntryKind {
    /// The number sent on the wire.
    pub const fn number(self) -> u8 {
        self as u8
    }

    /// The kind for `number`, or `None` for anything but 1 and 2.
    pub const fn from_number(number: u8) -> Option<Self> {
        match number {
            1 => Some(Self::Directory),
            2 => Some(Self::File),
            _ => None,
        }
    }
}

/// One child of a directory in `DirEntries`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    /// The child's name (one path component).
    pub name: String,
    /// Directory or file.
    pub kind: DirEntryKind,
    /// File size; 0 for a directory.
    pub size_bytes: u64,
    /// File modified time, Unix ms; 0 for a directory.
    pub modified_time_ms: i64,
    /// Latest version of the file; 0 for a directory.
    pub version_id: u64,
}

/// One decoded protocol message. Field names are the spec's.
#[derive(Clone, PartialEq, Eq)]
pub enum Message {
    /// Opens a connection.
    Hello {
        /// Must be [`crate::limits::PROTOCOL_VERSION`].
        protocol_version: u16,
        /// For example `haotrannas-cli/0.1.0`.
        client_software: String,
        /// Human name of the device.
        device_name: String,
    },
    /// Reply to `Hello`.
    HelloOk {
        /// The server's protocol version.
        protocol_version: u16,
        /// For example `haotrannas-server/0.1.0`.
        server_software: String,
        /// Human name of the server.
        server_name: String,
        /// The caller's device id; 0 = not paired on this connection.
        device_id: u64,
        /// Chunk size the server uses.
        chunk_size_bytes: u32,
        /// Largest frame length the server accepts.
        max_frame_length_bytes: u32,
    },
    /// Keepalive from the client.
    Ping,
    /// Reply to `Ping`.
    Pong,
    /// Pairing code typed by the user.
    PairRequest {
        /// 6 ASCII digits.
        code: String,
    },
    /// Pairing done: the new device identity. Debug output hides the key.
    PairOk {
        /// The new device's id.
        device_id: u64,
        /// Device certificate, DER.
        device_cert_der: Vec<u8>,
        /// Device private key, PKCS#8 DER. Never log it.
        device_key_pkcs8_der: Vec<u8>,
        /// SHA-256 of the server certificate DER.
        server_cert_sha256: [u8; HASH_BYTES],
    },
    /// A file to back up.
    FileOffer {
        /// Backup path (spec section 10).
        path: String,
        /// File size.
        size_bytes: u64,
        /// File modified time, Unix ms.
        modified_time_ms: i64,
        /// SHA-256 of the whole file.
        file_sha256: [u8; HASH_BYTES],
        /// Hash of each chunk, in order.
        chunk_hashes: Vec<ChunkHash>,
    },
    /// Which chunks of an offered file to send.
    NeedChunks {
        /// The new upload; 0 when already backed up.
        upload_id: u64,
        /// Non-zero when the file is already backed up as this version.
        existing_version_id: u64,
        /// Chunk indexes to send, ascending.
        missing_indexes: Vec<u32>,
    },
    /// One chunk of an upload.
    ChunkData {
        /// From `NeedChunks`.
        upload_id: u64,
        /// Index of the chunk in the file.
        chunk_index: u32,
        /// SHA-256 of `data`.
        chunk_sha256: ChunkHash,
        /// The chunk's bytes.
        data: Vec<u8>,
    },
    /// Chunk stored.
    ChunkOk {
        /// Index from `ChunkData`.
        chunk_index: u32,
        /// Hash from `ChunkData`.
        chunk_sha256: ChunkHash,
    },
    /// Finish an upload.
    Commit {
        /// From `NeedChunks`.
        upload_id: u64,
    },
    /// Upload committed.
    CommitOk {
        /// The new version.
        version_id: u64,
    },
    /// List paired devices.
    ListDevices,
    /// The paired devices.
    DeviceList {
        /// One entry per device.
        devices: Vec<DeviceEntry>,
    },
    /// List one directory.
    ListDir {
        /// 0 = the caller.
        device_id: u64,
        /// "" = root.
        path: String,
        /// Only names after this one; "" = from the start.
        start_after: String,
        /// 1 ..= 1000.
        max_entries: u32,
    },
    /// One page of a directory.
    DirEntries {
        /// Children sorted by name, byte-wise.
        entries: Vec<DirEntry>,
        /// True if more entries follow this page.
        has_more: bool,
    },
    /// Ask for a file's chunk list.
    ReadFile {
        /// 0 = the caller.
        device_id: u64,
        /// Backup path.
        path: String,
        /// 0 = latest.
        version_id: u64,
    },
    /// A file version's chunk list.
    FileManifest {
        /// The version described.
        version_id: u64,
        /// File size.
        size_bytes: u64,
        /// File modified time, Unix ms.
        modified_time_ms: i64,
        /// SHA-256 of the whole file.
        file_sha256: [u8; HASH_BYTES],
        /// Hash of each chunk, in order.
        chunk_hashes: Vec<ChunkHash>,
    },
    /// Ask for one chunk.
    ReadChunk {
        /// The chunk's hash.
        chunk_sha256: ChunkHash,
    },
    /// One chunk's bytes.
    ChunkContent {
        /// The chunk's hash.
        chunk_sha256: ChunkHash,
        /// The chunk's bytes.
        data: Vec<u8>,
    },
    /// A thumbnail for a file the caller has backed up (v2).
    PutThumbnail {
        /// The backed-up file's SHA-256.
        file_sha256: [u8; HASH_BYTES],
        /// JPEG bytes, at most [`crate::limits::MAX_THUMBNAIL_BYTES`].
        jpeg_data: Vec<u8>,
    },
    /// Thumbnail stored (v2).
    ThumbnailOk,
    /// Ask for a file's thumbnail (v2).
    ReadThumbnail {
        /// 0 = the caller.
        device_id: u64,
        /// Backup path.
        path: String,
        /// 0 = latest.
        version_id: u64,
    },
    /// The thumbnail's JPEG bytes (v2).
    Thumbnail {
        /// JPEG bytes.
        jpeg_data: Vec<u8>,
    },
    /// Ends the connection; gets no reply.
    Close {
        /// Raw reason number, see [`crate::error_code::CloseReason`].
        reason: u16,
        /// Free text for people.
        message: String,
    },
    /// A request failed.
    Error {
        /// Raw code number, see [`crate::error_code::ErrorCode`].
        code: u16,
        /// Free text for people.
        message: String,
    },
}

impl Message {
    /// This message's type.
    pub const fn message_type(&self) -> MessageType {
        match self {
            Self::Hello { .. } => MessageType::Hello,
            Self::HelloOk { .. } => MessageType::HelloOk,
            Self::Ping => MessageType::Ping,
            Self::Pong => MessageType::Pong,
            Self::PairRequest { .. } => MessageType::PairRequest,
            Self::PairOk { .. } => MessageType::PairOk,
            Self::FileOffer { .. } => MessageType::FileOffer,
            Self::NeedChunks { .. } => MessageType::NeedChunks,
            Self::ChunkData { .. } => MessageType::ChunkData,
            Self::ChunkOk { .. } => MessageType::ChunkOk,
            Self::Commit { .. } => MessageType::Commit,
            Self::CommitOk { .. } => MessageType::CommitOk,
            Self::ListDevices => MessageType::ListDevices,
            Self::DeviceList { .. } => MessageType::DeviceList,
            Self::ListDir { .. } => MessageType::ListDir,
            Self::DirEntries { .. } => MessageType::DirEntries,
            Self::ReadFile { .. } => MessageType::ReadFile,
            Self::FileManifest { .. } => MessageType::FileManifest,
            Self::ReadChunk { .. } => MessageType::ReadChunk,
            Self::ChunkContent { .. } => MessageType::ChunkContent,
            Self::PutThumbnail { .. } => MessageType::PutThumbnail,
            Self::ThumbnailOk => MessageType::ThumbnailOk,
            Self::ReadThumbnail { .. } => MessageType::ReadThumbnail,
            Self::Thumbnail { .. } => MessageType::Thumbnail,
            Self::Close { .. } => MessageType::Close,
            Self::Error { .. } => MessageType::Error,
        }
    }

    /// True for a client request that gets exactly one reply.
    pub const fn is_request(&self) -> bool {
        self.message_type().is_request()
    }
}

/// Shown instead of the device key in Debug output (spec section 7).
const REDACTED_KEY: &str = "<key redacted>";

/// Writes `Name { field: value, .. }` for the listed fields.
macro_rules! debug_fields {
    ($formatter:expr, $name:literal $(, $field:ident)*) => {
        $formatter
            .debug_struct($name)
            $(.field(stringify!($field), $field))*
            .finish()
    };
}

/// Hand-written so that `PairOk` never prints the device key; every other
/// variant prints like a derived Debug.
impl fmt::Debug for Message {
    #[allow(clippy::too_many_lines, reason = "one match arm per spec message")]
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Hello {
                protocol_version,
                client_software,
                device_name,
            } => debug_fields!(
                formatter,
                "Hello",
                protocol_version,
                client_software,
                device_name
            ),
            Self::HelloOk {
                protocol_version,
                server_software,
                server_name,
                device_id,
                chunk_size_bytes,
                max_frame_length_bytes,
            } => debug_fields!(
                formatter,
                "HelloOk",
                protocol_version,
                server_software,
                server_name,
                device_id,
                chunk_size_bytes,
                max_frame_length_bytes
            ),
            Self::Ping => formatter.write_str("Ping"),
            Self::Pong => formatter.write_str("Pong"),
            Self::PairRequest { code } => debug_fields!(formatter, "PairRequest", code),
            Self::PairOk {
                device_id,
                device_cert_der,
                device_key_pkcs8_der: _,
                server_cert_sha256,
            } => formatter
                .debug_struct("PairOk")
                .field("device_id", device_id)
                .field("device_cert_der", device_cert_der)
                .field("device_key_pkcs8_der", &format_args!("{REDACTED_KEY}"))
                .field("server_cert_sha256", server_cert_sha256)
                .finish(),
            Self::FileOffer {
                path,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            } => debug_fields!(
                formatter,
                "FileOffer",
                path,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes
            ),
            Self::NeedChunks {
                upload_id,
                existing_version_id,
                missing_indexes,
            } => debug_fields!(
                formatter,
                "NeedChunks",
                upload_id,
                existing_version_id,
                missing_indexes
            ),
            Self::ChunkData {
                upload_id,
                chunk_index,
                chunk_sha256,
                data,
            } => debug_fields!(
                formatter,
                "ChunkData",
                upload_id,
                chunk_index,
                chunk_sha256,
                data
            ),
            Self::ChunkOk {
                chunk_index,
                chunk_sha256,
            } => debug_fields!(formatter, "ChunkOk", chunk_index, chunk_sha256),
            Self::Commit { upload_id } => debug_fields!(formatter, "Commit", upload_id),
            Self::CommitOk { version_id } => debug_fields!(formatter, "CommitOk", version_id),
            Self::ListDevices => formatter.write_str("ListDevices"),
            Self::DeviceList { devices } => debug_fields!(formatter, "DeviceList", devices),
            Self::ListDir {
                device_id,
                path,
                start_after,
                max_entries,
            } => debug_fields!(
                formatter,
                "ListDir",
                device_id,
                path,
                start_after,
                max_entries
            ),
            Self::DirEntries { entries, has_more } => {
                debug_fields!(formatter, "DirEntries", entries, has_more)
            }
            Self::ReadFile {
                device_id,
                path,
                version_id,
            } => debug_fields!(formatter, "ReadFile", device_id, path, version_id),
            Self::FileManifest {
                version_id,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            } => debug_fields!(
                formatter,
                "FileManifest",
                version_id,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes
            ),
            Self::ReadChunk { chunk_sha256 } => debug_fields!(formatter, "ReadChunk", chunk_sha256),
            Self::ChunkContent { chunk_sha256, data } => {
                debug_fields!(formatter, "ChunkContent", chunk_sha256, data)
            }
            Self::PutThumbnail {
                file_sha256,
                jpeg_data,
            } => debug_fields!(formatter, "PutThumbnail", file_sha256, jpeg_data),
            Self::ThumbnailOk => formatter.write_str("ThumbnailOk"),
            Self::ReadThumbnail {
                device_id,
                path,
                version_id,
            } => debug_fields!(formatter, "ReadThumbnail", device_id, path, version_id),
            Self::Thumbnail { jpeg_data } => debug_fields!(formatter, "Thumbnail", jpeg_data),
            Self::Close { reason, message } => debug_fields!(formatter, "Close", reason, message),
            Self::Error { code, message } => debug_fields!(formatter, "Error", code, message),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Message, MessageType};

    #[test]
    fn pair_ok_debug_hides_the_key() {
        let key_bytes = vec![0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0xde, 0xad, 0xbe, 0xef];
        let message = Message::PairOk {
            device_id: 7,
            device_cert_der: vec![0x30, 0x82],
            device_key_pkcs8_der: key_bytes.clone(),
            server_cert_sha256: [0x11; 32],
        };
        let debug_text = format!("{message:?}");
        let pretty_text = format!("{message:#?}");
        for text in [&debug_text, &pretty_text] {
            assert!(text.contains("<key redacted>"), "{text}");
            assert!(text.contains("device_key_pkcs8_der"), "{text}");
            assert!(!text.contains(&format!("{key_bytes:?}")), "{text}");
            // 222 = 0xde, a byte only the key holds.
            assert!(!text.contains("222"), "{text}");
            assert!(!text.contains("dead"), "{text}");
        }
    }

    #[test]
    fn other_variants_print_their_fields() {
        let message = Message::Close {
            reason: 5,
            message: "bye".to_owned(),
        };
        assert_eq!(
            format!("{message:?}"),
            r#"Close { reason: 5, message: "bye" }"#
        );
        assert_eq!(format!("{:?}", Message::Ping), "Ping");
    }

    #[test]
    fn requests_are_odd_and_replies_follow() {
        let requests: Vec<MessageType> = MessageType::ALL
            .into_iter()
            .filter(|message_type| message_type.is_request())
            .collect();
        assert_eq!(requests.len(), 12);
        for request in requests {
            let reply = request.reply_type().unwrap();
            assert_eq!(reply.number(), request.number() + 1);
            assert!(!reply.is_request());
        }
        assert!(!MessageType::Close.is_request());
        assert!(!MessageType::Error.is_request());
        assert_eq!(MessageType::Error.reply_type(), None);
        assert_eq!(MessageType::from_number(0), None);
        assert_eq!(MessageType::from_number(0x0999), None);
        assert_eq!(MessageType::from_number(0x00FF), Some(MessageType::Error));
        assert!(Message::Ping.is_request());
        assert!(!Message::Pong.is_request());
    }
}
