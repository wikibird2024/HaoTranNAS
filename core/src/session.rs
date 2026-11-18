//! The connection state machine both sides follow:
//! `Connected → Greeted → Ready → Closed`, with the handshake and idle
//! timeouts and the pairing failure limit (see [`crate::limits`]).
//!
//! Pure logic, no I/O: it takes a message and says what to do next.

/// Where a connection is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    /// TCP + TLS are up; waiting for `Hello`.
    Connected,
    /// `Hello` accepted; the device is not paired yet.
    Greeted,
    /// The device is known; requests are allowed.
    Ready,
    /// The connection is over.
    Closed,
}
