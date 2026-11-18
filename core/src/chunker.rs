//! Cuts a file into `CHUNK_SIZE_BYTES` chunks and names each by its SHA-256
//! hash (see [`crate::limits`]).

use crate::limits::HASH_BYTES;

/// The SHA-256 hash of one chunk's bytes; it is the chunk's name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChunkHash(pub [u8; HASH_BYTES]);
