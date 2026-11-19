//! One task per connection: reads frames, drives the core session state
//! machine, enforces the handshake and idle timeouts, passes requests to the
//! handlers and writes replies in order (protocol spec sections 3 and 6).
//!
//! ```text
//!  accept ──► AwaitingHello ──Hello ok──► Ready / Unpaired ──► ... ──► end
//!               │ no Hello in handshake timeout → Close HANDSHAKE_TIMEOUT
//!               │ no frame in idle timeout      → Close IDLE_TIMEOUT
//!               │ server stopping               → Close SERVER_SHUTDOWN
//!               │ bad frame / payload           → Error MALFORMED_FRAME, end
//!               │ message not allowed           → Error UNEXPECTED_MESSAGE / NOT_PAIRED, end
//!               │ PairRequest ok (Unpaired)     → PairOk, Close PAIRED_RECONNECT, end
//!               └ client Close or end of stream → end quietly
//! ```
//!
//! Generic over the stream, so plain TCP (dev mode), TLS and
//! `tokio::io::duplex` (tests) all run the same code. Timeouts use
//! `tokio::time`, so tests can pause the clock. The handshake timeout counts
//! from accept, so a slow TLS handshake uses up the same 10 s.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use haotrannas_core::codec::decode_frame;
use haotrannas_core::error_code::{CloseReason, ErrorCode};
use haotrannas_core::frame::{FrameDecoder, RawFrame};
use haotrannas_core::io::{FrameIoError, read_frame, write_frame};
use haotrannas_core::limits::MAX_MESSAGE_BYTES;
use haotrannas_core::message::Message;
use haotrannas_core::session::SessionState;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::watch;
use tokio::time::Instant;

use crate::handlers::hello::{ServerIdentity, handle_hello};
use crate::handlers::pair::{PairAttempt, PairStep, handle_pair_request};
use crate::handlers::upload::{
    FileOfferRequest, UploadError, UploadStorage, handle_chunk_data, handle_commit,
    handle_file_offer,
};
use crate::pairing::PairingService;

/// Text of the `Error INTERNAL` sent for requests that later milestones add.
pub const NOT_IMPLEMENTED_MESSAGE: &str = "not implemented yet (milestone M1+)";

/// Request id of a `Close`, and of an `Error` that answers no readable request.
const NO_REQUEST_ID: u32 = 0;

/// Settings every session of one server shares.
#[derive(Debug, Clone)]
pub struct SessionSettings {
    /// Software name and server name sent in `HelloOk`.
    pub server_identity: ServerIdentity,
    /// Time from accept until `Hello` must have arrived.
    pub handshake_timeout_ms: u64,
    /// Time without any frame before the connection is closed.
    pub idle_timeout_ms: u64,
    /// Chunk store and catalog for the upload requests.
    pub upload_storage: UploadStorage,
    /// Pairing window and device CA; `None` in dev mode (no pairing).
    pub pairing: Option<Arc<PairingService>>,
}

/// Who the client is, as its TLS client certificate says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PeerIdentity {
    /// A paired, not revoked device (dev mode: always the dev device).
    Device(u64),
    /// No client certificate: may pair, ping and close.
    NoCertificate,
    /// A certificate from our device CA that the catalog does not know (or
    /// revoked): `Hello` gets `NOT_PAIRED`.
    UnknownCertificate,
}

/// One accepted connection, before its first frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Peer {
    pub identity: PeerIdentity,
    /// The client's address (pairing checks its IP).
    pub address: SocketAddr,
    /// When the TCP connection was accepted (start of the handshake timeout).
    pub accepted_at: Instant,
}

/// What one connection has learned so far.
#[derive(Debug)]
struct Conversation {
    state: SessionState,
    /// `device_name` from `Hello` (the name a new device is paired under).
    device_name: String,
    /// Wrong pairing codes on this connection.
    pair_failure_count: u32,
}

/// Why a session ended (for logs and tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionEnd {
    /// The client ended the stream between two frames.
    ClientEnded,
    /// The client sent `Close`.
    ClientClosed,
    /// The server sent a fatal `Error` with this code.
    FatalError(ErrorCode),
    /// The server sent `Close` with this reason (timeouts, shutdown).
    ServerClosed(CloseReason),
    /// The stream failed (reset, broken pipe).
    ConnectionFailed,
}

