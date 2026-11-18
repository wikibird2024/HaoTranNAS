//! Big-endian primitives on a byte buffer: integers, fixed hashes,
//! length-prefixed bytes and UTF-8 strings (protocol spec section 2).
//!
//! [`Reader`] reads from a borrowed payload and never reads past its end;
//! [`Writer`] appends to a growing buffer. Message encoding (`codec`) is built
//! on these two. Neither panics: bad input gives a [`DecodeError`], a value
//! the wire format cannot carry gives an [`EncodeError`].

use crate::limits::HASH_BYTES;

/// Largest value a `u64` field may carry: the top bit must be clear so a
/// Dart signed 64-bit `int` holds it.
pub const MAX_WIRE_U64: u64 = (1 << 63) - 1;

/// Bytes that are not a valid frame or payload (the peer answers with
/// `MALFORMED_FRAME`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("malformed: {reason}")]
pub struct DecodeError {
    /// What was wrong, for logs.
    pub reason: String,
}

impl DecodeError {
    /// Makes an error with the given reason text.
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

/// A value that the wire format cannot carry (a bug in the sender).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("cannot encode: {reason}")]
pub struct EncodeError {
    /// What was out of range, for logs.
    pub reason: String,
}

impl EncodeError {
    /// Makes an error with the given reason text.
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

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

    /// Takes the next `count_bytes` bytes, or fails if fewer are left.
    fn take(&mut self, count_bytes: usize) -> Result<&'payload [u8], DecodeError> {
        let remaining_bytes = self.remaining_bytes();
        if count_bytes > remaining_bytes {
            return Err(DecodeError::new(format!(
                "payload ends early: need {count_bytes} bytes, {remaining_bytes} left"
            )));
        }
        let end = self.position_bytes + count_bytes;
        let taken = self
            .payload
            .get(self.position_bytes..end)
            .ok_or_else(|| DecodeError::new("read past the end of the payload"))?;
        self.position_bytes = end;
        Ok(taken)
    }

    /// Takes exactly `N` bytes as an array.
    fn take_array<const N: usize>(&mut self) -> Result<[u8; N], DecodeError> {
        let taken = self.take(N)?;
        let mut array = [0_u8; N];
        array.copy_from_slice(taken);
        Ok(array)
    }

    /// Reads one byte.
    pub fn read_u8(&mut self) -> Result<u8, DecodeError> {
        Ok(u8::from_be_bytes(self.take_array()?))
    }

    /// Reads a big-endian `u16`.
    pub fn read_u16(&mut self) -> Result<u16, DecodeError> {
        Ok(u16::from_be_bytes(self.take_array()?))
    }

    /// Reads a big-endian `u32`.
    pub fn read_u32(&mut self) -> Result<u32, DecodeError> {
        Ok(u32::from_be_bytes(self.take_array()?))
    }

    /// Reads a big-endian `u64`; the top bit must be clear.
    pub fn read_u64(&mut self) -> Result<u64, DecodeError> {
        let value = u64::from_be_bytes(self.take_array()?);
        if value > MAX_WIRE_U64 {
            return Err(DecodeError::new("u64 must be < 2^63"));
        }
        Ok(value)
    }

    /// Reads a big-endian two's complement `i64`.
    pub fn read_i64(&mut self) -> Result<i64, DecodeError> {
        Ok(i64::from_be_bytes(self.take_array()?))
    }

    /// Reads a bool: `0` = false, `1` = true, anything else is malformed.
    pub fn read_bool(&mut self) -> Result<bool, DecodeError> {
        match self.read_u8()? {
            0 => Ok(false),
            1 => Ok(true),
            other => Err(DecodeError::new(format!(
                "bool must be 0 or 1, got {other}"
            ))),
        }
    }

    /// Reads a raw 32-byte SHA-256 digest.
    pub fn read_hash(&mut self) -> Result<[u8; HASH_BYTES], DecodeError> {
        self.take_array()
    }

    /// Reads `bytes`: a `u32` length, then that many raw bytes.
    pub fn read_bytes(&mut self) -> Result<Vec<u8>, DecodeError> {
        let length_bytes = usize::try_from(self.read_u32()?)
            .map_err(|_| DecodeError::new("byte length does not fit in memory"))?;
        Ok(self.take(length_bytes)?.to_vec())
    }

