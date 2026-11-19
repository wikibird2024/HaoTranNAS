//! One client connection: connect, say `Hello`, then one request at a time
//! (v1 clients do not pipeline, spec section 3).
//!
//! ```text
//!  dev-plain: TCP ──────────────────────────────────────────► Hello ─► HelloOk
//!  paired:    TCP ─► TLS 1.3 (server pinned by fingerprint,
//!                    this device's cert) ──────────────────────► Hello ─► HelloOk
//!               pin differs          → "server identity changed (expected …, got …)"
//!               lost before HelloOk,
//!               or NOT_PAIRED        → "this device is not paired (or was revoked)"
//!  pairing:   TCP ─► TLS 1.3 (any server cert, fingerprint recorded) ─► Hello ─► …
//! ```
//!
//! [`Connection`] is generic over the stream; the commands use a boxed one.

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use haotrannas_core::codec::decode_frame;
use haotrannas_core::error_code::{CloseReason, ErrorCode};
use haotrannas_core::fingerprint::CertFingerprint;
use haotrannas_core::frame::FrameDecoder;
use haotrannas_core::io::{FrameIoError, read_frame, write_frame};
use haotrannas_core::limits::{CONNECT_TIMEOUT_MS, PROTOCOL_VERSION};
use haotrannas_core::message::Message;
use haotrannas_core::tls::{ClientIdentity, ServerPin, TofuRecorder, client_config, server_name};
use rustls::{CertificateError, ClientConfig};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;

/// How long the cli waits for one reply before giving up.
pub const REPLY_TIMEOUT_MS: u64 = 10_000;

/// Request id of a `Close` (spec section 3).
const NO_REQUEST_ID: u32 = 0;

/// What went wrong, worded for the person at the terminal.
#[derive(Debug, PartialEq, Eq)]
pub enum ClientError {
    /// TCP connect failed or timed out.
    Connect(String),
    /// The server answered with `Error`.
    ServerError { code: u16, message: String },
    /// The server sent `Close`.
    ServerClosed { reason: u16, message: String },
    /// The connection ended or broke without a reply.
    ConnectionLost(String),
    /// No reply within `REPLY_TIMEOUT_MS`.
    ReplyTimeout,
    /// A reply that breaks the protocol (wrong type or request id, bad bytes).
    BadReply(String),
    /// TLS setup or handshake failed (not a pin mismatch).
    Tls(String),
    /// The server's certificate is not the pinned one.
    ServerIdentityChanged {
        expected_short_id: String,
        /// What the server showed, if a second look could tell.
        seen_short_id: Option<String>,
    },
    /// The server refused this device's certificate (unknown or revoked),
    /// or ended the connection before `HelloOk` (spec §6: "maybe not paired").
    NotPaired,
}

impl fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Connect(text) => write!(formatter, "cannot connect: {text}"),
            Self::ServerError { code, message } => write!(
                formatter,
                "server error {}: {message}",
                ErrorCode::label(*code)
            ),
            Self::ServerClosed { reason, message } => write!(
                formatter,
                "server closed the connection ({}): {message}",
                CloseReason::label(*reason)
            ),
            Self::ConnectionLost(text) => write!(formatter, "connection lost: {text}"),
            Self::ReplyTimeout => write!(
                formatter,
                "no reply from the server within {REPLY_TIMEOUT_MS} ms"
            ),
            Self::BadReply(text) => write!(formatter, "bad reply from the server: {text}"),
            Self::Tls(text) => write!(formatter, "TLS failed: {text}"),
            Self::ServerIdentityChanged {
                expected_short_id,
                seen_short_id,
            } => write!(
                formatter,
                "server identity changed (expected {expected_short_id}, got {}): this is not \
                 the server this device paired with",
                seen_short_id.as_deref().unwrap_or("unknown")
            ),
            Self::NotPaired => write!(formatter, "this device is not paired (or was revoked)"),
        }
    }
}

impl std::error::Error for ClientError {}

/// Any stream a connection runs over (plain TCP or TLS).
pub trait ClientStream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<Stream: AsyncRead + AsyncWrite + Unpin + Send> ClientStream for Stream {}

/// A connection over plain TCP or TLS, as the commands use it.
pub type AnyConnection = Connection<Box<dyn ClientStream>>;

