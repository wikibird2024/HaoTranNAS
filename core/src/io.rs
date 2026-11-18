//! Async frame read and write over any tokio `AsyncRead` / `AsyncWrite`
//! (plain TCP in dev mode, a TLS stream later). Enabled by the `tokio`
//! feature.
//!
//! [`read_frame`] feeds bytes into a [`FrameDecoder`] in small pieces, so the
//! length field is checked as soon as its 4 bytes arrive and nothing is ever
//! sized from an unchecked length: the decoder holds at most the current
//! frame plus one read piece ([`READ_PIECE_BYTES`]).
//!
//! Cancel-safe: if the `read_frame` future is dropped (a timeout or shutdown
//! in a `select!`), every byte already read is in the decoder, so the next
//! call carries on with the same decoder.

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::codec::encode_frame;
use crate::frame::{FrameDecoder, FrameError, RawFrame};
use crate::message::Message;
use crate::wire::EncodeError;

/// Most bytes taken from the stream in one read.
pub const READ_PIECE_BYTES: usize = 8 * 1024;

/// Why a frame could not be read or written.
#[derive(Debug, thiserror::Error)]
pub enum FrameIoError {
    /// The stream failed (reset, broken pipe, TLS error, ...).
    #[error("connection error: {0}")]
    Io(#[from] std::io::Error),
    /// The frame header is bad (length out of range); answer `MALFORMED_FRAME`.
    #[error(transparent)]
    Frame(#[from] FrameError),
    /// The stream ended in the middle of a frame; answer `MALFORMED_FRAME`.
    #[error("connection ended in the middle of a frame ({buffered_bytes} bytes of it received)")]
    EndedMidFrame {
        /// Bytes of the unfinished frame that did arrive.
        buffered_bytes: usize,
    },
    /// The message cannot be encoded (a bug in the sender).
    #[error(transparent)]
    Encode(#[from] EncodeError),
}

/// Reads the next whole frame. `Ok(None)` = the stream ended cleanly between
/// two frames. After a [`FrameIoError::Frame`] the decoder stays failed and
/// the connection must be closed.
pub async fn read_frame(
    reader: &mut (impl AsyncRead + Unpin),
    decoder: &mut FrameDecoder,
) -> Result<Option<RawFrame>, FrameIoError> {
    let mut read_piece = [0_u8; READ_PIECE_BYTES];
    loop {
        if let Some(next) = decoder.next_frame() {
            return Ok(Some(next?));
        }
        let received_bytes = reader.read(&mut read_piece).await?;
        if received_bytes == 0 {
            let buffered_bytes = decoder.buffered_len_bytes();
            return if buffered_bytes == 0 {
                Ok(None)
            } else {
                Err(FrameIoError::EndedMidFrame { buffered_bytes })
            };
        }
        decoder.push(&read_piece[..received_bytes]);
    }
}

/// Encodes `message` with `request_id`, writes the whole frame and flushes.
pub async fn write_frame(
    writer: &mut (impl AsyncWrite + Unpin),
    message: &Message,
    request_id: u32,
) -> Result<(), FrameIoError> {
    let frame_bytes = encode_frame(message, request_id)?;
    writer.write_all(&frame_bytes).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::io::AsyncWriteExt;

    use super::{FrameIoError, read_frame, write_frame};
    use crate::codec::{decode_frame, encode_frame};
    use crate::frame::{FrameDecoder, FrameError};
    use crate::limits::PROTOCOL_VERSION;
    use crate::message::Message;

    fn hello() -> Message {
        Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_software: "test/1".to_owned(),
            device_name: "phone".to_owned(),
        }
    }

    #[tokio::test]
    async fn write_then_read_round_trip() {
        let (mut client, mut server) = tokio::io::duplex(1024);
        write_frame(&mut client, &hello(), 7).await.unwrap();
        write_frame(&mut client, &Message::Ping, 8).await.unwrap();
        drop(client);

        let mut decoder = FrameDecoder::new();
        let first = read_frame(&mut server, &mut decoder)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(first.header.request_id, 7);
        assert_eq!(decode_frame(&first).unwrap(), hello());
        let second = read_frame(&mut server, &mut decoder)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(second.header.request_id, 8);
        assert_eq!(decode_frame(&second).unwrap(), Message::Ping);
        assert!(
            read_frame(&mut server, &mut decoder)
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn frame_split_into_single_bytes_is_read_whole() {
        let frame_bytes = encode_frame(&hello(), 3).unwrap();
        let (mut client, mut server) = tokio::io::duplex(16);
        let writer_task = tokio::spawn(async move {
            for byte in frame_bytes {
                client.write_all(&[byte]).await.unwrap();
                client.flush().await.unwrap();
                tokio::task::yield_now().await;
            }
        });
        let mut decoder = FrameDecoder::new();
        let frame = read_frame(&mut server, &mut decoder)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(decode_frame(&frame).unwrap(), hello());
        writer_task.await.unwrap();
    }

    #[tokio::test]
    async fn frame_larger_than_one_read_piece_is_read_whole() {
        let data = vec![0xab_u8; super::READ_PIECE_BYTES * 3 + 5];
        let message = Message::ChunkContent {
            chunk_sha256: crate::chunker::ChunkHash([1; 32]),
            data,
        };
        let frame_bytes = encode_frame(&message, 9).unwrap();
        let (mut client, mut server) = tokio::io::duplex(4096);
        let writer_task = tokio::spawn(async move {
            client.write_all(&frame_bytes).await.unwrap();
        });
        let mut decoder = FrameDecoder::new();
        let frame = read_frame(&mut server, &mut decoder)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(decode_frame(&frame).unwrap(), message);
        writer_task.await.unwrap();
    }

    /// A length over 4 MiB is refused from the 4 length bytes alone: the
    /// reader does not wait for (or make room for) the body.
    #[tokio::test]
    async fn over_limit_length_fails_without_waiting_for_the_body() {
        let (mut client, mut server) = tokio::io::duplex(64);
        client.write_all(&[0x00, 0x40, 0x00, 0x01]).await.unwrap();
        let mut decoder = FrameDecoder::new();
        let outcome = tokio::time::timeout(
            Duration::from_secs(5),
            read_frame(&mut server, &mut decoder),
        )
        .await
        .expect("read_frame must not wait for the body");
        assert!(matches!(
            outcome,
            Err(FrameIoError::Frame(FrameError::LengthOutOfRange {
                length_bytes: 4_194_305
            }))
        ));
        assert!(decoder.has_failed());
        // The client is still open: nothing else was needed.
        drop(client);
    }

    #[tokio::test]
    async fn under_limit_length_fails() {
        let (mut client, mut server) = tokio::io::duplex(64);
        client.write_all(&[0, 0, 0, 5]).await.unwrap();
        let mut decoder = FrameDecoder::new();
        assert!(matches!(
            read_frame(&mut server, &mut decoder).await,
            Err(FrameIoError::Frame(FrameError::LengthOutOfRange {
                length_bytes: 5
            }))
        ));
    }

    #[tokio::test]
    async fn end_in_the_middle_of_a_frame_is_an_error() {
        let frame_bytes = encode_frame(&hello(), 1).unwrap();
        let (mut client, mut server) = tokio::io::duplex(1024);
        client.write_all(&frame_bytes[..12]).await.unwrap();
        drop(client);
        let mut decoder = FrameDecoder::new();
        assert!(matches!(
            read_frame(&mut server, &mut decoder).await,
            Err(FrameIoError::EndedMidFrame { buffered_bytes: 12 })
        ));
    }

    #[tokio::test]
    async fn end_before_any_byte_is_clean() {
        let (client, mut server) = tokio::io::duplex(64);
        drop(client);
        let mut decoder = FrameDecoder::new();
        assert!(
            read_frame(&mut server, &mut decoder)
                .await
                .unwrap()
                .is_none()
        );
    }

    /// Dropping a pending read (as a timeout does) loses no bytes.
    #[tokio::test]
    async fn cancelled_read_keeps_the_bytes_it_got() {
        let frame_bytes = encode_frame(&Message::Ping, 4).unwrap();
        let (mut client, mut server) = tokio::io::duplex(64);
        client.write_all(&frame_bytes[..5]).await.unwrap();
        let mut decoder = FrameDecoder::new();
        let first_try = tokio::time::timeout(
            Duration::from_millis(50),
            read_frame(&mut server, &mut decoder),
        )
        .await;
        assert!(first_try.is_err(), "frame is not complete yet");
        client.write_all(&frame_bytes[5..]).await.unwrap();
        let frame = read_frame(&mut server, &mut decoder)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(frame.header.request_id, 4);
    }

    #[tokio::test]
    async fn unencodable_message_is_an_error() {
        let (mut client, _server) = tokio::io::duplex(64);
        let too_long_name = Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_software: "x".repeat(65),
            device_name: String::new(),
        };
        assert!(matches!(
            write_frame(&mut client, &too_long_name, 1).await,
            Err(FrameIoError::Encode(_))
        ));
    }
}
