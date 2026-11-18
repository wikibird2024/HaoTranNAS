//! Error codes sent in `Error` and reasons sent in `Close`.
//!
//! Stub: the variant list and their wire numbers come from the protocol spec.

/// Why a request failed (sent in `Error`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum ErrorCode {
    /// Something broke inside the server.
    Internal,
    /// The frame or payload could not be decoded.
    BadFrame,
    /// The disk is too full to store the data; nothing was written.
    DiskFull,
}

/// Why a connection is being closed (sent in `Close`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum CloseReason {
    /// Normal end of the conversation.
    Normal,
    /// No `Hello` within the handshake timeout.
    HandshakeTimeout,
    /// No frame within the idle timeout.
    IdleTimeout,
    /// The peer broke the protocol (bad frame, wrong state, over a limit).
    ProtocolError,
    /// Too many wrong pairing codes on this connection.
    TooManyPairFailures,
}