/// What to do with one decoded frame.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Step {
    /// Send this reply with the request's id and go on.
    Reply(Message),
    /// Send `Error code` with the request's id, then end the connection.
    Fatal(ErrorCode, String),
    /// Send this reply, then `Close reason` and end (after `PairOk`).
    ReplyThenClose(Message, CloseReason, &'static str),
    /// End the connection without a reply (client `Close`).
    EndQuietly,
}

/// What woke the session up.
enum Event {
    Shutdown,
    Timeout(CloseReason),
    Frame(Result<Option<RawFrame>, FrameIoError>),
}

/// Serves one connection until it ends. `peer` says who the client is. The
/// session stops with `Close SERVER_SHUTDOWN` once `shutdown` turns true.
pub async fn run_session<Stream>(
    mut stream: Stream,
    peer: Peer,
    settings: &SessionSettings,
    mut shutdown: watch::Receiver<bool>,
) -> SessionEnd
where
    Stream: AsyncRead + AsyncWrite + Unpin,
{
    let mut last_frame_at = peer.accepted_at;
    let mut conversation = Conversation {
        state: SessionState::AwaitingHello,
        device_name: String::new(),
        pair_failure_count: 0,
    };
    let mut decoder = FrameDecoder::new();

    let session_end = loop {
        let (deadline, timeout_reason) = if conversation.state == SessionState::AwaitingHello {
            (
                peer.accepted_at + Duration::from_millis(settings.handshake_timeout_ms),
                CloseReason::HandshakeTimeout,
            )
        } else {
            (
                last_frame_at + Duration::from_millis(settings.idle_timeout_ms),
                CloseReason::IdleTimeout,
            )
        };
        let event = tokio::select! {
            biased;
            // An error means the server dropped the sender: stop as well.
            _ = shutdown.wait_for(|is_stopping| *is_stopping) => Event::Shutdown,
            read_outcome = tokio::time::timeout_at(deadline, read_frame(&mut stream, &mut decoder)) => {
                read_outcome.map_or(Event::Timeout(timeout_reason), Event::Frame)
            }
        };

        let frame = match event {
            Event::Shutdown => {
                break send_close(
                    &mut stream,
                    CloseReason::ServerShutdown,
                    "server is stopping",
                )
                .await;
            }
            Event::Timeout(reason) => {
                let text = match reason {
                    CloseReason::HandshakeTimeout => "no Hello in time",
                    _ => "no frame in time",
                };
                break send_close(&mut stream, reason, text).await;
            }
            Event::Frame(Ok(None)) => break SessionEnd::ClientEnded,
            Event::Frame(Ok(Some(frame))) => frame,
            Event::Frame(Err(FrameIoError::Frame(error))) => {
                break send_fatal(
                    &mut stream,
                    NO_REQUEST_ID,
                    ErrorCode::MalformedFrame,
                    &error.to_string(),
                )
                .await;
            }
            Event::Frame(Err(error @ FrameIoError::EndedMidFrame { .. })) => {
                break send_fatal(
                    &mut stream,
                    NO_REQUEST_ID,
                    ErrorCode::MalformedFrame,
                    &error.to_string(),
                )
                .await;
            }
            Event::Frame(Err(error)) => {
                tracing::debug!(%error, "connection failed while reading");
                break SessionEnd::ConnectionFailed;
            }
        };

        let request_id = frame.header.request_id;
        match handle_frame(&frame, &mut conversation, &peer, settings).await {
            Step::Reply(reply) => {
                if let Err(error) = write_frame(&mut stream, &reply, request_id).await {
                    tracing::debug!(%error, "connection failed while writing a reply");
                    break SessionEnd::ConnectionFailed;
                }
                // Idle time counts from the reply, not from the request: a
                // slow request (Commit re-hashes the whole file) is not idle.
                last_frame_at = Instant::now();
            }
            Step::Fatal(code, text) => {
                break send_fatal(&mut stream, request_id, code, &text).await;
            }
            Step::ReplyThenClose(reply, reason, text) => {
                if let Err(error) = write_frame(&mut stream, &reply, request_id).await {
                    tracing::debug!(%error, "connection failed while writing a reply");
                    break SessionEnd::ConnectionFailed;
                }
                break send_close(&mut stream, reason, text).await;
            }
            Step::EndQuietly => break SessionEnd::ClientClosed,
        }
    };

    // Send FIN (or TLS close_notify) so the client sees the end at once.
    let _ = stream.shutdown().await;
    tracing::debug!(?session_end, "session ended");
    session_end
}