    /// Reads `str`: a `u16` length, then strict UTF-8 of at most `max_bytes`.
    pub fn read_string(&mut self, max_bytes: usize) -> Result<String, DecodeError> {
        let length_bytes = usize::from(self.read_u16()?);
        if length_bytes > max_bytes {
            return Err(DecodeError::new(format!(
                "string of {length_bytes} bytes is over its max of {max_bytes}"
            )));
        }
        let raw = self.take(length_bytes)?;
        let text = std::str::from_utf8(raw)
            .map_err(|error| DecodeError::new(format!("string is not valid UTF-8: {error}")))?;
        Ok(text.to_owned())
    }

    /// Reads a list item count and checks that `count * min_item_bytes` fits
    /// in the bytes left, so a caller can allocate `count` items safely.
    pub fn read_list_count(&mut self, min_item_bytes: usize) -> Result<usize, DecodeError> {
        let count = self.read_u32()?;
        let count_items = usize::try_from(count)
            .map_err(|_| DecodeError::new("list count does not fit in memory"))?;
        let needed_bytes = count_items.checked_mul(min_item_bytes);
        let remaining_bytes = self.remaining_bytes();
        match needed_bytes {
            Some(needed_bytes) if needed_bytes <= remaining_bytes => Ok(count_items),
            _ => Err(DecodeError::new(format!(
                "list count {count} needs more than the {remaining_bytes} bytes left"
            ))),
        }
    }

    /// Ends reading; fails if any byte was left unread.
    pub fn finish(self) -> Result<(), DecodeError> {
        match self.remaining_bytes() {
            0 => Ok(()),
            trailing_bytes => Err(DecodeError::new(format!(
                "{trailing_bytes} bytes left after the last field"
            ))),
        }
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

    /// Starts with `prefix` already in the buffer (for example a frame header
    /// to patch later).
    pub fn with_prefix(prefix: &[u8]) -> Self {
        Self {
            buffer: prefix.to_vec(),
        }
    }

    /// Number of bytes written so far.
    pub fn len_bytes(&self) -> usize {
        self.buffer.len()
    }

    /// Gives back everything written so far.
    pub fn into_bytes(self) -> Vec<u8> {
        self.buffer
    }

    /// Writes one byte.
    pub fn write_u8(&mut self, value: u8) {
        self.buffer.push(value);
    }

    /// Writes a big-endian `u16`.
    pub fn write_u16(&mut self, value: u16) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    /// Writes a big-endian `u32`.
    pub fn write_u32(&mut self, value: u32) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    /// Writes a big-endian `u64`; fails if the top bit is set.
    pub fn write_u64(&mut self, value: u64) -> Result<(), EncodeError> {
        if value > MAX_WIRE_U64 {
            return Err(EncodeError::new(format!("u64 {value} must be < 2^63")));
        }
        self.buffer.extend_from_slice(&value.to_be_bytes());
        Ok(())
    }

    /// Writes a big-endian two's complement `i64`.
    pub fn write_i64(&mut self, value: i64) {
        self.buffer.extend_from_slice(&value.to_be_bytes());
    }

    /// Writes a bool as `0` or `1`.
    pub fn write_bool(&mut self, value: bool) {
        self.buffer.push(u8::from(value));
    }

    /// Writes a raw 32-byte digest.
    pub fn write_hash(&mut self, hash: &[u8; HASH_BYTES]) {
        self.buffer.extend_from_slice(hash);
    }

    /// Writes `bytes`: a `u32` length, then the bytes.
    pub fn write_bytes(&mut self, bytes: &[u8]) -> Result<(), EncodeError> {
        let length_bytes = u32::try_from(bytes.len()).map_err(|_| {
            EncodeError::new(format!("{} bytes do not fit a u32 length", bytes.len()))
        })?;
        self.write_u32(length_bytes);
        self.buffer.extend_from_slice(bytes);
        Ok(())
    }

    /// Writes `str`: a `u16` length, then the UTF-8 bytes; fails if longer
    /// than `max_bytes`.
    pub fn write_string(&mut self, text: &str, max_bytes: usize) -> Result<(), EncodeError> {
        let length_bytes = text.len();
        if length_bytes > max_bytes {
            return Err(EncodeError::new(format!(
                "string of {length_bytes} bytes is over its max of {max_bytes}"
            )));
        }
        let length_field = u16::try_from(length_bytes)
            .map_err(|_| EncodeError::new(format!("string of {length_bytes} bytes is too long")))?;
        self.write_u16(length_field);
        self.buffer.extend_from_slice(text.as_bytes());
        Ok(())
    }

    /// Writes a list item count.
    pub fn write_list_count(&mut self, count_items: usize) -> Result<(), EncodeError> {
        let count = u32::try_from(count_items)
            .map_err(|_| EncodeError::new(format!("list of {count_items} items is too long")))?;
        self.write_u32(count);
        Ok(())
    }

    /// Overwrites 4 bytes at `offset_bytes` with a big-endian `u32` (used to
    /// fill in a frame length once the payload is known).
    pub fn patch_u32(&mut self, offset_bytes: usize, value: u32) -> Result<(), EncodeError> {
        let end = offset_bytes
            .checked_add(4)
            .ok_or_else(|| EncodeError::new("patch offset overflows"))?;
        let target = self
            .buffer
            .get_mut(offset_bytes..end)
            .ok_or_else(|| EncodeError::new("patch offset past the end of the buffer"))?;
        target.copy_from_slice(&value.to_be_bytes());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Reader, Writer};

    #[test]
    fn integers_read_big_endian() {
        let payload = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x7f, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff,
        ];
        let mut reader = Reader::new(&payload);
        assert_eq!(reader.read_u8().unwrap(), 0x01);
        assert_eq!(reader.read_u16().unwrap(), 0x0203);
        assert_eq!(reader.read_u32().unwrap(), 0x0405_0607);
        assert_eq!(reader.read_u64().unwrap(), 0x7f00_0000_0000_ffff);
        // Only 4 bytes left: an i64 needs 8.
        assert!(reader.read_i64().is_err());
        assert_eq!(reader.remaining_bytes(), 4);
    }