/// How to reach the server for `ping` and `upload`.
#[derive(Debug, Clone)]
pub enum Transport {
    /// Plain TCP, for a server started with `run --dev-plain`.
    DevPlain,
    /// TLS to the paired server (pinned) with this device's certificate.
    Paired {
        server_fingerprint: CertFingerprint,
        client_identity: ClientIdentity,
    },
}

/// Connects, says `Hello` as `device_name` and returns the open connection.
pub async fn open_connection(
    server_address: &str,
    transport: &Transport,
    device_name: &str,
) -> Result<AnyConnection, ClientError> {
    match transport {
        Transport::DevPlain => {
            let stream = connect_plain(server_address).await?;
            Connection::open(Box::new(stream) as Box<dyn ClientStream>, device_name).await
        }
        Transport::Paired {
            server_fingerprint,
            client_identity,
        } => {
            let config = client_config(
                ServerPin::Fingerprint(*server_fingerprint),
                Some(client_identity.clone()),
            )
            .map_err(|error| ClientError::Tls(error.to_string()))?;
            let stream = match connect_tls(server_address, config).await {
                Err(ClientError::ServerIdentityChanged { .. }) => {
                    let seen = fetch_server_fingerprint(server_address).await;
                    return Err(ClientError::ServerIdentityChanged {
                        expected_short_id: server_fingerprint.short_id(),
                        seen_short_id: seen.map(|fingerprint| fingerprint.short_id()),
                    });
                }
                other => other?,
            };
            match Connection::open(Box::new(stream) as Box<dyn ClientStream>, device_name).await {
                Err(ClientError::ServerError { code, .. })
                    if code == ErrorCode::NotPaired.code() =>
                {
                    Err(ClientError::NotPaired)
                }
                // TLS 1.3: a refused client certificate shows up as a TLS
                // alert or end of stream on the first read (spec §6).
                Err(ClientError::ConnectionLost(text)) => {
                    tracing::debug!(%text, "connection lost before HelloOk");
                    Err(ClientError::NotPaired)
                }
                other => other,
            }
        }
    }
}

/// Opens a pairing connection: TLS without a client certificate, any
/// server certificate accepted and its fingerprint recorded (trust on
/// first use). Returns the connection after `Hello` and the recorder.
pub async fn open_pairing_connection(
    server_address: &str,
    device_name: &str,
) -> Result<(AnyConnection, TofuRecorder), ClientError> {
    let recorder = TofuRecorder::new();
    let config = client_config(ServerPin::RecordFirstSeen(recorder.clone()), None)
        .map_err(|error| ClientError::Tls(error.to_string()))?;
    let stream = connect_tls(server_address, config).await?;
    let connection =
        Connection::open(Box::new(stream) as Box<dyn ClientStream>, device_name).await?;
    Ok((connection, recorder))
}

/// TCP, then the TLS handshake, within `CONNECT_TIMEOUT_MS` each.
async fn connect_tls(
    server_address: &str,
    config: Arc<ClientConfig>,
) -> Result<TlsStream<TcpStream>, ClientError> {
    let tcp_stream = connect_plain(server_address).await?;
    let handshake = TlsConnector::from(config).connect(server_name(), tcp_stream);
    tokio::time::timeout(Duration::from_millis(CONNECT_TIMEOUT_MS), handshake)
        .await
        .map_err(|_| {
            ClientError::Tls(format!(
                "{server_address}: no TLS handshake within {CONNECT_TIMEOUT_MS} ms"
            ))
        })?
        .map_err(|error| {
            if is_pin_mismatch(&error) {
                ClientError::ServerIdentityChanged {
                    expected_short_id: String::new(),
                    seen_short_id: None,
                }
            } else {
                ClientError::Tls(format!("{server_address}: {error}"))
            }
        })
}

/// True when the handshake failed because the server cert is not the
/// pinned one (`PinnedServerVerifier` says `ApplicationVerificationFailure`).
fn is_pin_mismatch(error: &std::io::Error) -> bool {
    matches!(
        error
            .get_ref()
            .and_then(|inner| inner.downcast_ref::<rustls::Error>()),
        Some(rustls::Error::InvalidCertificate(
            CertificateError::ApplicationVerificationFailure
        ))
    )
}