/// Decodes one frame, checks it against the state machine and answers it.
async fn handle_frame(
    frame: &RawFrame,
    conversation: &mut Conversation,
    peer: &Peer,
    settings: &SessionSettings,
) -> Step {
    let message = match decode_frame(frame) {
        Ok(message) => message,
        Err(error) => return Step::Fatal(ErrorCode::MalformedFrame, error.to_string()),
    };
    let message_type = message.message_type();
    let state = conversation.state;
    if let Err(code) = state.check_incoming(message_type) {
        return Step::Fatal(
            code,
            format!("{} is not allowed now ({state:?})", message_type.name()),
        );
    }
    match message {
        Message::Hello {
            protocol_version,
            device_name,
            ..
        } => match handle_hello(protocol_version, &settings.server_identity, peer.identity) {
            Ok((reply, next_state)) => {
                conversation.state = next_state;
                conversation.device_name = device_name;
                Step::Reply(reply)
            }
            Err((code, text)) => Step::Fatal(code, text),
        },
        Message::Ping => Step::Reply(Message::Pong),
        Message::Close { .. } => {
            conversation.state = SessionState::Closed;
            Step::EndQuietly
        }
        Message::PairRequest { code } => {
            let Some(pairing) = &settings.pairing else {
                return Step::Reply(Message::Error {
                    code: ErrorCode::PairingNotOpen.code(),
                    message: "this server runs in dev mode: no pairing".to_owned(),
                });
            };
            let attempt = PairAttempt {
                peer_ip: peer.address.ip(),
                device_name: &conversation.device_name,
                code: &code,
            };
            let step = handle_pair_request(
                pairing,
                &settings.upload_storage.catalog_writer,
                &attempt,
                &mut conversation.pair_failure_count,
            )
            .await;
            match step {
                PairStep::Paired(pair_ok) => {
                    conversation.state = SessionState::Closed;
                    Step::ReplyThenClose(
                        pair_ok,
                        CloseReason::PairedReconnect,
                        "paired: reconnect with the new certificate",
                    )
                }
                PairStep::Refused(code, text) => Step::Reply(Message::Error {
                    code: code.code(),
                    message: fit_message(&text),
                }),
                PairStep::Fatal(code, text) => Step::Fatal(code, text),
            }
        }
        Message::FileOffer { .. } | Message::ChunkData { .. } | Message::Commit { .. } => {
            // The state machine lets these through only in Ready, which
            // always has a device.
            let PeerIdentity::Device(device_id) = peer.identity else {
                return Step::Fatal(ErrorCode::NotPaired, "no device on this connection".into());
            };
            match handle_upload_request(message, &settings.upload_storage, device_id).await {
                Ok(reply) => Step::Reply(reply),
                Err((code, text)) => Step::Reply(Message::Error {
                    code: code.code(),
                    message: fit_message(&text),
                }),
            }
        }
        // Allowed by the state machine, handled in later milestones. Not fatal.
        _ => Step::Reply(Message::Error {
            code: ErrorCode::Internal.code(),
            message: NOT_IMPLEMENTED_MESSAGE.to_owned(),
        }),
    }
}

