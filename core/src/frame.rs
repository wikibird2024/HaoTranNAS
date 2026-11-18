//! Frames on the wire: a 10-byte header (length u32 BE, message type u16 BE,
//! request id u32 BE) followed by the payload (protocol spec section 3).
//!
//! [`FrameDecoder`] buffers incoming bytes and yields whole frames. It checks
//! the length field as soon as its 4 bytes arrive, before waiting for the
//! body, and rejects anything outside
//! `MIN_FRAME_LENGTH_BYTES ..= MAX_FRAME_LENGTH_BYTES` (see
//! [`crate::limits`]). The message type is checked later, by the codec.

use crate::limits::{FRAME_HEADER_BYTES, MAX_FRAME_LENGTH_BYTES, MIN_FRAME_LENGTH_BYTES};

/// Size of the length field at the start of every frame.
const LENGTH_FIELD_BYTES: usize = 4;

/// A frame that cannot be read; the connection must be closed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FrameError {
    /// The length field is outside `6 ..= 4 MiB`.
    #[error(
        "malformed: frame length {length_bytes} is outside {MIN_FRAME_LENGTH_BYTES}..={MAX_FRAME_LENGTH_BYTES}"
    )]
    LengthOutOfRange {
        /// The length field as received.
        length_bytes: u32,
    },
}

/// Checks a frame length field against the spec range.
fn check_length(length_bytes: u32) -> Result<(), FrameError> {
    if (MIN_FRAME_LENGTH_BYTES..=MAX_FRAME_LENGTH_BYTES).contains(&length_bytes) {
        Ok(())
    } else {
        Err(FrameError::LengthOutOfRange { length_bytes })
    }
}

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

impl FrameHeader {
    /// The header bytes, big-endian.
    pub fn encode(&self) -> [u8; FRAME_HEADER_BYTES] {
        let mut header_bytes = [0_u8; FRAME_HEADER_BYTES];
        header_bytes[0..4].copy_from_slice(&self.length_bytes.to_be_bytes());
        header_bytes[4..6].copy_from_slice(&self.message_type.to_be_bytes());
        header_bytes[6..10].copy_from_slice(&self.request_id.to_be_bytes());
        header_bytes
    }

    /// Reads a header and checks its length field.
    pub fn decode(header_bytes: &[u8; FRAME_HEADER_BYTES]) -> Result<Self, FrameError> {
        let [
            length_0,
            length_1,
            length_2,
            length_3,
            type_0,
            type_1,
            request_0,
            request_1,
            request_2,
            request_3,
        ] = *header_bytes;
        let length_bytes = u32::from_be_bytes([length_0, length_1, length_2, length_3]);
        check_length(length_bytes)?;
        Ok(Self {
            length_bytes,
            message_type: u16::from_be_bytes([type_0, type_1]),
            request_id: u32::from_be_bytes([request_0, request_1, request_2, request_3]),
        })
    }

    /// Payload size: the length field minus message type and request id.
    pub fn payload_len_bytes(&self) -> usize {
        let after_length_bytes = FRAME_HEADER_BYTES - LENGTH_FIELD_BYTES;
        usize::try_from(self.length_bytes)
            .unwrap_or(usize::MAX)
            .saturating_sub(after_length_bytes)
    }
}

/// One whole frame: header plus its payload, not decoded yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawFrame {
    /// The header, length already checked.
    pub header: FrameHeader,
    /// Exactly `header.payload_len_bytes()` bytes.
    pub payload: Vec<u8>,
}

/// Turns a byte stream into whole frames.
///
/// Feed bytes with [`push`](Self::push), then call
/// [`next_frame`](Self::next_frame) until it gives `None`. After a
/// [`FrameError`] the decoder stays failed and drops further input.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    /// Bytes received; everything before `read_position_bytes` is used up.
    buffered_bytes: Vec<u8>,
    /// Start of the first byte not yet returned as part of a frame.
    read_position_bytes: usize,
    /// Set on the first error; then every call returns it again.
    failure: Option<FrameError>,
}

impl FrameDecoder {
    /// Starts with an empty buffer.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of bytes waiting for the rest of their frame.
    pub fn buffered_len_bytes(&self) -> usize {
        self.buffered_bytes
            .len()
            .saturating_sub(self.read_position_bytes)
    }

    /// True once a frame error was seen; the connection must be closed.
    pub fn has_failed(&self) -> bool {
        self.failure.is_some()
    }

    /// Adds received bytes. Ignored after a failure.
    pub fn push(&mut self, received_bytes: &[u8]) {
        if self.failure.is_some() {
            return;
        }
        if self.read_position_bytes > 0 {
            self.buffered_bytes.drain(..self.read_position_bytes);
            self.read_position_bytes = 0;
        }
        self.buffered_bytes.extend_from_slice(received_bytes);
    }