/// The fingerprint the server at `server_address` shows now (a handshake
/// only, for the "identity changed" message). `None` if that fails too.
async fn fetch_server_fingerprint(server_address: &str) -> Option<CertFingerprint> {
    let recorder = TofuRecorder::new();
    let config = client_config(ServerPin::RecordFirstSeen(recorder.clone()), None).ok()?;
    let _ = connect_tls(server_address, config).await;
    recorder.seen_fingerprint()
}

/// What the server said in `HelloOk`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerHello {
    pub server_software: String,
    pub server_name: String,
    /// 0 = not paired on this connection.
    pub device_id: u64,
}

/// An open connection that has finished `Hello`.
pub struct Connection<Stream> {
    stream: Stream,
    decoder: FrameDecoder,
    next_request_id: u32,
    pub server_hello: ServerHello,
}

/// Opens a plain TCP connection (dev mode) within `CONNECT_TIMEOUT_MS`.
pub async fn connect_plain(server_address: &str) -> Result<TcpStream, ClientError> {
    let connect = TcpStream::connect(server_address);
    let stream = tokio::time::timeout(Duration::from_millis(CONNECT_TIMEOUT_MS), connect)
        .await
        .map_err(|_| {
            ClientError::Connect(format!(
                "{server_address} did not answer within {CONNECT_TIMEOUT_MS} ms"
            ))
        })?
        .map_err(|error| ClientError::Connect(format!("{server_address}: {error}")))?;
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

impl<Stream: AsyncRead + AsyncWrite + Unpin> Connection<Stream> {
    /// Sends `Hello` on `stream` and waits for `HelloOk`.
    pub async fn open(stream: Stream, device_name: &str) -> Result<Self, ClientError> {
        let mut connection = Self {
            stream,
            decoder: FrameDecoder::new(),
            next_request_id: 1,
            server_hello: ServerHello {
                server_software: String::new(),
                server_name: String::new(),
                device_id: 0,
            },
        };
        let hello = Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_software: format!("haotrannas-cli/{}", env!("CARGO_PKG_VERSION")),
            device_name: device_name.to_owned(),
        };
        match connection.request(&hello).await? {
            Message::HelloOk {
                protocol_version,
                server_software,
                server_name,
                device_id,
                ..
            } => {
                if protocol_version != PROTOCOL_VERSION {
                    return Err(ClientError::BadReply(format!(
                        "server speaks protocol version {protocol_version}, not {PROTOCOL_VERSION}"
                    )));
                }
                connection.server_hello = ServerHello {
                    server_software,
                    server_name,
                    device_id,
                };
                Ok(connection)
            }
            other => Err(unexpected_reply(&other)),
        }
    }

    /// Sends one request and returns its reply. `Error` and `Close` from the
    /// server become [`ClientError`]s.
    pub async fn request(&mut self, request: &Message) -> Result<Message, ClientError> {
        let request_id = self.take_request_id();
        write_frame(&mut self.stream, request, request_id)
            .await
            .map_err(|error| ClientError::ConnectionLost(error.to_string()))?;
        let reply_timeout = Duration::from_millis(REPLY_TIMEOUT_MS);
        let frame = tokio::time::timeout(
            reply_timeout,
            read_frame(&mut self.stream, &mut self.decoder),
        )
        .await
        .map_err(|_| ClientError::ReplyTimeout)?
        .map_err(|error| match error {
            FrameIoError::Io(io_error) => ClientError::ConnectionLost(io_error.to_string()),
            other => ClientError::BadReply(other.to_string()),
        })?
        .ok_or_else(|| {
            ClientError::ConnectionLost("the server ended the connection without a reply".into())
        })?;
        let reply =
            decode_frame(&frame).map_err(|error| ClientError::BadReply(error.to_string()))?;
        match reply {
            Message::Error { code, message } => Err(ClientError::ServerError { code, message }),
            Message::Close { reason, message } => {
                Err(ClientError::ServerClosed { reason, message })
            }
            reply if frame.header.request_id == request_id => Ok(reply),
            _ => Err(ClientError::BadReply(format!(
                "reply has request id {}, expected {request_id}",
                frame.header.request_id
            ))),
        }
    }

    /// Sends one request and does not wait for its reply (tests of a lost
    /// reply: the caller drops the connection right after).
    pub async fn send_without_reply(&mut self, request: &Message) -> Result<(), ClientError> {
        let request_id = self.take_request_id();
        write_frame(&mut self.stream, request, request_id)
            .await
            .map_err(|error| ClientError::ConnectionLost(error.to_string()))?;
        self.stream
            .flush()
            .await
            .map_err(|error| ClientError::ConnectionLost(error.to_string()))
    }

    /// Sends `Close NORMAL` and ends the stream. Errors are ignored: the
    /// connection is over either way.
    pub async fn close(mut self) {
        let close = Message::Close {
            reason: CloseReason::Normal.reason(),
            message: String::new(),
        };
        let _ = write_frame(&mut self.stream, &close, NO_REQUEST_ID).await;
        let _ = self.stream.shutdown().await;
    }

    /// The next request id: starts at 1, +1 each time, skips 0 on wrap.
    fn take_request_id(&mut self) -> u32 {
        let request_id = self.next_request_id;
        self.next_request_id = next_request_id_after(request_id);
        request_id
    }
}