/// Passes an upload request to its handler. Its errors are not fatal.
async fn handle_upload_request(
    message: Message,
    upload_storage: &UploadStorage,
    device_id: u64,
) -> Result<Message, UploadError> {
    match message {
        Message::FileOffer {
            path,
            size_bytes,
            modified_time_ms,
            file_sha256,
            chunk_hashes,
        } => {
            let offer = FileOfferRequest {
                path,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            };
            handle_file_offer(upload_storage, device_id, offer).await
        }
        Message::ChunkData {
            upload_id,
            chunk_index,
            chunk_sha256,
            data,
        } => {
            handle_chunk_data(
                upload_storage,
                device_id,
                upload_id,
                chunk_index,
                chunk_sha256,
                data,
            )
            .await
        }
        Message::Commit { upload_id } => handle_commit(upload_storage, device_id, upload_id).await,
        other => Err((
            ErrorCode::Internal,
            format!("{} is not an upload request", other.message_type().name()),
        )),
    }
}

/// Sends `Close reason` and reports the end.
async fn send_close(
    stream: &mut (impl AsyncWrite + Unpin),
    reason: CloseReason,
    text: &str,
) -> SessionEnd {
    let close = Message::Close {
        reason: reason.reason(),
        message: fit_message(text),
    };
    match write_frame(stream, &close, NO_REQUEST_ID).await {
        Ok(()) => SessionEnd::ServerClosed(reason),
        Err(error) => {
            tracing::debug!(%error, "could not send Close");
            SessionEnd::ConnectionFailed
        }
    }
}

/// Sends a fatal `Error` and reports the end.
async fn send_fatal(
    stream: &mut (impl AsyncWrite + Unpin),
    request_id: u32,
    code: ErrorCode,
    text: &str,
) -> SessionEnd {
    tracing::info!(code = code.name(), reason = text, "closing connection");
    let error = Message::Error {
        code: code.code(),
        message: fit_message(text),
    };
    match write_frame(stream, &error, request_id).await {
        Ok(()) => SessionEnd::FatalError(code),
        Err(write_error) => {
            tracing::debug!(error = %write_error, "could not send Error");
            SessionEnd::ConnectionFailed
        }
    }
}

/// Cuts `text` to at most `MAX_MESSAGE_BYTES`, on a character boundary.
fn fit_message(text: &str) -> String {
    let mut end_bytes = text.len().min(MAX_MESSAGE_BYTES);
    while !text.is_char_boundary(end_bytes) {
        end_bytes -= 1;
    }
    text[..end_bytes].to_owned()
}

#[cfg(test)]
mod tests {
    use haotrannas_core::chunker::ChunkHash;
    use haotrannas_core::codec::{decode_frame, encode_frame};
    use haotrannas_core::frame::FrameDecoder;
    use haotrannas_core::io::{read_frame, write_frame};
    use haotrannas_core::limits::{HANDSHAKE_TIMEOUT_MS, IDLE_TIMEOUT_MS, PROTOCOL_VERSION};
    use tokio::io::{AsyncWriteExt, DuplexStream};
    use tokio::task::JoinHandle;

    use super::*;
    use crate::handlers::upload::test_support::open_test_storage;

    /// The client end of an in-memory connection to a running session.
    struct TestClient {
        stream: DuplexStream,
        decoder: FrameDecoder,
        session: JoinHandle<SessionEnd>,
        shutdown_sender: watch::Sender<bool>,
        /// Keeps the storage folder alive as long as the session.
        _storage_folder: tempfile::TempDir,
    }

    impl TestClient {
        fn start(paired_device_id: Option<u64>) -> Self {
            let identity =
                paired_device_id.map_or(PeerIdentity::NoCertificate, PeerIdentity::Device);
            Self::start_with(identity, None)
        }

        fn start_with(identity: PeerIdentity, pairing: Option<Arc<PairingService>>) -> Self {
            let (client_stream, server_stream) = tokio::io::duplex(64 * 1024);
            let (shutdown_sender, shutdown_receiver) = watch::channel(false);
            let (storage_folder, upload_storage) = open_test_storage();
            let settings = SessionSettings {
                server_identity: ServerIdentity::new("attic".to_owned()),
                handshake_timeout_ms: HANDSHAKE_TIMEOUT_MS,
                idle_timeout_ms: IDLE_TIMEOUT_MS,
                upload_storage,
                pairing,
            };
            let peer = Peer {
                identity,
                address: "127.0.0.1:50000".parse().unwrap(),
                accepted_at: Instant::now(),
            };
            let session = tokio::spawn(async move {
                run_session(server_stream, peer, &settings, shutdown_receiver).await
            });
            Self {
                stream: client_stream,
                decoder: FrameDecoder::new(),
                session,
                shutdown_sender,
                _storage_folder: storage_folder,
            }
        }

