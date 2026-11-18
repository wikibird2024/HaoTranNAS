//! Big-endian primitives on a byte buffer: integers, fixed hashes,
//! length-prefixed bytes and UTF-8 strings.
//!
//! [`Reader`] reads from a borrowed payload and never reads past its end;
//! [`Writer`] appends to a growing buffer. Message encoding (`codec`) is built
//! on these two.

/// Reads primitives from a payload, front to back.
#[derive(Debug)]
pub struct Reader<'payload> {
    /// The bytes being read.
    payload: &'payload [u8],
    /// Index of the next unread byte in `payload`.
    position_bytes: usize,
}

impl<'payload> Reader<'payload> {
    /// Starts reading at the first byte of `payload`.
    pub fn new(payload: &'payload [u8]) -> Self {
        Self {
            payload,
            position_bytes: 0,
        }
    }

    /// Number of bytes not read yet.
    pub fn remaining_bytes(&self) -> usize {
        self.payload.len().saturating_sub(self.position_bytes)
    }
}

/// Appends primitives to a byte buffer.
#[derive(Debug, Default)]
pub struct Writer {
    /// Everything written so far.
    buffer: Vec<u8>,
}

impl Writer {
    /// Starts an empty buffer.
    pub fn new() -> Self {
        Self::default()
    }

    /// Gives back everything written so far.
    pub fn into_bytes(self) -> Vec<u8> {
        self.buffer
    }
}
