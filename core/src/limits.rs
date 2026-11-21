//! Every protocol limit, timeout and size in one place.
//!
//! The protocol spec uses the same names and values. Change both together.

/// Protocol version this side speaks and sends in `Hello` (2 = v1 +
/// thumbnails, spec §16).
pub const PROTOCOL_VERSION: u16 = 2;
/// Lowest `Hello` version a server accepts; also the mDNS `v=` value, so
/// older apps still find a newer server (D-048).
pub const MIN_PROTOCOL_VERSION: u16 = 1;

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

/// Fixed part of the client's wait for `CommitOk` (spec §8, D-030).
pub const COMMIT_TIMEOUT_BASE_MS: u64 = 30_000;

/// Slowest re-hash speed a client allows for at `Commit`: the server
/// re-reads every chunk, and a busy spinning disk can be this slow.
pub const COMMIT_MIN_HASH_BYTES_PER_SECOND: u64 = 20 * 1_048_576;
/// Largest thumbnail the server stores, in bytes (spec §16).
pub const MAX_THUMBNAIL_BYTES: usize = 65_536;
/// Longest side a client should give a thumbnail, in pixels (spec §16).
pub const THUMBNAIL_MAX_SIDE_PX: u32 = 256;

/// How long a client waits for `CommitOk` for a file of `size_bytes`:
/// [`COMMIT_TIMEOUT_BASE_MS`] plus the time to re-read the file at
/// [`COMMIT_MIN_HASH_BYTES_PER_SECOND`]. A fixed timeout would make every
/// big file fail on a slow disk.
#[must_use]
pub fn commit_timeout_ms(size_bytes: u64) -> u64 {
    let rehash_ms = size_bytes.saturating_mul(1_000) / COMMIT_MIN_HASH_BYTES_PER_SECOND;
    COMMIT_TIMEOUT_BASE_MS.saturating_add(rehash_ms)
}

#[cfg(test)]
mod tests {
    use super::{
        CHUNK_SIZE_BYTES, COMMIT_TIMEOUT_BASE_MS, FRAME_HEADER_BYTES, HASH_BYTES,
        MAX_FRAME_LENGTH_BYTES, commit_timeout_ms,
    };

    /// The largest `ChunkData` frame must fit in one frame.
    ///
    /// Layout: header, upload id (u64), chunk index (u32), hash, byte count
    /// (u32), chunk bytes. The length field does not count its own 4 bytes,
    /// hence the `+ 4` on the right side.
    #[test]
    fn commit_timeout_grows_with_the_file_size() {
        assert_eq!(commit_timeout_ms(0), 30_000);
        // 20 MiB takes one more second at the slowest allowed speed.
        assert_eq!(commit_timeout_ms(20 * 1_048_576), 31_000);
        // The largest file (64 GiB) gets about 55 minutes, not 30 seconds.
        assert_eq!(commit_timeout_ms(64 * 1_073_741_824), 30_000 + 3_276_800);
        // Never overflows, even for absurd sizes.
        assert!(commit_timeout_ms(u64::MAX) > COMMIT_TIMEOUT_BASE_MS);
    }

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