/// The id after `request_id`, skipping 0 (spec section 3).
fn next_request_id_after(request_id: u32) -> u32 {
    request_id.checked_add(1).unwrap_or(1)
}

/// A reply of the wrong type.
pub fn unexpected_reply(reply: &Message) -> ClientError {
    ClientError::BadReply(format!("unexpected {}", reply.message_type().name()))
}

#[cfg(test)]
mod tests {
    use haotrannas_core::io::{read_frame, write_frame};
    use haotrannas_core::message::MessageType;

    use super::*;

    #[test]
    fn request_ids_skip_zero_on_wrap() {
        assert_eq!(next_request_id_after(1), 2);
        assert_eq!(next_request_id_after(u32::MAX), 1);
    }

    #[test]
    fn errors_name_the_code() {
        let error = ClientError::ServerError {
            code: 2,
            message: "version".to_owned(),
        };
        assert_eq!(error.to_string(), "server error VERSION_MISMATCH: version");
        let closed = ClientError::ServerClosed {
            reason: 99,
            message: String::new(),
        };
        assert!(closed.to_string().contains("UNKNOWN(99)"));
    }

    /// A fake server on the other end of a duplex: answers Hello and one
    /// Ping, then an Error.
    #[tokio::test]
    async fn hello_ping_and_error_against_a_fake_server() {
        let (client_stream, mut server_stream) = tokio::io::duplex(4096);
        let fake_server = tokio::spawn(async move {
            let mut decoder = FrameDecoder::new();
            let hello = read_frame(&mut server_stream, &mut decoder)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(hello.header.request_id, 1);
            assert_eq!(hello.header.message_type, MessageType::Hello.number());
            let hello_ok = Message::HelloOk {
                protocol_version: PROTOCOL_VERSION,
                server_software: "fake/1".to_owned(),
                server_name: "attic".to_owned(),
                device_id: 1,
                chunk_size_bytes: 1,
                max_frame_length_bytes: 6,
            };
            write_frame(&mut server_stream, &hello_ok, 1).await.unwrap();
            let ping = read_frame(&mut server_stream, &mut decoder)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(ping.header.request_id, 2);
            write_frame(&mut server_stream, &Message::Pong, 2)
                .await
                .unwrap();
            read_frame(&mut server_stream, &mut decoder)
                .await
                .unwrap()
                .unwrap();
            let error = Message::Error {
                code: ErrorCode::Internal.code(),
                message: "nope".to_owned(),
            };
            write_frame(&mut server_stream, &error, 3).await.unwrap();
        });

        let mut connection = Connection::open(client_stream, "test").await.unwrap();
        assert_eq!(connection.server_hello.server_name, "attic");
        assert_eq!(connection.server_hello.device_id, 1);
        assert_eq!(
            connection.request(&Message::Ping).await.unwrap(),
            Message::Pong
        );
        assert_eq!(
            connection.request(&Message::Ping).await.unwrap_err(),
            ClientError::ServerError {
                code: 50,
                message: "nope".to_owned()
            }
        );
        fake_server.await.unwrap();
    }
}