    /// The next whole frame, `None` if more bytes are needed, or the error
    /// that stopped the decoder. A bad length field is reported as soon as
    /// its 4 bytes are in, without waiting for the rest.
    pub fn next_frame(&mut self) -> Option<Result<RawFrame, FrameError>> {
        if let Some(failure) = &self.failure {
            return Some(Err(failure.clone()));
        }
        let unread = self.buffered_bytes.get(self.read_position_bytes..)?;
        let length_field: [u8; LENGTH_FIELD_BYTES] =
            unread.get(..LENGTH_FIELD_BYTES)?.try_into().ok()?;
        let length_bytes = u32::from_be_bytes(length_field);
        if let Err(error) = check_length(length_bytes) {
            self.failure = Some(error.clone());
            self.buffered_bytes = Vec::new();
            self.read_position_bytes = 0;
            return Some(Err(error));
        }
        let frame_bytes = LENGTH_FIELD_BYTES + usize::try_from(length_bytes).ok()?;
        let frame = unread.get(..frame_bytes)?;
        let header_bytes: [u8; FRAME_HEADER_BYTES] =
            frame.get(..FRAME_HEADER_BYTES)?.try_into().ok()?;
        let header = match FrameHeader::decode(&header_bytes) {
            Ok(header) => header,
            Err(error) => {
                self.failure = Some(error.clone());
                return Some(Err(error));
            }
        };
        let payload = frame.get(FRAME_HEADER_BYTES..)?.to_vec();
        self.read_position_bytes += frame_bytes;
        Some(Ok(RawFrame { header, payload }))
    }
}

#[cfg(test)]
mod tests {
    use super::{FrameDecoder, FrameError, FrameHeader};

    #[test]
    fn header_round_trip() {
        let header = FrameHeader {
            length_bytes: 6,
            message_type: 0x0003,
            request_id: 0xffff_ffff,
        };
        let header_bytes = header.encode();
        assert_eq!(header_bytes, [0, 0, 0, 6, 0, 3, 0xff, 0xff, 0xff, 0xff]);
        assert_eq!(FrameHeader::decode(&header_bytes).unwrap(), header);
        assert_eq!(header.payload_len_bytes(), 0);
    }

    #[test]
    fn partial_input_gives_none() {
        let mut decoder = FrameDecoder::new();
        assert!(decoder.next_frame().is_none());
        decoder.push(&[0, 0, 0, 7, 0, 3, 0, 0, 0]);
        assert!(decoder.next_frame().is_none());
        decoder.push(&[1]);
        assert!(decoder.next_frame().is_none());
        decoder.push(&[0xaa, 0, 0]);
        let frame = decoder.next_frame().unwrap().unwrap();
        assert_eq!(frame.header.request_id, 1);
        assert_eq!(frame.payload, vec![0xaa]);
        assert_eq!(decoder.buffered_len_bytes(), 2);
        assert!(decoder.next_frame().is_none());
    }

    #[test]
    fn bad_length_is_rejected_from_four_bytes_alone() {
        let mut decoder = FrameDecoder::new();
        decoder.push(&[0, 0x40, 0, 1]);
        assert_eq!(
            decoder.next_frame(),
            Some(Err(FrameError::LengthOutOfRange {
                length_bytes: 4_194_305
            }))
        );
        assert!(decoder.has_failed());
    }

    #[test]
    fn decoder_stays_failed() {
        let mut decoder = FrameDecoder::new();
        decoder.push(&[0, 0, 0, 5]);
        assert!(matches!(decoder.next_frame(), Some(Err(_))));
        decoder.push(&[0, 0, 0, 6, 0, 3, 0, 0, 0, 1]);
        assert!(matches!(decoder.next_frame(), Some(Err(_))));
        assert_eq!(decoder.buffered_len_bytes(), 0);
    }

    #[test]
    fn two_frames_in_one_push() {
        let mut decoder = FrameDecoder::new();
        decoder.push(&[0, 0, 0, 6, 0, 3, 0, 0, 0, 1, 0, 0, 0, 6, 0, 4, 0, 0, 0, 2]);
        let first = decoder.next_frame().unwrap().unwrap();
        let second = decoder.next_frame().unwrap().unwrap();
        assert_eq!(first.header.message_type, 3);
        assert_eq!(second.header.message_type, 4);
        assert!(decoder.next_frame().is_none());
        assert_eq!(decoder.buffered_len_bytes(), 0);
    }
}
