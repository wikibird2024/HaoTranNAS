//! Frames on the wire: a 10-byte header (length u32 BE, message type u16 BE,
//! request id u32 BE) followed by the payload.
//!
//! [`FrameDecoder`] buffers incoming bytes and yields whole frames; it rejects
//! length fields outside `MIN_FRAME_LENGTH_BYTES ..= MAX_FRAME_LENGTH_BYTES`
//! (see [`crate::limits`]).

/// The fixed part in front of every frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    /// Size of everything after the length field (type + request id + payload).
    pub length_bytes: u32,
    /// Which message the payload holds.
    pub message_type: u16,
    /// Set by the client, copied into the reply.
    pub request_id: u32,
}

/// Turns a byte stream into whole frames.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    /// Bytes received but not yet returned as a frame.
    buffered_bytes: Vec<u8>,
}

impl FrameDecoder {
    /// Starts with an empty buffer.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of bytes waiting for the rest of their frame.
    pub fn buffered_len_bytes(&self) -> usize {
        self.buffered_bytes.len()
    }
}