        async fn send(&mut self, message: &Message, request_id: u32) {
            write_frame(&mut self.stream, message, request_id)
                .await
                .unwrap();
        }

        /// The next reply as (request id, message); `None` at end of stream.
        async fn receive(&mut self) -> Option<(u32, Message)> {
            let frame = read_frame(&mut self.stream, &mut self.decoder)
                .await
                .unwrap()?;
            Some((frame.header.request_id, decode_frame(&frame).unwrap()))
        }

        async fn hello(&mut self) -> Message {
            self.send(&hello_with_version(PROTOCOL_VERSION), 1).await;
            self.receive().await.unwrap().1
        }

        async fn expect_end(mut self) -> SessionEnd {
            assert_eq!(self.receive().await, None, "expected end of stream");
            self.session.await.unwrap()
        }
    }

    fn hello_with_version(protocol_version: u16) -> Message {
        Message::Hello {
            protocol_version,
            client_software: "test/1".to_owned(),
            device_name: "phone".to_owned(),
        }
    }

    fn error(code: ErrorCode) -> u16 {
        code.code()
    }

    fn file_offer() -> Message {
        Message::FileOffer {
            path: "a.txt".to_owned(),
            size_bytes: 0,
            modified_time_ms: 0,
            file_sha256: [0; 32],
            chunk_hashes: Vec::new(),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn hello_then_ping_gets_pong() {
        let mut client = TestClient::start(Some(1));
        let hello_ok = client.hello().await;
        assert!(matches!(
            hello_ok,
            Message::HelloOk {
                protocol_version: 1,
                device_id: 1,
                ..
            }
        ));
        client.send(&Message::Ping, 2).await;
        assert_eq!(client.receive().await, Some((2, Message::Pong)));
        client.send(&Message::Ping, 3).await;
        assert_eq!(client.receive().await, Some((3, Message::Pong)));
        client
            .send(
                &Message::Close {
                    reason: 0,
                    message: String::new(),
                },
                0,
            )
            .await;
        assert_eq!(client.expect_end().await, SessionEnd::ClientClosed);
    }

    #[tokio::test(start_paused = true)]
    async fn ping_before_hello_is_unexpected_and_fatal() {
        let mut client = TestClient::start(Some(1));
        client.send(&Message::Ping, 5).await;
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 5);
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::UnexpectedMessage))
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::FatalError(ErrorCode::UnexpectedMessage)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn other_version_gets_version_mismatch() {
        let mut client = TestClient::start(Some(1));
        client.send(&hello_with_version(2), 1).await;
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::VersionMismatch))
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::FatalError(ErrorCode::VersionMismatch)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn garbage_gets_malformed_frame_with_id_zero() {
        let mut client = TestClient::start(Some(1));
        client
            .stream
            .write_all(b"GET / HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 0);
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::MalformedFrame))
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::FatalError(ErrorCode::MalformedFrame)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn unknown_type_gets_malformed_frame_with_its_request_id() {
        let mut client = TestClient::start(Some(1));
        // length 6, type 0x7777, request id 9, empty payload.
        client
            .stream
            .write_all(&[0, 0, 0, 6, 0x77, 0x77, 0, 0, 0, 9])
            .await
            .unwrap();
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 9);
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::MalformedFrame))
        );
        client.expect_end().await;
    }

    #[tokio::test(start_paused = true)]
    async fn trailing_payload_bytes_are_malformed() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        let mut ping_bytes = encode_frame(&Message::Ping, 4).unwrap();
        ping_bytes[3] = 7; // length 7: one payload byte a Ping must not have
        ping_bytes.push(0);
        client.stream.write_all(&ping_bytes).await.unwrap();
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 4);
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::MalformedFrame))
        );
        client.expect_end().await;
    }

    #[tokio::test(start_paused = true)]
    async fn end_in_the_middle_of_a_frame_is_malformed() {
        let mut client = TestClient::start(Some(1));
        let ping_bytes = encode_frame(&Message::Ping, 4).unwrap();
        client.stream.write_all(&ping_bytes[..7]).await.unwrap();
        // Half-close: the client stops writing but still reads.
        client.stream.shutdown().await.unwrap();
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::MalformedFrame))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn file_offer_before_hello_is_unexpected() {
        let mut client = TestClient::start(Some(1));
        client.send(&file_offer(), 1).await;
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::UnexpectedMessage))
        );
        client.expect_end().await;
    }

    #[tokio::test(start_paused = true)]
    async fn request_not_built_yet_gets_internal_and_the_session_goes_on() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        client.send(&Message::ListDevices, 2).await;
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 2);
        assert_eq!(
            reply,
            Message::Error {
                code: error(ErrorCode::Internal),
                message: NOT_IMPLEMENTED_MESSAGE.to_owned(),
            }
        );
        client.send(&Message::Ping, 3).await;
        assert_eq!(client.receive().await, Some((3, Message::Pong)));
    }

    #[tokio::test]
    async fn upload_errors_are_not_fatal_and_a_small_upload_commits() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        let bad_offer = Message::FileOffer {
            path: "/abs".to_owned(),
            size_bytes: 0,
            modified_time_ms: 0,
            file_sha256: [0; 32],
            chunk_hashes: Vec::new(),
        };
        client.send(&bad_offer, 2).await;
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 2);
        assert!(matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::BadPath)));
        client.send(&Message::Ping, 3).await;
        assert_eq!(client.receive().await, Some((3, Message::Pong)));

        let data = b"hello".to_vec();
        let chunk_sha256 = ChunkHash::of_bytes(&data);
        let offer = Message::FileOffer {
            path: "notes/hello.txt".to_owned(),
            size_bytes: 5,
            modified_time_ms: 1,
            file_sha256: chunk_sha256.0,
            chunk_hashes: vec![chunk_sha256],
        };
        client.send(&offer, 4).await;
        let Some((
            4,
            Message::NeedChunks {
                upload_id,
                existing_version_id: 0,
                missing_indexes,
            },
        )) = client.receive().await
        else {
            panic!("expected NeedChunks");
        };
        assert_eq!(missing_indexes, vec![0]);
        let chunk = Message::ChunkData {
            upload_id,
            chunk_index: 0,
            chunk_sha256,
            data,
        };
        client.send(&chunk, 5).await;
        assert_eq!(
            client.receive().await,
            Some((
                5,
                Message::ChunkOk {
                    chunk_index: 0,
                    chunk_sha256
                }
            ))
        );
        client.send(&Message::Commit { upload_id }, 6).await;
        assert!(matches!(
            client.receive().await,
            Some((6, Message::CommitOk { version_id })) if version_id > 0
        ));
        client.send(&Message::Commit { upload_id }, 7).await;
        assert!(matches!(
            client.receive().await,
            Some((7, Message::Error { code, .. })) if code == error(ErrorCode::UnknownUpload)
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn second_hello_is_unexpected() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        client.send(&hello_with_version(PROTOCOL_VERSION), 2).await;
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::UnexpectedMessage))
        );
        client.expect_end().await;
    }

    #[tokio::test(start_paused = true)]
    async fn server_to_client_type_is_unexpected() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        client.send(&Message::Pong, 2).await;
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::UnexpectedMessage))
        );
        client.expect_end().await;
    }

    #[tokio::test(start_paused = true)]
    async fn unpaired_client_gets_device_zero_and_not_paired() {
        let mut client = TestClient::start(None);
        let hello_ok = client.hello().await;
        assert!(matches!(hello_ok, Message::HelloOk { device_id: 0, .. }));
        client.send(&Message::Ping, 2).await;
        assert_eq!(client.receive().await, Some((2, Message::Pong)));
        client
            .send(
                &Message::ReadChunk {
                    chunk_sha256: ChunkHash([0; 32]),
                },
                3,
            )
            .await;
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::NotPaired))
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::FatalError(ErrorCode::NotPaired)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn unknown_certificate_gets_not_paired_after_hello() {
        let mut client = TestClient::start_with(PeerIdentity::UnknownCertificate, None);
        let reply = client.hello().await;
        assert!(
            matches!(reply, Message::Error { code, .. } if code == error(ErrorCode::NotPaired))
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::FatalError(ErrorCode::NotPaired)
        );
    }

    #[tokio::test]
    async fn right_pairing_code_gets_pair_ok_then_close_paired_reconnect() {
        let tls_folder = tempfile::tempdir().unwrap();
        let tls_identity =
            Arc::new(crate::tls_identity::TlsIdentity::create(tls_folder.path()).unwrap());
        let pairing = Arc::new(PairingService::new(
            tls_identity,
            crate::config::ServerConfig::default(),
            haotrannas_core::limits::PAIRING_CODE_TTL_MS,
        ));
        let code = pairing.open_window().code;
        let mut client = TestClient::start_with(PeerIdentity::NoCertificate, Some(pairing));
        assert!(matches!(
            client.hello().await,
            Message::HelloOk { device_id: 0, .. }
        ));
        client
            .send(
                &Message::PairRequest {
                    code: "000000x".into(),
                },
                2,
            )
            .await;
        assert!(matches!(
            client.receive().await,
            Some((2, Message::Error { code, .. })) if code == error(ErrorCode::BadPairingCode)
        ));
        client.send(&Message::PairRequest { code }, 3).await;
        assert!(matches!(
            client.receive().await,
            Some((3, Message::PairOk { device_id, .. })) if device_id > 0
        ));
        assert!(matches!(
            client.receive().await,
            Some((0, Message::Close { reason, .. })) if reason == CloseReason::PairedReconnect.reason()
        ));
        assert_eq!(
            client.expect_end().await,
            SessionEnd::ServerClosed(CloseReason::PairedReconnect)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn no_hello_in_time_gets_handshake_timeout() {
        let mut client = TestClient::start(Some(1));
        let started_at = Instant::now();
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 0);
        assert!(
            matches!(reply, Message::Close { reason, .. } if reason == CloseReason::HandshakeTimeout.reason())
        );
        assert_eq!(
            started_at.elapsed(),
            Duration::from_millis(HANDSHAKE_TIMEOUT_MS)
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::ServerClosed(CloseReason::HandshakeTimeout)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn idle_connection_gets_idle_timeout() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        tokio::time::sleep(Duration::from_millis(IDLE_TIMEOUT_MS / 2)).await;
        client.send(&Message::Ping, 2).await;
        assert_eq!(client.receive().await, Some((2, Message::Pong)));
        let last_frame_at = Instant::now();
        let (_, reply) = client.receive().await.unwrap();
        assert!(
            matches!(reply, Message::Close { reason, .. } if reason == CloseReason::IdleTimeout.reason())
        );
        // Counted from the last frame, not from the Hello.
        assert_eq!(
            last_frame_at.elapsed(),
            Duration::from_millis(IDLE_TIMEOUT_MS)
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::ServerClosed(CloseReason::IdleTimeout)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn shutdown_sends_server_shutdown() {
        let mut client = TestClient::start(Some(1));
        client.hello().await;
        client.shutdown_sender.send(true).unwrap();
        let (request_id, reply) = client.receive().await.unwrap();
        assert_eq!(request_id, 0);
        assert!(
            matches!(reply, Message::Close { reason, .. } if reason == CloseReason::ServerShutdown.reason())
        );
        assert_eq!(
            client.expect_end().await,
            SessionEnd::ServerClosed(CloseReason::ServerShutdown)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn client_end_of_stream_ends_quietly() {
        let client = TestClient::start(Some(1));
        let TestClient {
            stream, session, ..
        } = client;
        drop(stream);
        assert_eq!(session.await.unwrap(), SessionEnd::ClientEnded);
    }

    #[test]
    fn long_text_is_cut_on_a_character_boundary() {
        let text = "é".repeat(MAX_MESSAGE_BYTES);
        let fitted = fit_message(&text);
        assert!(fitted.len() <= MAX_MESSAGE_BYTES);
        assert_eq!(fitted.len(), MAX_MESSAGE_BYTES);
        assert_eq!(fit_message("short"), "short");
    }
}
