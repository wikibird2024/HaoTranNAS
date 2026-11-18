//! Every protocol message as one Rust enum, plus its message type number.
//!
//! The protocol spec is the source of truth for the message list and fields;
//! this enum follows it. Stub: only the messages without fields exist so far.

/// One decoded protocol message.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum Message {
    /// Keepalive from the client.
    Ping,
    /// Reply to `Ping`.
    Pong,
}
