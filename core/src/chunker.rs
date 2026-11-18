//! Cuts a file into `CHUNK_SIZE_BYTES` chunks and names each by its SHA-256
//! hash (protocol spec section 8, see [`crate::limits`]).
//!
//! [`chunk_reader`] streams a file one chunk at a time, so memory use stays at
//! one chunk however big the file is.

use std::fmt;
use std::io::{self, Read};

use sha2::{Digest, Sha256};

use crate::limits::{CHUNK_SIZE_BYTES, HASH_BYTES};

/// The SHA-256 hash of one chunk's bytes; it is the chunk's name.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChunkHash(pub [u8; HASH_BYTES]);

impl ChunkHash {
    /// Hashes `chunk_bytes`.
    pub fn of_bytes(chunk_bytes: &[u8]) -> Self {
        Self(hash_bytes(chunk_bytes))
    }

    /// Lowercase hex, 64 characters.
    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    /// Parses 64 hex characters (either case).
    pub fn from_hex(text: &str) -> Result<Self, hex::FromHexError> {
        let mut hash = [0_u8; HASH_BYTES];
        hex::decode_to_slice(text, &mut hash)?;
        Ok(Self(hash))
    }
}

impl fmt::Debug for ChunkHash {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ChunkHash({})", self.to_hex())
    }
}

impl fmt::Display for ChunkHash {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.to_hex())
    }
}

/// SHA-256 of `bytes`.
pub fn hash_bytes(bytes: &[u8]) -> [u8; HASH_BYTES] {
    Sha256::digest(bytes).into()
}

/// Number of chunks a file of `size_bytes` has: `ceil(size / 1 MiB)`; a
/// 0-byte file has 0 chunks.
pub fn expected_chunk_count(size_bytes: u64) -> u64 {
    size_bytes.div_ceil(u64::from(CHUNK_SIZE_BYTES))
}

/// Size of chunk `chunk_index` in a file of `size_bytes`: 1 MiB, except the
/// last chunk which holds the rest. `None` if the file has no such chunk.
pub fn expected_chunk_size_bytes(size_bytes: u64, chunk_index: u32) -> Option<u32> {
    if u64::from(chunk_index) >= expected_chunk_count(size_bytes) {
        return None;
    }
    let start_bytes = u64::from(chunk_index) * u64::from(CHUNK_SIZE_BYTES);
    let rest_bytes = size_bytes - start_bytes;
    let chunk_size_bytes = rest_bytes.min(u64::from(CHUNK_SIZE_BYTES));
    u32::try_from(chunk_size_bytes).ok()
}

/// What a whole file looks like as chunks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChunkList {
    /// Total file size.
    pub size_bytes: u64,
    /// Hash of each chunk, in file order.
    pub chunk_hashes: Vec<ChunkHash>,
    /// SHA-256 of the whole file.
    pub file_sha256: [u8; HASH_BYTES],
}

/// Reads `source` to its end one chunk at a time and returns its chunk
/// hashes and whole-file hash, both computed in the same pass.
pub fn chunk_reader(mut source: impl Read) -> io::Result<ChunkList> {
    let chunk_capacity_bytes = usize::try_from(CHUNK_SIZE_BYTES)
        .map_err(|_| io::Error::other("chunk size does not fit in memory"))?;
    let mut chunk_buffer = vec![0_u8; chunk_capacity_bytes];
    let mut file_hasher = Sha256::new();
    let mut chunk_hashes = Vec::new();
    let mut size_bytes: u64 = 0;
    loop {
        let filled_bytes = fill_buffer(&mut source, &mut chunk_buffer)?;
        if filled_bytes == 0 {
            break;
        }
        let chunk_bytes = &chunk_buffer[..filled_bytes];
        file_hasher.update(chunk_bytes);
        chunk_hashes.push(ChunkHash::of_bytes(chunk_bytes));
        size_bytes += filled_bytes as u64;
        if filled_bytes < chunk_capacity_bytes {
            break;
        }
    }
    Ok(ChunkList {
        size_bytes,
        chunk_hashes,
        file_sha256: file_hasher.finalize().into(),
    })
}