    #[test]
    fn i64_reads_negative_values() {
        let payload = (-2_i64).to_be_bytes();
        let mut reader = Reader::new(&payload);
        assert_eq!(reader.read_i64().unwrap(), -2);
        reader.finish().unwrap();
    }

    #[test]
    fn u64_with_top_bit_is_rejected() {
        let payload = 0x8000_0000_0000_0000_u64.to_be_bytes();
        let error = Reader::new(&payload).read_u64().unwrap_err();
        assert_eq!(error.reason, "u64 must be < 2^63");
        let max_payload = u64::MAX.to_be_bytes();
        assert!(Reader::new(&max_payload).read_u64().is_err());
        let largest_ok = ((1_u64 << 63) - 1).to_be_bytes();
        assert_eq!(Reader::new(&largest_ok).read_u64().unwrap(), (1 << 63) - 1);
    }

    #[test]
    fn bool_two_is_rejected() {
        assert!(!Reader::new(&[0]).read_bool().unwrap());
        assert!(Reader::new(&[1]).read_bool().unwrap());
        assert!(Reader::new(&[2]).read_bool().is_err());
        assert!(Reader::new(&[0xff]).read_bool().is_err());
    }

    #[test]
    fn list_count_past_end_is_rejected() {
        // Count 2 of 4-byte items, but only 4 bytes left.
        let payload = [0, 0, 0, 2, 0, 0, 0, 1];
        assert!(Reader::new(&payload).read_list_count(4).is_err());
        // Count u32::MAX with huge items must not overflow.
        let payload = [0xff, 0xff, 0xff, 0xff];
        assert!(Reader::new(&payload).read_list_count(usize::MAX).is_err());
        // Count 1 of 4-byte items with 4 bytes left is fine.
        let payload = [0, 0, 0, 1, 0, 0, 0, 9];
        let mut reader = Reader::new(&payload);
        assert_eq!(reader.read_list_count(4).unwrap(), 1);
        assert_eq!(reader.read_u32().unwrap(), 9);
        reader.finish().unwrap();
    }

    #[test]
    fn surrogate_utf8_is_rejected() {
        let payload = [0, 3, 0xed, 0xa0, 0x80];
        assert!(Reader::new(&payload).read_string(64).is_err());
    }

