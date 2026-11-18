//! Every protocol limit, timeout and size in one place.
//!
//! The protocol spec uses the same names and values. Change both together.

/// Protocol version sent in `Hello`; a peer with another version is refused.
pub const PROTOCOL_VERSION: u16 = 1;

/// Frame header size: length (u32) + message type (u16) + request id (u32).
pub const FRAME_HEADER_BYTES: usize = 10;

/// Smallest valid frame length field: message type + request id, empty payload.
pub const MIN_FRAME_LENGTH_BYTES: u32 = 6;

/// Largest valid frame length field (4 MiB); anything bigger closes the connection.
pub const MAX_FRAME_LENGTH_BYTES: u32 = 4_194_304;

/// Size of one chunk (1 MiB); only the last chunk of a file may be smaller.
pub const CHUNK_SIZE_BYTES: u32 = 1_048_576;

/// Most chunks one file may have (64 GiB at 1 MiB chunks).
pub const MAX_CHUNKS_PER_FILE: u32 = 65_536;

/// Size of a SHA-256 hash (chunk hashes and certificate fingerprints).
pub const HASH_BYTES: usize = 32;

/// Longest backup path, in UTF-8 bytes.
pub const MAX_PATH_BYTES: usize = 1024;

/// Most `/`-separated components in a backup path.
pub const MAX_PATH_COMPONENTS: usize = 32;

/// Longest name (device name, one path component), in UTF-8 bytes.
pub const MAX_NAME_BYTES: usize = 64;

/// Longest free-text message (for example in `Error` or `Close`), in UTF-8 bytes.
pub const MAX_MESSAGE_BYTES: usize = 1024;

/// Most entries the server returns in one `DirEntries` reply.
pub const MAX_LIST_DIR_ENTRIES: u32 = 1000;

/// Number of digits in a pairing code.
pub const PAIRING_CODE_DIGITS: usize = 6;

/// Time a new connection has to finish `Hello` before the server closes it.
pub const HANDSHAKE_TIMEOUT_MS: u64 = 10_000;

/// Time without any frame before the connection is closed.
pub const IDLE_TIMEOUT_MS: u64 = 60_000;

/// How often an idle client sends `Ping`.
pub const PING_INTERVAL_MS: u64 = 20_000;

/// How long a pairing code stays valid after the server prints it.
pub const PAIRING_CODE_TTL_MS: u64 = 120_000;

/// Wrong pairing codes allowed on one connection before it is closed.
pub const MAX_PAIR_FAILURES_PER_CONNECTION: u32 = 3;

/// Wrong pairing codes allowed server-wide within one pairing code's lifetime.
pub const MAX_PAIR_FAILURES_PER_WINDOW: u32 = 10;

/// Time a client waits for a TCP connect before giving up.
pub const CONNECT_TIMEOUT_MS: u64 = 3_000;

#[cfg(test)]
mod tests {
    use super::{CHUNK_SIZE_BYTES, FRAME_HEADER_BYTES, HASH_BYTES, MAX_FRAME_LENGTH_BYTES};

    /// The largest `ChunkData` frame must fit in one frame.
    ///
    /// Layout: header, upload id (u64), chunk index (u32), hash, byte count
    /// (u32), chunk bytes. The length field does not count its own 4 bytes,
    /// hence the `+ 4` on the right side.
    #[test]
    fn largest_chunk_data_frame_fits_in_one_frame() {
        let upload_id_bytes = 8;
        let chunk_index_bytes = 4;
        let byte_count_bytes = 4;
        let largest_chunk_data_frame_bytes = FRAME_HEADER_BYTES
            + upload_id_bytes
            + chunk_index_bytes
            + HASH_BYTES
            + byte_count_bytes
            + usize::try_from(CHUNK_SIZE_BYTES).expect("chunk size fits in usize");
        let max_frame_bytes =
            usize::try_from(MAX_FRAME_LENGTH_BYTES).expect("frame length fits in usize") + 4;
        assert!(
            largest_chunk_data_frame_bytes <= max_frame_bytes,
            "{largest_chunk_data_frame_bytes} > {max_frame_bytes}"
        );
    }
}