/// Reads until `buffer` is full or the source ends; returns the bytes read.
fn fill_buffer(source: &mut impl Read, buffer: &mut [u8]) -> io::Result<usize> {
    let mut filled_bytes = 0;
    while let Some(free_space) = buffer.get_mut(filled_bytes..) {
        if free_space.is_empty() {
            break;
        }
        match source.read(free_space) {
            Ok(0) => break,
            Ok(read_bytes) => filled_bytes += read_bytes,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(filled_bytes)
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    use super::{
        ChunkHash, chunk_reader, expected_chunk_count, expected_chunk_size_bytes, hash_bytes,
    };
    use crate::limits::CHUNK_SIZE_BYTES;

    /// One chunk (1 MiB) as a `u64`, to build file sizes.
    const MIB: u64 = 1 << 20;

    #[test]
    fn chunk_count_rounds_up() {
        assert_eq!(expected_chunk_count(0), 0);
        assert_eq!(expected_chunk_count(1), 1);
        assert_eq!(expected_chunk_count(MIB), 1);
        assert_eq!(expected_chunk_count(MIB + 1), 2);
        assert_eq!(expected_chunk_count(64 * 1024 * MIB), 65_536);
    }

    #[test]
    fn chunk_sizes_are_full_except_the_last() {
        assert_eq!(expected_chunk_size_bytes(0, 0), None);
        assert_eq!(expected_chunk_size_bytes(5, 0), Some(5));
        assert_eq!(expected_chunk_size_bytes(5, 1), None);
        assert_eq!(MIB, u64::from(CHUNK_SIZE_BYTES));
        assert_eq!(expected_chunk_size_bytes(MIB, 0), Some(CHUNK_SIZE_BYTES));
        assert_eq!(
            expected_chunk_size_bytes(3 * MIB + 17, 2),
            Some(CHUNK_SIZE_BYTES)
        );
        assert_eq!(expected_chunk_size_bytes(3 * MIB + 17, 3), Some(17));
        assert_eq!(expected_chunk_size_bytes(3 * MIB + 17, 4), None);
        assert_eq!(
            expected_chunk_size_bytes(u64::MAX, u32::MAX),
            Some(CHUNK_SIZE_BYTES)
        );
    }

    #[test]
    fn hex_round_trip() {
        let hash = ChunkHash(hash_bytes(b"hello"));
        let text = hash.to_hex();
        assert_eq!(
            text,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
        assert_eq!(ChunkHash::from_hex(&text).unwrap(), hash);
        assert_eq!(ChunkHash::from_hex(&text.to_uppercase()).unwrap(), hash);
        assert!(ChunkHash::from_hex("abcd").is_err());
        assert!(ChunkHash::from_hex(&"zz".repeat(32)).is_err());
    }

    /// A reader that hands out at most 7 bytes per call, to prove chunks do
    /// not depend on how the source splits its reads.
    struct TrickleReader {
        file_bytes: Vec<u8>,
        position_bytes: usize,
    }

    impl Read for TrickleReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let rest = &self.file_bytes[self.position_bytes..];
            let count_bytes = buffer.len().min(7).min(rest.len());
            buffer[..count_bytes].copy_from_slice(&rest[..count_bytes]);
            self.position_bytes += count_bytes;
            Ok(count_bytes)
        }
    }

    #[test]
    fn short_reads_give_the_same_chunks() {
        let file_bytes: Vec<u8> = (0..(MIB + 3))
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect();
        let whole = chunk_reader(file_bytes.as_slice()).unwrap();
        let trickle = chunk_reader(TrickleReader {
            file_bytes: file_bytes.clone(),
            position_bytes: 0,
        })
        .unwrap();
        assert_eq!(whole, trickle);
        assert_eq!(whole.size_bytes, MIB + 3);
        assert_eq!(whole.chunk_hashes.len(), 2);
        assert_eq!(whole.file_sha256, hash_bytes(&file_bytes));
    }
}