    #[test]
    fn overlong_utf8_is_rejected() {
        let payload = [0, 2, 0xc0, 0xaf];
        assert!(Reader::new(&payload).read_string(64).is_err());
    }

    #[test]
    fn code_point_above_max_is_rejected() {
        // F4 90 80 80 would be U+110000.
        let payload = [0, 4, 0xf4, 0x90, 0x80, 0x80];
        assert!(Reader::new(&payload).read_string(64).is_err());
    }

    #[test]
    fn string_over_max_is_rejected_before_reading_it() {
        let payload = [0, 3, b'a', b'b', b'c'];
        assert!(Reader::new(&payload).read_string(2).is_err());
        assert_eq!(Reader::new(&payload).read_string(3).unwrap(), "abc");
    }

    #[test]
    fn string_length_past_end_is_rejected() {
        let payload = [0, 0xff, b'a', b'b', b'c'];
        assert!(Reader::new(&payload).read_string(1024).is_err());
    }

    #[test]
    fn bytes_and_hash_read_exactly() {
        let mut payload = vec![0, 0, 0, 2, 7, 8];
        payload.extend_from_slice(&[0xab; 32]);
        let mut reader = Reader::new(&payload);
        assert_eq!(reader.read_bytes().unwrap(), vec![7, 8]);
        assert_eq!(reader.read_hash().unwrap(), [0xab; 32]);
        reader.finish().unwrap();
        assert!(Reader::new(&[0; 31]).read_hash().is_err());
        assert!(Reader::new(&[0, 0, 0, 5, 1]).read_bytes().is_err());
    }

    #[test]
    fn trailing_bytes_fail_finish() {
        let reader = Reader::new(&[1]);
        assert!(reader.finish().is_err());
        assert!(Reader::new(&[]).finish().is_ok());
    }

    #[test]
    fn empty_payload_gives_errors_not_panics() {
        let mut reader = Reader::new(&[]);
        assert!(reader.read_u8().is_err());
        assert!(reader.read_u16().is_err());
        assert!(reader.read_u32().is_err());
        assert!(reader.read_u64().is_err());
        assert!(reader.read_i64().is_err());
        assert!(reader.read_bool().is_err());
        assert!(reader.read_hash().is_err());
        assert!(reader.read_bytes().is_err());
        assert!(reader.read_string(10).is_err());
        assert!(reader.read_list_count(1).is_err());
    }

    #[test]
    fn writer_rejects_out_of_range_values() {
        let mut writer = Writer::new();
        assert!(writer.write_u64(1 << 63).is_err());
        assert!(writer.write_string("abc", 2).is_err());
        assert_eq!(writer.len_bytes(), 0);
        writer.write_u64((1 << 63) - 1).unwrap();
        writer.write_string("ab", 2).unwrap();
        assert_eq!(writer.len_bytes(), 8 + 2 + 2);
    }

    #[test]
    fn writer_and_reader_agree() {
        let mut writer = Writer::new();
        writer.write_u8(9);
        writer.write_u16(0xbeef);
        writer.write_u32(0xdead_beef);
        writer.write_u64(42).unwrap();
        writer.write_i64(-42);
        writer.write_bool(true);
        writer.write_hash(&[3; 32]);
        writer.write_bytes(&[1, 2, 3]).unwrap();
        writer.write_string("Hào", 64).unwrap();
        writer.write_list_count(0).unwrap();
        let bytes = writer.into_bytes();
        let mut reader = Reader::new(&bytes);
        assert_eq!(reader.read_u8().unwrap(), 9);
        assert_eq!(reader.read_u16().unwrap(), 0xbeef);
        assert_eq!(reader.read_u32().unwrap(), 0xdead_beef);
        assert_eq!(reader.read_u64().unwrap(), 42);
        assert_eq!(reader.read_i64().unwrap(), -42);
        assert!(reader.read_bool().unwrap());
        assert_eq!(reader.read_hash().unwrap(), [3; 32]);
        assert_eq!(reader.read_bytes().unwrap(), vec![1, 2, 3]);
        assert_eq!(reader.read_string(64).unwrap(), "Hào");
        assert_eq!(reader.read_list_count(32).unwrap(), 0);
        reader.finish().unwrap();
    }
}
